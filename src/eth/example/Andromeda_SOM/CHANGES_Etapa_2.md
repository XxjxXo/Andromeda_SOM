# Generador UDP/IP a velocidad de línea sobre la pila Zircon

Este documento recoge los cambios del commit `8df29b8` ("Zircon udp Tx datapath working") respecto a la etapa 1 (`91c57c9`), en la que el diseño hacía loopback 10GBASE-R en los cuatro carriles del QSFP28.

- **Hardware destino**: SOM Enclustra Andromeda XZU90 (XCZU17EG-1FFVD1760E) sobre placa base Andromeda PE5.
- **Función**: cada carril del QSFP28 transmite de forma autónoma tramas UDP/IPv4 cuyo payload es una secuencia LFSR, a velocidad de línea. El RX se descarta.
- **Configuración construida**: `fpga_10g` (MAC de 32 bits a 322,266 MHz, baja latencia, MAC+PCS combinados).
- **Estado**: probado en placa contra una NIC Intel X710 (driver `i40e`). Con payload de 8960 B se reciben **1,16 GiB/s por interfaz** (medido con `bmon`), es decir, tasa de línea en los cuatro carriles. Timing cumplido (WNS +0,015 ns).

Las rutas son relativas a `src/eth/example/Andromeda_SOM/fpga/` salvo que se indique otra cosa.

## 1. Ficheros modificados

| Fichero | Cambio |
|---|---|
| `rtl/udp_packet_generator_top.sv` | **Nuevo**. Generador LFSR + pila TX de Zircon (ingress, buffer, deparse, egress). |
| `rtl/fpga_core.sv` | El bucle `qsfp_ch` deja de instanciar la FIFO de loopback RX→TX y pasa a instanciar un `udp_packet_generator_top` por carril. |
| `fpga_10g/Makefile` | Añadidos el generador, los módulos `zircon_ip_*`, `taxi_axis_concat.sv` y `taxi_eth_phy_10g_us_gt_ll.f`. |
| `build_10g.sh` | Comentario con el comando `tcpdump` de prueba. |
| `vitis/Andromeda_SOM/` (raíz del repo) | `platform.spr` apunta al `.xsa` de la nueva ruta del repositorio y `hw/fpga.xsa` se ha regenerado. |
| `pin_irqs.sh` (raíz del repo) | **Nuevo**. Script para el PC receptor: un core por interfaz (ver parte 5). |

## 2. Arquitectura del generador

Una instancia por carril, toda en el dominio `qsfp_tx_clk[n]` (322,266 MHz, bus de 32 bits):

```
taxi_lfsr ──► FSM payload ──► zircon_ip_tx_ingress ──► zircon_ip_tx_buffer ──────────────► zircon_ip_tx_egress ──► MAC TX
                                                       (FIFO 32 KB + len_cksum)            (deparse + concat + FIFO)
                                                              │                                   ▲
                                                              └─ longitud, checksum ─► FSM metadatos (16 × 64 bits)
```

1. **Payload**: `taxi_lfsr` (PRBS31, polinomio `0x10000001`, sin Galois) genera `DATA_W` bits por ciclo. La FSM los empaqueta en tramas de `pkt_len_bytes` con `tlast` y `tkeep` en la última palabra.
2. **Buffer**: `zircon_ip_tx_buffer` almacena el payload y calcula su longitud y su checksum de 16 bits (`zircon_ip_len_cksum`, `START_OFFSET = 0`).
3. **Metadatos**: con la longitud y el checksum, la FSM de metadatos manda al deparser el bloque de 16 palabras que describe las cabeceras Ethernet/IPv4/UDP.
4. **Egress**: `zircon_ip_tx_deparse` construye la cabecera de 42 B (32 bits), `taxi_axis_concat` la une al payload y una FIFO asíncrona la entrega a la MAC.

### Parámetros en `fpga_core.sv`

| Parámetro | Valor | Nota |
|---|---|---|
| `pkt_len_bytes` | 8960 | Payload UDP. Máximo con MTU 9000: 8972 (ver parte 4) |
| `trigger_start` | `1'b1` | Transmisión continua |
| `dest_mac` | `FF:FF:FF:FF:FF:FF` | Broadcast: la NIC la acepta sin modo promiscuo |
| `src_mac` | `80:23:31:43:54:4C + n` | |
| `src_ip` / `dest_ip` | `10·(n+1).0.0.2` → `10·(n+1).0.0.1` | Canal 0: 10.0.0.x, canal 3: 40.0.0.x |
| `src_port` / `dest_port` | `5005 + n` → `5005` | |

## 3. Correcciones sobre la primera versión del generador

La primera versión sintetizaba, pero no llegaba **ningún** paquete al PC. Estos son los errores encontrados y su motivo.

### FSM de payload: el paquete nunca terminaba

| Antes | Problema |
|---|---|
| En la última palabra se asignaba `tlast <= 1` y, si `tready`, en el mismo ciclo `tvalid <= 0` y `tlast <= 0` | La última asignación gana: con `tready` casi siempre a 1, la palabra con `tlast` nunca salía con `tvalid`. Todo el flujo era una única trama infinita. |
| La cuenta de bytes y el LFSR avanzaban con `tready`, aunque `tvalid` estuviera a 0 | Se perdía una palabra por paquete. |

Consecuencia en cadena: sin `tlast`, `zircon_ip_len_cksum` no emite la longitud, no se generan metadatos, el deparser no construye cabecera, `taxi_axis_concat` espera la cabecera indefinidamente y el buffer de 32 KB se llena. A la MAC no llega nada.

**Ahora**: handshake estándar. Se carga una palabra nueva solo si `!tvalid || tready`, y `tvalid` baja únicamente cuando `tready` consume la palabra presente.

### FSM de metadatos: la palabra 15 nunca se transfería

Mismo patrón de error. Con `cnt == 15` el `tvalid <= 0` del mismo ciclo anulaba la palabra, así que el deparser recibía 15 palabras sin `tlast`. El deparser cierra el bloque al recibir 16 palabras o `tlast`, por lo que tomaba como palabra 15 la palabra 0 del paquete siguiente. A partir de ahí todos los bloques quedaban desplazados (flags a 0, MAC e IP en posiciones incorrectas). Además, si `tready` bajaba a mitad del bloque, se sobrescribía una palabra no transferida.

**Ahora**: el mismo handshake que en la FSM de payload.

### Formato de los metadatos

El deparser espera MAC e IP **en orden de red**, con el primer byte del cable en `tdata[7:0]` (comprobado en la lógica de `zircon_ip_tx_deparse.sv` y en `test_zircon_ip_tx_deparse.py`).

| Palabra | Antes | En el cable salía | Ahora |
|---|---|---|---|
| 3 (MAC destino) | `dest_mac` sin invertir | `01:00:00:35:0A:00`: **multicast**, la NIC la descartaba | `swab48(dest_mac)` |
| 4 (MAC origen) | `src_mac` sin invertir | MAC al revés | `swab48(src_mac)`; ethertype `16'h0008` (0x0800 en big-endian; el deparser lo sobrescribe por los flags) |
| 7 (IP) | `{16'd0, 16'h1234, 8'd64, 8'd17, 16'd0}` | **TTL = 0** | `{8'd0 DSCP/ECN, 8'd0, 16'h1234 ID, 16'd0, 8'd64 TTL, 8'd17 proto}` |
| 8 / 10 (IP destino / origen) | `dest_ip` / `src_ip` sin invertir | `1.0.0.10` en lugar de `10.0.0.1`: el kernel lo descartaba | `swab32(...)` |
| 12 (puertos) | `{dest_port, src_port}` | Puertos intercambiados | `{src_port, dest_port}` |

La palabra 0 (`{checksum, longitud, flags 0x8000_0208}` = EN | UDP | IPv4) ya era correcta.

### `swab48` / `swab32` en lugar de `{<<8{...}}`

Vivado da *"streaming concatenation not supported"* con el operador de streaming dentro de una concatenación. Se sustituyó por dos funciones de inversión de bytes, con la misma lógica que `swab32` en `zircon_ip_tx_deparse.sv`.

## 4. Rendimiento

### Overhead por trama

| Campo | Bytes |
|---|---|
| Preámbulo + SFD | 8 |
| Ethernet + IPv4 + UDP | 14 + 20 + 8 = 42 |
| Payload | `pkt_len_bytes` |
| FCS | 4 |
| IFG | 12 |
| **Overhead total** | **66** |

| Payload | Eficiencia | Payload útil a 10G | Paquetes/s | Máximo en `bmon` |
|---|---|---|---|---|
| 1000 B | 93,8 % | 1118 MiB/s | 1,17 M | ~1165 MiB/s |
| 8960 B | 99,3 % | ~9,93 Gb/s | 138 k | **1,16 GiB/s** |

`bmon` (y cualquier herramienta basada en `rx_bytes`) cuenta la trama sin preámbulo, FCS ni IFG: payload + 42 B por paquete.

### Por qué payload de 8960 y no 9000

Con MTU 9000, el paquete IP (cabecera IP + UDP + payload) no puede superar 9000 B, así que el payload máximo es 9000 − 20 − 8 = **8972 B**. Con 9000 B de payload el paquete IP mide 9028 B y la NIC lo descarta como oversize. 8960 es múltiplo de 32 y queda dentro del límite. En la FPGA nada limita por debajo de 8972: el buffer de 32 KB admite ~3 paquetes, la longitud va en 16 bits y la FIFO de egress funciona en modo cut-through.

### De 875 MiB/s a tasa de línea

Con payload de 1000 B, `bmon` marcaba **875 MiB/s** (≈ 880 kpps, el 75 % del máximo). `ethtool -S` mostraba `port.rx_dropped` = 8 M: las tramas llegaban a la NIC, pero se descartaban por falta de descriptores RX. La FPGA estaba transmitiendo a tasa de línea y el PC no vaciaba el ring a tiempo.

Causa: cada carril es un único flujo (misma 5-tupla). RSS lo lleva siempre a la misma cola RX y, por tanto, a un único core, que no llega a 1,17 Mpps. Con tramas jumbo (138 kpps) y una interfaz por core, se alcanza la tasa de línea.

### Límite de tamaño mínimo

`zircon_ip_len_cksum` emite la longitud y el checksum como un pulso de un ciclo e ignora `tready`. Si llega mientras la FSM de metadatos está enviando las 16 palabras del paquete anterior, se pierde. Por debajo de unos **70 B de payload** se perderían paquetes.

## 5. Configuración del PC receptor

Probado con una NIC Intel X710 de 4 puertos (driver `i40e`), interfaces `enp4s0f0np0` … `enp4s0f3np3`. La shell por defecto era zsh: los arrays empiezan en 1, así que los scripts que usan índices se ejecutan con `bash`.

### Interfaces con NetworkManager

Una conexión por interfaz, IP del canal correspondiente y MTU 9000. La versión con pares `interfaz:red` funciona igual en bash y en zsh:

```bash
# Borrar conexiones anteriores
nmcli -g NAME con show | grep '^fpga-' | while read -r c; do nmcli con delete "$c"; done

for pair in enp4s0f0np0:10 enp4s0f1np1:20 enp4s0f2np2:30 enp4s0f3np3:40; do
    IF=${pair%%:*}
    NET=${pair##*:}
    nmcli con add type ethernet ifname "$IF" con-name "fpga-$IF" \
        ipv4.method manual ipv4.addresses "$NET.0.0.1/24" \
        ipv4.never-default yes ipv6.method disabled \
        802-3-ethernet.mtu 9000 connection.autoconnect yes
    nmcli con up "fpga-$IF"
done
```

| Interfaz | Canal FPGA | IP en el PC | Origen FPGA |
|---|---|---|---|
| enp4s0f0np0 | 0 | 10.0.0.1/24 | 10.0.0.2 |
| enp4s0f1np1 | 1 | 20.0.0.1/24 | 20.0.0.2 |
| enp4s0f2np2 | 2 | 30.0.0.1/24 | 30.0.0.2 |
| enp4s0f3np3 | 3 | 40.0.0.1/24 | 40.0.0.2 |

Las redes 20, 30 y 40 son públicas. Con `ipv4.never-default` y una /24 solo afectan a esas subredes.

Comprobación:

```bash
nmcli -f NAME,DEVICE,STATE con show --active | grep fpga
ip -br addr show | grep enp4s0
```

Si los paquetes no llegan a la aplicación, desactivar `rp_filter`:

```bash
for IF in enp4s0f0np0 enp4s0f1np1 enp4s0f2np2 enp4s0f3np3; do
    sudo sysctl -w net.ipv4.conf.$IF.rp_filter=0
done
sudo sysctl -w net.ipv4.conf.all.rp_filter=0
```

### Un core por interfaz (`pin_irqs.sh`)

El script de la raíz del repositorio detiene `irqbalance`, elige CPUs del nodo NUMA de la NIC (salvo el CPU 0) y, para cada interfaz:

1. Deja una sola cola: `ethtool -L <if> combined 1`.
2. Fija todas las IRQs de la interfaz en su CPU.
3. Desactiva RPS para que el kernel no mueva el procesado a otro core.

```bash
sudo bash pin_irqs.sh
```

La versión del commit está configurada para el segundo PC (`IFACES` = `enp2s0f0` … `enp2s0f3`). Para usarlo en otro equipo hay que cambiar esa lista por sus interfaces.

Para que se mantenga al reiniciar:

```bash
sudo systemctl disable irqbalance
sudo cp pin_irqs.sh /usr/local/sbin/ && sudo chmod +x /usr/local/sbin/pin_irqs.sh
sudo tee /etc/systemd/system/pin-irqs.service >/dev/null <<'EOF'
[Unit]
Description=Pin NIC IRQs one core per interface
After=network-online.target NetworkManager.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pin_irqs.sh

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl enable --now pin-irqs.service
```

Para deshacerlo: `ethtool -L <if> combined <N>` con el valor original (`ethtool -l <if>`) y `systemctl start irqbalance`.

### Ajustes adicionales de la NIC y del kernel

Ayudan con tramas pequeñas; con tramas jumbo no son imprescindibles.

```bash
IF=enp4s0f0np0
sudo ethtool -G $IF rx 4096                  # ring RX al máximo (ethtool -g)
sudo ethtool -C $IF adaptive-rx off rx-usecs 100
sudo ethtool -A $IF rx off tx off            # sin pause frames
sudo ethtool -N $IF rx-flow-hash udp4 sdfn   # RSS con puertos

sudo sysctl -w net.core.rmem_max=268435456
sudo sysctl -w net.core.rmem_default=268435456
sudo sysctl -w net.core.netdev_max_backlog=250000
sudo sysctl -w net.core.netdev_budget=600
sudo cpupower frequency-set -g performance
```

En la aplicación receptora: `SO_RCVBUF` grande (por ejemplo 256 MB) y cada hilo fijado con `taskset` en un core distinto del de su IRQ, pero en el mismo nodo NUMA.

### Comandos de diagnóstico

| Para qué | Comando |
|---|---|
| Ver las tramas | `tcpdump -i <if> -e -nn udp port 5005` |
| Tasa por interfaz | `bmon` |
| Pérdidas en la NIC (`i40e`) | `ethtool -S <if> \| grep -E "^\s+(rx_packets\|port.rx_dropped\|rx_dropped):"` |
| Pérdidas en el socket | `netstat -su \| grep -iE "receive errors\|buffer errors"` |
| Cola RX activa | `ethtool -S <if> \| grep -E "rx-[0-9]+\.packets"` |
| CPU por core (columna `%soft`) | `mpstat -P ALL 1` |
| Qué core procesa NET_RX | `watch -d -n1 "grep -E 'CPU\|NET_RX' /proc/softirqs"` |
| CPU de la aplicación por hilo | `pidstat -u -t -p <pid> 1` |
| Desglose por función | `sudo perf top -g` |
| Enlace PCIe de la NIC | `sudo lspci -s <bus> -vv \| grep -E "LnkCap:\|LnkSta:"` (bus con `ethtool -i <if>`) |

Interpretación de `port.rx_dropped`: si crece y un core tiene `%soft` cerca del 100 %, el límite es la CPU. Si crece sin CPU saturada, la NIC no consigue mover los datos a memoria (PCIe, IOMMU o ahorro de energía).

## 6. Pendiente

### Rendimiento

- **Segundo PC, menos potente**: no llega a tasa de línea y no muestra `%soft` saturado. Lo primero es comprobar el enlace PCIe (`LnkSta` frente a `LnkCap`): cuatro puertos de 10G necesitan ~40 Gb/s, y una ranura Gen3 x4 o Gen2 x8 se queda en ~31–32 Gb/s útiles.
- **Repartir un mismo carril entre varios cores**: rotar el puerto origen en la FSM de metadatos (por ejemplo `src_port + contador[1:0]`) con el destino fijo en 5005. En el PC, `rx-flow-hash udp4 sdfn` y sockets con `SO_REUSEPORT`. El orden solo se mantiene dentro de cada sub-flujo: para reconstruir la secuencia LFSR haría falta un número de secuencia en el payload.

### Funcionalidad

- **RX (etapa 3)**: el RX del QSFP se descarta (`tready = 1`) y `qsfp_rx_act` está a 0, así que la indicación de tramas recibidas en el LED 3 (etapa 1, parte 4) ya no parpadea. Se recuperará en la etapa 3, que implementará la parte RX de Zircon (`zircon_ip_rx_ingress`, `zircon_ip_rx_parse`, `zircon_ip_rx_egress`).
- Los comentarios de cabecera de `udp_packet_generator_top.sv` y de la instancia en `fpga_core.sv` hablan de 25G y 100G y no corresponden al uso actual (32 bits a 10G).
- `MAC_DATA_W` del generador no se usa: el ancho real lo toma `zircon_ip_tx_egress` de la interfaz `m_axis_mac_tx`.

### Limpieza del commit

- `vitis/Andromeda_SOM/platform.tcl` tiene `platform generate` repetido seis veces al final, probablemente añadido por la GUI de Vitis.
- `src/axis/rtl/Table.xlsx` está dentro de un directorio de RTL.
