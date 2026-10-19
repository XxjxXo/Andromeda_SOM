#!/bin/bash
set -e
IFACES=(enp2s0f0 enp2s0f1 enp2s0f2 enp2s0f3)

# 1. Parar irqbalance para que no deshaga la asignación
systemctl stop irqbalance 2>/dev/null || true

# 2. CPUs del nodo NUMA de la NIC (salta el CPU 0, que es el que más interrupciones recibe)
NODE=$(cat /sys/class/net/${IFACES[0]}/device/numa_node)
[ "$NODE" -lt 0 ] && NODE=0
CPUS=($(lscpu -p=CPU,NODE | grep -v '^#' | awk -F, -v n=$NODE '$2==n && $1!=0 {print $1}'))
echo "NUMA node $NODE, CPUs disponibles: ${CPUS[*]}"

for idx in "${!IFACES[@]}"; do
    IF=${IFACES[$idx]}
    CPU=${CPUS[$idx]}

    # 3. Una sola cola por interfaz: el flujo cae siempre en ella
    ethtool -L "$IF" combined 1

    # 4. Fijar todas las IRQs de la interfaz a su CPU
    for irq in $(grep "$IF" /proc/interrupts | awk '{print $1}' | tr -d ':'); do
        echo "$CPU" > /proc/irq/$irq/smp_affinity_list
    done

    # 5. Desactivar RPS/XPS para que el kernel no mueva el procesado a otro core
    for q in /sys/class/net/$IF/queues/rx-*/rps_cpus; do echo 0 > "$q"; done

    echo "$IF -> CPU $CPU"
done
