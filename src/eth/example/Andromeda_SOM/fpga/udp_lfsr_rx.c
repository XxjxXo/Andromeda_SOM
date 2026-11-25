// SPDX-License-Identifier: MIT
/*
 * Fast UDP receiver and PRBS31 checker for udp_packet_generator_top.
 *
 * - recvmmsg() batches, large socket buffer
 * - -j N: N threads, thread i listens on port + i. The 100G generator sends
 *   FLOW_CNT = 8 flows with destination ports 5005..5012, so -j 8 gives one
 *   socket and one core per flow (the NIC spreads the flows over its RX
 *   queues with RSS, or with ntuple rules, see CHANGES_Etapa_3.md)
 * - -c CPU: pin thread i to CPU + i
 * - PRBS31 check (x^31 + x^28 + 1) per packet with the self-synchronising
 *   recurrence b[n] ^ b[n-31] ^ b[n-t] = 0, done on 64-bit words; the bit
 *   order and tap orientation are detected on the first packet
 * - taxi_lfsr shifts MSB first: bit DATA_W-1 of each generator word is the
 *   first one in time, while the MAC sends tdata[7:0] first. The checker
 *   bit-reverses each DATA_W/8-byte block before checking (64 B for the
 *   512-bit 100G datapath, 4 B for 32-bit 10G); the block size is detected
 *   too, or forced with -w
 * - -s N checks only 1 of every N packets (all packets are still counted)
 *
 * A single bit error on the wire gives 3 recurrence errors; the BER printed
 * at the end is already divided by 3.
 *
 * Build: gcc -O3 -march=native -pthread -o udp_lfsr_rx udp_lfsr_rx.c
 * Usage: ./udp_lfsr_rx [-p port] [-j threads] [-c first_cpu] [-s sample]
 *                      [-t seconds] [-w block_bytes] [-T] [-f payload_file]
 *   -f  check a raw payload file instead of listening (detection only)
 *   -T  self test (no network)
 */

#define _GNU_SOURCE
#include <errno.h>
#include <getopt.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define BATCH   64
#define PKT_MAX 9216
#define MAX_THR 64

static int port = 5005;
static int nthreads = 1;
static int first_cpu = -1;
static int sample = 1;
static int force_blk = -1;
static double duration = 0;
static volatile sig_atomic_t stop_flag = 0;

/*
 * detected mode: mode_blk = 0: bits LSB first, as received; mode_blk = B > 0:
 * bit-reverse every B-byte block (B = 1: MSB first in each byte); short tap
 */
static atomic_int mode_set = 0;
static int mode_blk = 0;
static int mode_tap = 28;
static pthread_mutex_t mode_lock = PTHREAD_MUTEX_INITIALIZER;

struct stats {
    _Atomic uint64_t pkts, bytes, checked_bytes, err_bits, err_pkts, short_pkts;
} __attribute__((aligned(64)));

static struct stats st[MAX_THR];

static uint8_t rev8[256];

static void init_rev8(void)
{
    for (int i = 0; i < 256; i++) {
        uint8_t r = 0;
        for (int b = 0; b < 8; b++)
            if (i & (1 << b))
                r |= 1 << (7 - b);
        rev8[i] = r;
    }
}

/*
 * Recurrence errors over a packet. Bits are taken LSB first from each byte,
 * bytes in order (little-endian 64-bit words on x86). The words after the
 * data up to the next 8-byte boundary must be zero (the caller pads).
 *
 * For word i (bits 64i..64i+63): b[n-31] = (w[i-1] >> 33) | (w[i] << 31)
 * and b[n-t] = (w[i-1] >> (64-t)) | (w[i] << t).
 */
static inline uint64_t prbs_errors(const uint64_t *w, size_t nbytes, int tap)
{
    size_t nbits = nbytes * 8;
    size_t full = nbits / 64;
    unsigned rt = 64 - tap;
    uint64_t err = 0;

    /* word 0: only bits 31..63 can be checked */
    {
        uint64_t v = w[0] ^ (w[0] << 31) ^ (w[0] << tap);
        err += __builtin_popcountll(v & ~((1ULL << 31) - 1));
    }
    for (size_t i = 1; i < full; i++) {
        uint64_t a = w[i - 1], b = w[i];
        uint64_t v = b ^ ((a >> 33) | (b << 31)) ^ ((a >> rt) | (b << tap));
        err += __builtin_popcountll(v);
    }
    if (nbits % 64) {
        uint64_t a = w[full - 1], b = w[full];
        uint64_t v = b ^ ((a >> 33) | (b << 31)) ^ ((a >> rt) | (b << tap));
        err += __builtin_popcountll(v & ((1ULL << (nbits % 64)) - 1));
    }
    return err;
}

static inline uint64_t rev64(uint64_t x)
{
    x = ((x >> 1) & 0x5555555555555555ULL) | ((x & 0x5555555555555555ULL) << 1);
    x = ((x >> 2) & 0x3333333333333333ULL) | ((x & 0x3333333333333333ULL) << 2);
    x = ((x >> 4) & 0x0F0F0F0F0F0F0F0FULL) | ((x & 0x0F0F0F0F0F0F0F0FULL) << 4);
    return __builtin_bswap64(x);
}

/* 'data' must have 8 writable bytes after n (zeroed here) */
static uint64_t check_packet(uint8_t *data, size_t n, uint64_t *tmp)
{
    if (n < 16)
        return 0;
    memset(data + n, 0, 8);
    if (mode_blk && (mode_blk % 8) == 0 && ((uintptr_t)data & 7) == 0) {
        /* fast path: reverse 64-bit word order and bits inside each word */
        size_t wpb = (size_t)mode_blk / 8;
        size_t full = n / (size_t)mode_blk;
        const uint64_t *src = (const uint64_t *)data;
        for (size_t k = 0; k < full; k++)
            for (size_t j = 0; j < wpb; j++)
                tmp[k * wpb + j] = rev64(src[k * wpb + wpb - 1 - j]);
        size_t done = full * (size_t)mode_blk;
        if (done < n) {
            uint8_t *t = (uint8_t *)tmp;
            size_t len = n - done;
            for (size_t j = 0; j < len; j++)
                t[done + j] = rev8[data[n - 1 - j]];
        }
        memset((uint8_t *)tmp + n, 0, 8);
        return prbs_errors(tmp, n, mode_tap);
    }
    if (mode_blk) {
        uint8_t *t = (uint8_t *)tmp;
        size_t blk = (size_t)mode_blk;
        for (size_t k = 0; k < n; k += blk) {
            size_t len = n - k < blk ? n - k : blk;
            const uint8_t *src = data + k + len - 1;
            uint8_t *dst = t + k;
            for (size_t j = 0; j < len; j++)
                dst[j] = rev8[src[-(ptrdiff_t)j]];
        }
        memset(t + n, 0, 8);
        return prbs_errors(tmp, n, mode_tap);
    }
    if (((uintptr_t)data & 7) == 0)
        return prbs_errors((const uint64_t *)data, n, mode_tap);
    memcpy(tmp, data, n + 8);
    return prbs_errors(tmp, n, mode_tap);
}

static void detect_mode(uint8_t *data, size_t n, uint64_t *tmp)
{
    pthread_mutex_lock(&mode_lock);
    if (!atomic_load(&mode_set)) {
        static const int blks[] = { 0, 1, 4, 8, 16, 32, 64 };
        uint64_t best = UINT64_MAX;
        int bblk = 0, btap = 28;
        for (unsigned b = 0; b < sizeof(blks) / sizeof(blks[0]); b++) {
            if (force_blk >= 0 && blks[b] != force_blk)
                continue;
            for (int k = 0; k < 2; k++) {
                int tap = k ? 3 : 28;
                mode_blk = blks[b];
                mode_tap = tap;
                uint64_t e = check_packet(data, n, tmp);
                if (e < best) {
                    best = e;
                    bblk = blks[b];
                    btap = tap;
                }
            }
        }
        if (force_blk >= 0 && best == UINT64_MAX) {
            /* block size not in the list: use it as given */
            bblk = force_blk;
            for (int k = 0; k < 2; k++) {
                mode_blk = bblk;
                mode_tap = k ? 3 : 28;
                uint64_t e = check_packet(data, n, tmp);
                if (e < best) {
                    best = e;
                    btap = mode_tap;
                }
            }
        }
        mode_blk = bblk;
        mode_tap = btap;
        if (bblk == 0)
            printf("Detected PRBS31: LSB first as received, taps 31/%d", btap);
        else
            printf("Detected PRBS31: bit-reversed in %d-byte blocks, taps 31/%d", bblk, btap);
        printf(" (%lu errors in the first %zu-byte packet)\n", (unsigned long)best, n);
        if (best > n)
            printf("WARNING: no combination matches, the payload does not look like PRBS31\n");
        fflush(stdout);
        atomic_store(&mode_set, 1);
    }
    pthread_mutex_unlock(&mode_lock);
}

static void *rx_thread(void *arg)
{
    int id = (int)(intptr_t)arg;
    struct stats *s = &st[id];

    if (first_cpu >= 0) {
        cpu_set_t set;
        CPU_ZERO(&set);
        CPU_SET(first_cpu + id, &set);
        if (pthread_setaffinity_np(pthread_self(), sizeof(set), &set) != 0)
            fprintf(stderr, "thread %d: could not pin to CPU %d\n", id, first_cpu + id);
    }

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        perror("socket");
        exit(1);
    }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
    int rcvbuf = 256 * 1024 * 1024;
    if (setsockopt(fd, SOL_SOCKET, SO_RCVBUFFORCE, &rcvbuf, sizeof(rcvbuf)) < 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
    struct timeval tv = { .tv_sec = 0, .tv_usec = 200000 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    struct sockaddr_in addr = { .sin_family = AF_INET, .sin_port = htons(port + id), .sin_addr.s_addr = INADDR_ANY };
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "port %d: ", port + id);
        perror("bind");
        exit(1);
    }

    uint8_t (*bufs)[PKT_MAX] = aligned_alloc(64, sizeof(uint8_t[BATCH][PKT_MAX]));
    uint64_t *tmp = aligned_alloc(64, (PKT_MAX / 8 + 8) * 8);
    if (!bufs || !tmp) {
        perror("alloc");
        exit(1);
    }
    struct mmsghdr msgs[BATCH];
    struct iovec iov[BATCH];
    memset(msgs, 0, sizeof(msgs));
    for (int i = 0; i < BATCH; i++) {
        iov[i].iov_base = bufs[i];
        iov[i].iov_len = PKT_MAX - 8;
        msgs[i].msg_hdr.msg_iov = &iov[i];
        msgs[i].msg_hdr.msg_iovlen = 1;
    }

    uint64_t cnt = 0;
    while (!stop_flag) {
        int r = recvmmsg(fd, msgs, BATCH, MSG_WAITFORONE, NULL);
        if (r < 0) {
            if (errno == EAGAIN || errno == EINTR)
                continue;
            perror("recvmmsg");
            break;
        }
        uint64_t b = 0, cb = 0, eb = 0, ep = 0, sp = 0;
        for (int i = 0; i < r; i++) {
            size_t n = msgs[i].msg_len;
            b += n;
            if (n < 16) {
                sp++;
                continue;
            }
            if (!atomic_load_explicit(&mode_set, memory_order_acquire))
                detect_mode(bufs[i], n, tmp);
            if (sample <= 1 || (cnt++ % sample) == 0) {
                uint64_t e = check_packet(bufs[i], n, tmp);
                cb += n;
                eb += e;
                if (e)
                    ep++;
            }
        }
        atomic_fetch_add_explicit(&s->pkts, r, memory_order_relaxed);
        atomic_fetch_add_explicit(&s->bytes, b, memory_order_relaxed);
        atomic_fetch_add_explicit(&s->checked_bytes, cb, memory_order_relaxed);
        atomic_fetch_add_explicit(&s->err_bits, eb, memory_order_relaxed);
        atomic_fetch_add_explicit(&s->err_pkts, ep, memory_order_relaxed);
        atomic_fetch_add_explicit(&s->short_pkts, sp, memory_order_relaxed);
    }
    close(fd);
    return NULL;
}

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static void on_sig(int sig)
{
    (void)sig;
    stop_flag = 1;
}

/* build a packet the way udp_packet_generator_top does: DATA_W-bit words,
 * taxi_lfsr MSB first (bit DATA_W-1 first in time), tdata[7:0] first on the
 * wire. dw = 0 builds a plain LSB-first stream. */
static void build_packet(uint8_t *pkt, size_t n, const uint8_t *bits, int dw)
{
    memset(pkt, 0, n + 8);
    for (size_t i = 0; i < n * 8; i++) {
        if (!bits[i])
            continue;
        size_t pos;
        if (dw) {
            size_t word = i / dw, k = i % dw;
            pos = word * dw + (dw - 1 - k);   /* tdata bit index */
        } else {
            pos = i;
        }
        pkt[pos / 8] |= 1 << (pos % 8);
    }
}

static int self_test(void)
{
    size_t n = 8960;
    uint8_t *bits = calloc(n * 8, 1);
    uint8_t *pkt = calloc(n + 8, 1);
    uint64_t *tmp = calloc(n / 8 + 8, 8);
    for (int i = 0; i < 31; i++)
        bits[i] = 1;
    for (size_t i = 31; i < n * 8; i++)
        bits[i] = bits[i - 31] ^ bits[i - 28];

    static const int dws[] = { 0, 8, 32, 64, 512 };
    static const int exp_blk[] = { 0, 1, 4, 8, 64 };
    int ok = 1;
    for (unsigned d = 0; d < sizeof(dws) / sizeof(dws[0]); d++) {
        build_packet(pkt, n, bits, dws[d]);
        atomic_store(&mode_set, 0);
        detect_mode(pkt, n, tmp);
        uint64_t e0 = check_packet(pkt, n, tmp);
        pkt[700] ^= 0x10;
        uint64_t e1 = check_packet(pkt, n, tmp);
        printf("  DATA_W %3d: block %2d tap %2d, clean %lu, 1 flipped bit -> %lu (expect block %d, 0 and 3)\n",
               dws[d], mode_blk, mode_tap, (unsigned long)e0, (unsigned long)e1, exp_blk[d]);
        if (mode_blk != exp_blk[d] || e0 != 0 || e1 != 3)
            ok = 0;
    }

    for (int b = 0; b <= 64; b += 64) {
        build_packet(pkt, n, bits, b ? 512 : 0);
        mode_blk = b;
        mode_tap = 28;
        double t0 = now_s();
        uint64_t acc = 0;
        int iters = 100000;
        for (int i = 0; i < iters; i++)
            acc += check_packet(pkt, n, tmp);
        double dt = now_s() - t0;
        printf("  check speed, block %2d: %.1f Gb/s per core (acc %lu)\n", b,
               (double)iters * n * 8 / dt / 1e9, (unsigned long)acc);
    }
    printf("Self test %s\n", ok ? "PASSED" : "FAILED");
    return ok ? 0 : 1;
}

int main(int argc, char **argv)
{
    int opt;
    int test = 0;
    init_rev8();
    const char *file = NULL;
    while ((opt = getopt(argc, argv, "p:j:c:s:t:w:f:Th")) != -1) {
        switch (opt) {
        case 'p': port = atoi(optarg); break;
        case 'j': nthreads = atoi(optarg); break;
        case 'c': first_cpu = atoi(optarg); break;
        case 's': sample = atoi(optarg); break;
        case 't': duration = atof(optarg); break;
        case 'w': force_blk = atoi(optarg); break;
        case 'f': file = optarg; break;
        case 'T': test = 1; break;
        default:
            fprintf(stderr, "Usage: %s [-p port] [-j threads] [-c first_cpu] [-s sample] [-t seconds]\n"
                    "          [-w block_bytes] [-f payload_file] [-T]\n"
                    "  -j  N threads, thread i listens on port + i (one per flow)\n"
                    "  -c  pin thread i to CPU first_cpu + i\n"
                    "  -w  bit-reverse blocks of this many bytes (64 for 100G, 4 for 10G, 0 none); default auto\n",
                    argv[0]);
            return 1;
        }
    }
    if (test)
        return self_test();
    if (file) {
        /* check a raw payload file (e.g. extracted from a capture) */
        static uint8_t fb[PKT_MAX] __attribute__((aligned(64)));
        static uint64_t ft[PKT_MAX / 8 + 8];
        FILE *f = fopen(file, "rb");
        if (!f) {
            perror(file);
            return 1;
        }
        size_t n = fread(fb, 1, PKT_MAX - 8, f);
        fclose(f);
        detect_mode(fb, n, ft);
        return 0;
    }
    if (nthreads < 1 || nthreads > MAX_THR)
        nthreads = 1;
    if (sample < 1)
        sample = 1;

    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);

    if (nthreads > 1)
        printf("Listening on UDP ports %d-%d, one thread per port", port, port + nthreads - 1);
    else
        printf("Listening on UDP port %d", port);
    if (first_cpu >= 0)
        printf(", CPUs %d-%d", first_cpu, first_cpu + nthreads - 1);
    printf(", checking 1 of every %d packet(s)\n", sample);
    pthread_t th[MAX_THR];
    for (int i = 0; i < nthreads; i++)
        pthread_create(&th[i], NULL, rx_thread, (void *)(intptr_t)i);

    double t0 = now_s(), tl = t0;
    uint64_t lp = 0, lb = 0, le = 0;
    uint64_t lbt[MAX_THR] = { 0 };
    while (!stop_flag) {
        usleep(1000000);
        double t = now_s();
        uint64_t p = 0, b = 0, cb = 0, e = 0, ep = 0;
        for (int i = 0; i < nthreads; i++) {
            p += atomic_load(&st[i].pkts);
            b += atomic_load(&st[i].bytes);
            cb += atomic_load(&st[i].checked_bytes);
            e += atomic_load(&st[i].err_bits);
            ep += atomic_load(&st[i].err_pkts);
        }
        double dt = t - tl;
        printf("%7.1fs %9.0f pkt/s %7.2f Gb/s  errors %8lu | pkts %lu  err pkts %lu  err bits %lu  BER %.2e\n",
               t - t0, (p - lp) / dt, (b - lb) * 8 / dt / 1e9, (unsigned long)(e - le),
               (unsigned long)p, (unsigned long)ep, (unsigned long)e, cb ? e / 3.0 / (cb * 8.0) : 0.0);
        if (nthreads > 1) {
            printf("         per port Gb/s:");
            for (int i = 0; i < nthreads; i++) {
                uint64_t bt = atomic_load(&st[i].bytes);
                printf(" %d:%.1f", port + i, (bt - lbt[i]) * 8 / dt / 1e9);
                lbt[i] = bt;
            }
            printf("\n");
        }
        fflush(stdout);
        lp = p;
        lb = b;
        le = e;
        tl = t;
        if (duration > 0 && t - t0 >= duration)
            stop_flag = 1;
    }
    for (int i = 0; i < nthreads; i++)
        pthread_join(th[i], NULL);

    uint64_t p = 0, b = 0, cb = 0, e = 0, ep = 0, sp = 0;
    for (int i = 0; i < nthreads; i++) {
        p += st[i].pkts;
        b += st[i].bytes;
        cb += st[i].checked_bytes;
        e += st[i].err_bits;
        ep += st[i].err_pkts;
        sp += st[i].short_pkts;
    }
    if (nthreads > 1) {
        printf("\n");
        for (int i = 0; i < nthreads; i++)
            printf("Port %d: packets %lu, errors %lu, packets with errors %lu\n", port + i,
                   (unsigned long)st[i].pkts, (unsigned long)st[i].err_bits, (unsigned long)st[i].err_pkts);
    }
    printf("\nPackets %lu, bytes %lu, checked bytes %lu, packets with errors %lu, short packets %lu\n",
           (unsigned long)p, (unsigned long)b, (unsigned long)cb, (unsigned long)ep, (unsigned long)sp);
    printf("Recurrence errors %lu, approx. BER %.3e\n", (unsigned long)e, cb ? e / 3.0 / (cb * 8.0) : 0.0);
    if (cb && e == 0)
        printf("No errors in %.3e checked bits: BER < %.1e (95%% confidence, 3/bits)\n",
               cb * 8.0, 3.0 / (cb * 8.0));
    return 0;
}
