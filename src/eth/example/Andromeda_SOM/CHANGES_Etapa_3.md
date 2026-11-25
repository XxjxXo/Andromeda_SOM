# Enlace 100GBASE-SR4 con la CMAC y generador UDP a 100 Gb/s

Este documento recoge los cambios respecto al commit `aa6f080` ("Zircon udp RX datapath not yet tested"): el commit `8795396` ("100Gbps with UDP/IP Working") y, sobre él, el reparto del tráfico en 8 flujos UDP (apartado 3.8). La etapa 2 dejaba el generador UDP funcionando a 4 × 10G con el PHY de Taxi. En esta etapa se pasa a un único enlace de 100G con la MAC hard (CMAC) del dispositivo.

- **Hardware destino**: SOM Enclustra Andromeda XZU90 (XCZU17EG-1FFVD1760E) sobre placa base Andromeda PE5.
- **Función**: un enlace 100GBASE-SR4 (4 × 25,78125 Gb/s NRZ, RS-FEC CL91) por el QSFP28 de la PE5. El generador UDP de la etapa 2 transmite tramas jumbo con payload PRBS31 a velocidad de línea.
- **Configuración construida**: `fpga` (CMACE4_X0Y1, bus LBUS de 512 bits a 322,266 MHz, GTY con buffer de TX: `CFG_LOW_LATENCY = 0`). Se compila con `./build_100g.sh`.
- **Equipo remoto**: PC con NVIDIA ConnectX-6 Dx MCX623106AN-CDA (QSFP56, driver `mlx5_core`, firmware 22.43.2566), interfaz `enp4s0f0np0`, módulos FS QSFP-SR4-100G y latiguillo MTP/MPO-12 tipo B.
- **Estado**: enlace `Active` a 100G con RS-FEC. El PC recibe y comprueba el payload completo, repartido en 8 flujos: **99,22 Gb/s** de payload UDP (el 99,95 % del máximo teórico) y **0 errores** en 1,58·10¹² bits (BER < 1,9·10⁻¹² con un 95 % de confianza). BER bruto antes del FEC: 1·10⁻¹¹. Ver parte 6. Las medidas se hicieron con la ecualización de TX aplicada desde el VIO; ya está fijada en el build (`diffctrl` 20, post-cursor 16, ver 3.4), pendiente de probar en placa sin el VIO.

Las rutas son relativas a `src/eth/example/Andromeda_SOM/fpga/` salvo que se indique otra cosa.

## 1. Ficheros modificados

### Diseño del ejemplo

| Fichero | Cambio |
|---|---|
| `fpga/Makefile` | Adaptado al XCZU17EG (`FPGA_PART`, `FPGA_ARCH`). Añade el block design del PS, el generador y la pila Zircon, las IPs de depuración (`ila_cmac`, `vio_cmac`) y `syn/debug.xdc`. Eliminados los objetivos `flash`/`mcs` de la VCU118. |
| `fpga/config.tcl` | `CFG_LOW_LATENCY` de `1` a `0` (GTY con buffer de TX, ver 3.5). |
| `rtl/fpga_core.sv` | LEDs de depuración del TX, ecualización de TX del GT fijada a `diffctrl` 20 y post-cursor 16 (3.4), quitado el `BUFG_GT` de la refclk (3.6), bloque de depuración con VIO, dos ILAs y contadores de frecuencia (parte 4), y `FLOW_CNT = 8` en el generador de 100G (3.8). |
| `rtl/udp_packet_generator_top.sv` | Nuevo parámetro `FLOW_CNT` (1 por defecto): el puerto destino rota paquete a paquete entre `dest_port` y `dest_port + FLOW_CNT − 1` (3.8). |
| `rtl/fpga.sv` | Nuevo significado de los LEDs 2 y 3 (parte 4). |
| `syn/eth_cmac.xdc` | Solo la CMAC `CMACE4_X0Y1`, la más cercana a los GTY X0Y8–X0Y11. |
| `syn/debug.xdc` | **Nuevo**. Fija el reloj del `dbg_hub` a `clk_125mhz`. |
| `ip/ila_cmac.tcl`, `ip/vio_cmac.tcl` | **Nuevos**. IPs de depuración. |
| `build_10g.sh` | Admite como argumento el directorio de build (`fpga_10g` por defecto, o `fpga`). |
| `build_100g.sh` | **Nuevo**. Llama a `build_10g.sh fpga`. |
| `udp_lfsr_rx.c` | **Nuevo**. Receptor UDP y comprobador del PRBS31 para el PC, con un hilo por flujo (parte 7). |
| `doc/Medidas.md`, `doc/BMON_100Gbps.png` | **Nuevos**. Medidas en el PC. |
| `doc/rxtx_10g_loopback.tex` | **Nuevo**. Diagrama TikZ del loopback de la etapa 1 (FIFO asíncrona RX → TX por carril). |
| `doc/tx_10g_dataflow.tex` | **Nuevo**. Diagrama TikZ del flujo de TX a 4 × 10G (etapa 2). |
| `doc/tx_100g_dataflow_1_flux.tex`, `doc/tx_100g_dataflow_8_flux.tex` | **Nuevos**. Diagramas TikZ del flujo de TX a 100G, con un flujo UDP y con 8 flujos (puerto destino rotativo y reparto en el PC). |

### Librería Taxi (`src/eth/rtl/us/`, fuera del ejemplo)

Todos los puertos nuevos tienen valor por defecto: los demás diseños que usan el MAC de 100G no cambian de comportamiento, salvo por la corrección del pre/post-cursor.

| Fichero | Cambio |
|---|---|
| `taxi_eth_mac_100g_us_gty_{156,161,322}.tcl` | Habilitan los puertos `loopback_in` y `txprbssel_in` del GTY. |
| `taxi_eth_mac_100g_us_gt.sv`, `taxi_eth_mac_100g_us_gt_ll.sv` | **Corrección**: `txprecursor_in` y `txpostcursor_in` estaban conectados cruzados. Puertos nuevos `gt_loopback_in` y `gt_tx_dbg_in` (ecualización de TX y PRBS en tiempo de ejecución). |
| `taxi_eth_mac_100g_us_ch.sv` | Pasa los puertos nuevos a las dos variantes del GT. |
| `taxi_eth_mac_100g_us.sv` | Entradas `gt_loopback_in` y `gt_tx_dbg_in`, y salidas `dbg_cmac_rx_stat` (64 bits) y `dbg_cmac_tx_stat` (8 bits) con el estado de la CMACE4. El mapa de bits está comentado en la declaración de los puertos. |

### Vitis (raíz del repo)

| Fichero | Cambio |
|---|---|
| `zynqmp_fsbl/peripherials_cfg_init.h` | **Corrección**: tabla del expansor PCAL6416A 0x20 con `QSFP_LPMODE = 0` (ver 3.1). Defines y prototipo del diagnóstico del QSFP. |
| `zynqmp_fsbl/peripherials_cfg_init.c` | Nueva función `qsfp_diag_main()` (ver 3.2). |
| `zynqmp_fsbl/xfsbl_hooks.c` | Llama a `qsfp_diag_main()` en `XFsbl_HookAfterBSDownload`. No detiene el arranque si falla. |
| `platform.spr`, `hw/fpga.xsa` | Apuntan al `.xsa` del build `fpga` (100G). |
| `platform.tcl` | La GUI de Vitis ha vuelto a añadir líneas `platform generate` repetidas (ya son 17). |

## 2. Configuración del enlace de 100G

| Elemento | Valor |
|---|---|
| MAC | CMACE4 (hard), `CMACE4_X0Y1` |
| Interfaz de usuario | LBUS de 512 bits a 322,266 MHz |
| GTY | 4 carriles, `GTYE4_CHANNEL_X0Y8`–`X0Y11` (banco 129), 25,78125 Gb/s cada uno |
| Refclk | 156,25 MHz (Si5395, salida `QSFP_CLK0`), QPLL0 fraccional × 82,5 (IP `taxi_eth_mac_100g_us_gty_156`) |
| Interfaz CMAC ↔ GT | 80 bits por carril a 322,266 MHz (25,78125 G / 80) |
| FEC | RS-FEC CL91, RS(528,514), siempre activado en el wrapper de Taxi |
| Autonegociación | No (la CMAC no la implementa): el PC tiene que ir en modo forzado |

El bus de 512 bits a 322 MHz (165 Gb/s) supera los 100 Gb/s porque la CMAC necesita margen para las inserciones del PCS y del RS-FEC (marcadores de alineamiento, transcodificación) y para no tener que llenar todas las palabras. No es un error del ejemplo original.

## 3. Problemas encontrados y su solución

En orden cronológico. Cada apartado resume el síntoma, cómo se diagnosticó y qué se cambió.

### 3.1 El módulo QSFP28 de la FPGA no emitía luz

**Síntoma**: el PC no recibía potencia óptica (alarmas de RX power low en los 4 canales).

**Causa**: la tabla del expansor PCAL6416A 0x20 que escribe el FSBL configuraba todo el puerto 1 como salida a 1. El pin P1_0 es `QSFP_LPMODE`: con `LPMODE = 1`, un módulo activo (SR4) se queda en modo de bajo consumo con los láseres apagados. Con el QSFP+ y el cable breakout de la etapa anterior no se notaba.

**Solución** (`peripherials_cfg_init.h`):

| Registro | Antes | Ahora |
|---|---|---|
| `0x03` (salidas puerto 1) | `0xFF` | `0xFE`: `QSFP_LPMODE = 0` |
| `0x07` (dirección puerto 1) | `0x00` (todo salida) | `0xFE`: P1_0 salida, P1_1–P1_7 entradas (P1_1 es `QSFP_MODPRS#`) |

Los valores de salida se escriben ahora antes que la dirección, para que los pines nunca saquen el valor anterior.

### 3.2 Diagnóstico del módulo por I2C desde el FSBL

Para separar problemas del módulo de problemas del enlace se añadió `qsfp_diag_main()`, que se ejecuta después de cargar el bitstream y saca por UART:

1. El puerto 1 del expansor 0x20 (`QSFP_LPMODE` y `QSFP_MODPRS#`).
2. Tras 2 s de espera (`QSFP_DIAG_DELAY_S`, inicialización del módulo y del GT), selecciona el canal 4 del mux 0x75 de I2C1 y la página 0 del módulo (0x50).
3. Lee la página baja dos veces (flags acumulados y actuales) y la página alta, según SFF-8636: identificador y compliance, fabricante, part number, número de serie, bytes 2, 86, 93 y 98, temperatura, Vcc, y por canal LOS, LOL, TX fault, TX disable, bias, potencia de TX y potencia de RX.

Solo escribe el selector de página. Las lecturas van en bloques de 16 bytes (profundidad de la FIFO del I2C del PS).

### 3.3 El PC intentaba modos PAM4

**Síntoma**: con autonegociación desactivada desde `ethtool`, el PC seguía en `Polling`.

**Causa**: la ConnectX-6 Dx es QSFP56. El driver `mlx5` habilita todos los modos de 100G, incluido `100G_2X` (2 × 50G PAM4), que la CMAC no habla. NetworkManager además volvía a fijar la velocidad.

**Solución** (en el PC): forzar solo `100G_4X` con RS-FEC desde `mlxlink`, y dejar la velocidad vacía en el perfil de NetworkManager (ver parte 5). El módulo QSFP28 en la jaula QSFP56 es compatible: 4 × 25G NRZ es uno de los modos de la tarjeta.

### 3.4 Enlace en `Polling` con todo lo óptico correcto: ecualización de TX

Era el problema principal. Con 3.1 y 3.3 resueltos:

- FPGA ← PC: la CMAC de la FPGA se alineaba (con RS-FEC).
- FPGA → PC: el PC recibía unos +0,3 dBm por carril, la CDR de RX de su módulo enganchaba, sin LOS ni LOL. Pero se quedaba en `Polling`, `Physical state: ETH_AN_FSM_ENABLE`, `Status Opcode 36 (PHY FW): Other issues`.

**Hipótesis descartadas, por orden:**

| Hipótesis | Cómo se descartó |
|---|---|
| Driver o firmware viejos | Firmware 22.43.2566 (febrero de 2025) y kernel 6.8: al día. |
| Módulo o latiguillo | Con los dos módulos en el PC (PC↔PC) el enlace subía a `Active`. |
| Frecuencia del QPLL0 fraccional | Contadores de frecuencia en la FPGA (parte 4): TX de la FPGA y RX recuperado del PC difieren **32 ppm**. La norma admite ±100 ppm en cada extremo. |
| Datos de la CMAC (PCS, RS-FEC) | Loopback near-end PMA del GTY: la CMAC se alinea con su propio TX, con `am_lock` de RS-FEC en los 4 carriles. La lógica genera un 100GBASE-R válido. |
| Polaridad invertida en la placa | Esquemáticos: `MGT_B129_TXn_P` → `MGT_W2_TXn_P` (SOM) → `QSFP_TXn+1_P` (PE5). Todo directo. |
| Fase del TX en modo sin buffer | Se pasó a `CFG_LOW_LATENCY = 0` (ver 3.5). No cambió nada. |

**Causa**: lo único que el loopback near-end no recorre es el tramo eléctrico de TX: el driver del GTY, las pistas de la SOM, el conector a la PE5, las pistas de la PE5 y el conector del QSFP28. A 25,78 Gb/s (Nyquist a 12,9 GHz) ese canal atenúa mucho las altas frecuencias y cierra el ojo. La CDR del módulo se engancha igualmente, pero retransmite demasiados errores para el RS-FEC. Con la ecualización por defecto de Taxi (`diffctrl` 16, post-cursor 0, pre-cursor 0), el ojo llegaba cerrado.

**Solución**: subir el **post-cursor** (de-énfasis) de la FFE de TX del GTY. Resta al bit actual una fracción del anterior: los bits repetidos salen con menos amplitud y las transiciones con la amplitud completa. Funciona como un filtro paso-alto que compensa el paso-bajo del canal. Los valores se encontraron barriendo desde el VIO en modo far-end PMA y modo normal (parte 4), y se han fijado en `fpga_core.sv` para los 4 carriles:

| Parámetro | Taxi por defecto | Ahora |
|---|---|---|
| `GT_TX_DIFFCTRL` (amplitud) | 16 | **20** |
| `GT_TX_POSTCURSOR` (de-énfasis) | 0 | **16** |
| `GT_TX_PRECURSOR` | 0 | 0 |

Por qué no se había visto antes:

- **En el sentido PC → FPGA**, el RX del GTY está en modo DFE, que ecualiza solo. La entrada eléctrica de TX del módulo no tiene ecualizador adaptativo (`Cable Tx Equalization: 0`).
- **A 10G** (Nyquist a 5,2 GHz) las pérdidas del mismo canal son mucho menores.
- **La prueba anterior con "post-cursor 8"** aplicó en realidad pre-cursor 8, por el error de Taxi descrito a continuación.

**Error en Taxi**: en `taxi_eth_mac_100g_us_gt.sv` y `taxi_eth_mac_100g_us_gt_ll.sv` estaban conectados `.txprecursor_in(ctrl_txpostcursor)` y `.txpostcursor_in(ctrl_txprecursor)`. Corregido en el 100G. El mismo cruce sigue en `taxi_eth_phy_25g_us_gt_ll.sv` (lo usa el build de 10G), donde no se ha tocado: con los cursores a 0 no tiene efecto.

### 3.5 `CFG_LOW_LATENCY = 0`

Con `CFG_LOW_LATENCY = 1` el GTY transmite sin buffer de TX y necesita alinear la fase entre el reloj de usuario y el serializador. Se cambió a `0` (IP `taxi_eth_mac_100g_us_gty_full`/`_ch`, con buffer) como hipótesis para 3.4. No era la causa, pero se ha mantenido: es la configuración con la que se ha validado el enlace. Cuesta unos ciclos de latencia.

El valor que cuenta es el de `fpga/config.tcl`, que sobrescribe el valor por defecto de `fpga.sv`.

### 3.6 Error de rutado con el GT con buffer

**Síntoma**: `route_design` terminaba con *"Design has 2 unroutable pins"* en el `BUFG_GT` de la refclk (`bufg_gt_qsfp1_mgt_refclk_0_inst`).

**Causa**: ese `BUFG_GT` tenía `CE = &qsfp_gtpowergood`. En el IP con buffer, `gtpowergood` sale de un flip-flop de lógica (retardo de power-good del wizard), y los pines CE/CLR de un `BUFG_GT` solo son accesibles a través de un `BUFG_GT_SYNC`. En la posición elegida por el placer no quedaba ninguno libre.

**Solución**: el `BUFG_GT` solo daba reloj al sincronizador de `qsfp_rst`, y `qsfp_rst` va a `xcvr_ctrl_rst`, cuyo reloj es `clk_125mhz`. Se eliminó el `BUFG_GT` y `qsfp_rst` se sincroniza con `clk_125mhz`. Afecta también al build de 10G, sin consecuencias.

Los critical warnings *"Could not find module `taxi_eth_mac_100g_us_gty_ll_full`/`_ll_ch`"* que quedan en el log son normales: el IP de baja latencia se sigue generando pero ya no se usa.

### 3.7 Falsos errores al comprobar el PRBS31 en el PC

**Síntoma**: el comprobador daba un BER de 1·10⁻² en todos los paquetes, unos 2150 errores por paquete de 8960 B (`doc/Medidas.md`). Se atribuyó a que el enlace era demasiado rápido para un único flujo, pero eso no puede ser: la comprobación se hace dentro de cada paquete y no le afectan los paquetes perdidos.

**Causa**: `taxi_lfsr` desplaza **MSB primero** ("Shifts MSB first by default"). En cada palabra de 512 bits del generador, el bit 511 es el primero de la secuencia en el tiempo. En cambio, la MAC transmite primero `tdata[7:0]`. Dentro de cada bloque de 64 bytes del payload la secuencia va invertida. La recurrencia del PRBS31 solo fallaba en las 139 fronteras entre palabras (unos 15 errores por frontera).

**Solución**: `udp_lfsr_rx.c` invierte los bits de cada bloque de `DATA_W/8` bytes antes de comprobar (64 B en 100G, 4 B en 10G) y detecta el tamaño de bloque en el primer paquete (`-w` para forzarlo). Validado con el paquete capturado en `doc/Medidas.md`: **0 errores** con bloques de 64 B, frente a 120 errores en 8 fronteras sin invertir. Repetida la medida con esta versión: 0 errores (parte 6).

### 3.8 El PC no recibe 100 Gb/s en un socket

**Síntoma**: el primer comprobador, en Python, recibía unos 4 Gb/s; la versión en C, entre 35 y 46 Gb/s.

**Causa**: el generador enviaba un único flujo UDP (misma 5-tupla en todos los paquetes). La NIC reparte el tráfico entre colas de RX por flujo, así que todo caía en una sola cola y en un solo core, que no da más. La FPGA ya transmitía a velocidad de línea: los contadores de la NIC y `bmon` lo mostraban (parte 6).

**Solución**:

1. **Comprobador en C** (`udp_lfsr_rx.c`): `recvmmsg` por lotes y comprobación del PRBS31 con palabras de 64 bits (unos 78 Gb/s por core con la inversión de bloques). Así el comprobador deja de ser el límite.
2. **8 flujos en el generador** (`udp_packet_generator_top.sv`, parámetro `FLOW_CNT`): el puerto destino rota paquete a paquete entre 5005 y 5012. Se varía el destino, y no el origen, para que cada hilo del receptor escuche en su propio puerto, sin depender del hash del kernel. El deparser de Zircon suma los puertos al checksum UDP a partir de los metadatos, así que el checksum sigue siendo correcto. En `fpga_core.sv`, `FLOW_CNT = 8` en 100G y 1 en 10G (un flujo por carril, como en la etapa 2).
3. **En el PC**, una regla ntuple por puerto lleva cada flujo a su cola, y `udp_lfsr_rx -j 8 -c 8` atiende cada puerto con un hilo fijado a un core distinto de los de las interrupciones (parte 5). Cada flujo lleva unos 12,4 Gb/s.

La palabra 12 de metadatos tiene el puerto destino en `[15:0]` y el origen en `[31:16]` (comprobado en `test_zircon_ip_tx_deparse.py`). Hasta ahora no se había podido verificar porque los dos valían 5005.

## 4. Infraestructura de depuración

### LEDs

| LED | Significado |
|---|---|
| LED 2 | Parpadea a ~1,2 Hz si corre el reloj de usuario de TX del GT (QPLL0 enganchado). Fijo en otro caso. |
| LED 3 | Apagado: GT sin power good (o PL sin configurar). Parpadeo lento (~1 Hz): TX en reset. Encendido: TX fuera de reset, RX sin alinear. Parpadeo rápido (~7,5 Hz): TX fuera de reset y RX alineado. |

### VIO (`vio_cmac`, reloj `clk_125mhz`)

| Probe | Ancho | Función |
|---|---|---|
| `probe_in0` | 32 | Ciclos del reloj de TX por ventana de 2²⁷ ciclos de `clk_125mhz` (1,0737 s). A 322,265625 MHz: **346 030 080** (1 ppm ≈ 346). |
| `probe_in1` | 32 | Lo mismo con el reloj de RX (recuperado del PC). (`in0` − `in1`) / 346 = ppm entre la FPGA y el PC, independiente del error de la referencia. |
| `probe_in2` | 16 | `[0]` status, `[1]` aligned, `[2]` aligned_err, `[3]` misaligned, `[4]` hi_ber, `[5..8]` faults, `[9]` rsfec_hi_ser, `[10]` rsfec_lane_align, `[14:11]` rsfec_am_lock, `[15]` rx_rst |
| `probe_in3` | 2 | `[0]` tx_local_fault, `[1]` tx_rst |
| `probe_in4` | 1 | gtpowergood |
| `probe_out0` | 3 | Loopback del GT: 0 normal, 2 near-end PMA, 4 far-end PMA. No usar 6 (far-end PCS): necesita corrección de reloj, que en modo raw no hay. |
| `probe_out1` / `probe_out2` | 1 | Reset de RX / de TX (pulso 1 → 0 después de cambiar el loopback). |
| `probe_out3` / `4` / `5` | 5 | `txdiffctrl` / `txpostcursor` / `txprecursor` para los 4 carriles. |
| `probe_out6` | 1 | 1 = aplicar `probe_out3..5`; 0 = parámetros del build. |
| `probe_out7` | 4 | TX PRBS: 0 = datos de la CMAC, 5 = PRBS31. |

Todos los cruces de dominio pasan por `taxi_sync_signal`, que trae sus propias restricciones de timing.

### ILAs (`ila_cmac`, 64 bits × 4096)

- **RX** (reloj `qsfp_rx_clk`): `dbg_cmac_rx_stat` completo. Trigger útil: flanco de subida de `probe0[1]` (aligned).
- **TX** (reloj `qsfp_tx_clk`): `probe0[0]` `tx_local_fault`, `[1]` paquetes buenos, `[2]` `tx_ovfout`, `[3]` `tx_unfout`, `[8]` `tx_rst`.

`syn/debug.xdc` conecta el `dbg_hub` a `clk_125mhz`: si no, Vivado puede elegir un reloj del GT y Hardware Manager pierde todos los cores al resetear el RX.

### Uso

Con la placa arrancada desde `BOOT.bin`: Hardware Manager → Open Target, sin programar (el bitstream lo carga el FSBL), cargar `fpga/fpga.runs/impl_1/fpga.ltx` y Refresh.

Resultados de las pruebas de esta etapa:

| Prueba | Resultado |
|---|---|
| Frecuencia | 32 ppm entre la FPGA y el PC |
| Near-end PMA | Alineado, `am_lock` en los 4 carriles |
| Far-end PMA con ecualización por defecto | El PC no sube (no concluyente) |
| Far-end PMA / normal subiendo el post-cursor | `Active` |

## 5. Configuración del PC

### NIC en modo forzado

La configuración de `mlxlink` no sobrevive a un reinicio del PC ni a un reset de la tarjeta.

```bash
DEV=04:00.0
sudo mlxlink -d $DEV --test_mode DS                        # por si quedó el modo PRBS
sudo mlxlink -d $DEV --speeds 100G_4X --link_mode_force    # sin 100G_2X ni autoneg
sudo mlxlink -d $DEV --fec RS --fec_speed 100G_4X          # RS-FEC CL91
sudo mlxlink -d $DEV -a TG                                 # reiniciar el enlace
sudo mlxlink -d $DEV                                       # State: Active, FORCE - 100G_4X
```

No usar `ethtool -s ... autoneg off`: vuelve a habilitar los modos 100G_2X.

### Interfaz

```bash
IF=enp4s0f0np0
sudo nmcli con mod "<perfil>" 802-3-ethernet.speed 0 802-3-ethernet.duplex "" \
    ipv4.method manual ipv4.addresses 10.0.0.1/24 802-3-ethernet.mtu 9000
sudo nmcli con up "<perfil>"
```

MTU 9000 para el payload de 8960 B (ver la etapa 2, parte 4).

### Un flujo por cola y por core

```bash
IF=enp4s0f0np0

# 1. Que haya al menos 8 colas, y en qué nodo NUMA está la tarjeta
ethtool -l $IF
cat /sys/class/net/$IF/device/numa_node; lscpu | grep NUMA

# 2. Fijar cada flujo a una cola (sin esto, RSS reparte por hash y dos flujos pueden caer en la misma cola)
sudo ethtool -K $IF ntuple on
for i in $(seq 0 7); do sudo ethtool -N $IF flow-type udp4 dst-port $((5005+i)) action $i; done
ethtool -n $IF                                   # muestra las reglas

# 3. Ver en qué CPU procesa cada cola su interrupción
grep mlx5_comp /proc/interrupts | head -8

# 4. Receptor: hilos en cores distintos de los de las interrupciones, en el mismo nodo NUMA
sudo sysctl -w net.core.rmem_max=268435456
sudo ./udp_lfsr_rx -j 8 -c 8 -t 60
```

En el PC de prueba, las colas 0–7 atienden sus interrupciones en las CPUs 0–7, y los hilos del receptor van a las CPUs 8–15. Si un puerto se queda por debajo del resto, `mpstat -P ALL 1` muestra qué core se satura. Las reglas se quitan con `sudo ethtool -N $IF delete <id>` (los id los da `ethtool -n`).

Anillo de RX y coalescencia: no hacen falta con los 8 flujos. Para volver a los valores por defecto de `mlx5`:

```bash
sudo ethtool -G $IF rx 1024
sudo ethtool -C $IF adaptive-rx on
```

### Diagnóstico

| Para qué | Comando |
|---|---|
| Estado del enlace | `sudo mlxlink -d 04:00.0` (`State`, `Physical state`, `Status Opcode`) |
| Módulo: potencias, CDR, LOS/LOL | `sudo mlxlink -d 04:00.0 -m` |
| BER y contadores físicos | `sudo mlxlink -d 04:00.0 -c` |
| FEC | `sudo mlxlink -d 04:00.0 --show_fec` |
| Seguir el estado en directo | `sudo watch -n1 "mlxlink -d 04:00.0 \| grep -E 'State\|Physical state\|Opcode'"` |
| Tasa en la interfaz | `bmon -p enp4s0f0np0` |
| Contadores de la NIC | `ethtool -S enp4s0f0np0 \| grep -E "rx_bytes_phy\|rx_packets_phy\|rx_crc_errors_phy\|rx_out_of_buffer"` |
| Checksum UDP | `nstat -az \| grep -E "UdpInDatagrams\|UdpInCsumErrors"` |
| Temperatura de la NIC | `sudo mget_temp -d 04:00.0` |

El `dmesg` del PC muestra avisos de temperatura alta en la ConnectX (`temp_warn ... High temperature`). Necesita ventilación forzada.

## 6. Rendimiento

`bmon` mide **12,46 GB/s** en recepción (`doc/BMON_100Gbps.png`). Como en la etapa 2, cuenta la trama sin preámbulo, FCS ni IFG: payload + 42 B por paquete.

| Concepto | Bytes por trama |
|---|---|
| Contados por `bmon` (Ethernet + IP + UDP + payload) | 42 + 8960 = 9002 |
| En la línea (+ preámbulo 8, FCS 4, IFG 12) | 9026 |

Máximo teórico: 100 Gb/s / 8 × 9002 / 9026 = **12,47 GB/s**. La FPGA transmite a velocidad de línea.

En la misma captura, `Dropped` (684 k) y `Missed Error` (4,25 M) son paquetes que el PC no conseguía procesar con un único flujo (ver 3.8), no errores del enlace. El único `CRC Error` es de la fase de puesta en marcha.

### Recepción y comprobación del payload completo

Con 8 flujos y `udp_lfsr_rx -j 8 -c 8` (`doc/Medidas.md`):

| Medida | Valor |
|---|---|
| Paquetes por segundo | 1 384 200 (unos 173 000 por puerto) |
| Payload UDP recibido | **99,22 Gb/s** (12,4 Gb/s por puerto) |
| Máximo teórico | 100 Gb/s / (9026 × 8 bits) = 1 384 888 paquetes/s → 99,27 Gb/s de payload |
| Errores de payload | **0** en 22 077 155 paquetes (1,58·10¹² bits) |
| BER (cota, 95 % de confianza) | < 1,9·10⁻¹² |

El PC recibe y comprueba el 99,95 % de los paquetes que caben en la línea, todos sin errores.

Con un único flujo (antes de 3.8), la recepción se quedaba en 35–46 Gb/s, también con 0 errores (BER < 4,6·10⁻¹²).

### BER del enlace (`mlxlink -c`)

| Contador | Valor |
|---|---|
| Effective Physical Errors (después del RS-FEC) | 0 |
| Raw Physical BER (antes del RS-FEC) | 1·10⁻¹¹ |
| Raw Physical Errors por carril | 2538, 133, 0, 0 |

El RS-FEC (528,514) corrige hasta un BER bruto de unos 2·10⁻⁴: hay unos 7 órdenes de magnitud de margen. Los carriles 0 y 1 tienen algo menos de margen que el 2 y el 3, porque la ecualización del VIO es la misma para los cuatro. No hace falta ajustarla por carril. Los errores brutos son acumulados desde el último borrado de contadores (`Time Since Last Clear`).

## 7. Comprobador en el PC (`udp_lfsr_rx.c`)

```bash
gcc -O3 -march=native -pthread -o udp_lfsr_rx udp_lfsr_rx.c
./udp_lfsr_rx -T                     # autoprueba sin red
sudo sysctl -w net.core.rmem_max=268435456
sudo ./udp_lfsr_rx -j 8 -c 8         # 8 flujos; Ctrl-C para parar
```

| Opción | Función |
|---|---|
| `-p` | Primer puerto UDP (5005 por defecto) |
| `-j N` | N hilos: el hilo i escucha en el puerto `p + i` (uno por flujo) |
| `-c CPU` | Fija el hilo i al core `CPU + i` |
| `-s N` | Comprueba 1 de cada N paquetes, pero cuenta todos |
| `-t S` | Termina a los S segundos |
| `-w B` | Tamaño de bloque a invertir (64 en 100G, 4 en 10G, 0 ninguno); por defecto se detecta |
| `-f fichero` | Comprueba un payload guardado en un fichero, sin red |

Comprueba en cada paquete la recurrencia b[n] = b[n−31] ⊕ b[n−28], que se sincroniza sola: los paquetes perdidos no dan falsos errores. Cada bit erróneo en el cable produce 3 errores en la recurrencia; el BER final ya está dividido entre 3.

Salida:

- Cada segundo: paquetes por segundo, Gb/s y errores en total, y con `-j` los Gb/s de cada puerto.
- Al final: paquetes y errores por puerto, y el BER. Si no hay errores, da la cota superior con un 95 % de confianza: BER < 3 / bits comprobados.

La autoprueba (`-T`) genera paquetes como el generador para anchos de palabra de 8, 32, 64 y 512 bits, comprueba que se detecta el tamaño de bloque correcto y que un bit invertido da 3 errores. También se probó con 8 flujos por la interfaz local, con errores inyectados en un solo puerto.

## 8. Pendiente

### Diseño

- **Probar el build con la ecualización fija** (20/16/0, ver 3.4) sin el override del VIO (`probe_out6 = 0`), y comprobar que el enlace sube solo al arrancar.
- **Decidir si se vuelve a `CFG_LOW_LATENCY = 1`** con la ecualización corregida, o si se mantiene el GT con buffer.
- **Quitar o dejar opcional la depuración** (VIO, ILAs, `debug.xdc`) con un parámetro, como indica el commit `8795396`.
- **Corregir el cruce pre/post-cursor en `taxi_eth_phy_25g_us_gt_ll.sv`**, y comprobar que el build de 10G no cambia.
- **RX de 100G**: `udp_packet_receiver_top.sv` y `udp_payload_extractor.sv` (commit `aa6f080`) están en el Makefile pero no se instancian.

### Limpieza

- `vitis/Andromeda_SOM/platform.tcl`: 17 líneas `platform generate` repetidas.
- Los critical warnings del IP `_ll` sin usar: se pueden quitar generando solo las variantes necesarias.
