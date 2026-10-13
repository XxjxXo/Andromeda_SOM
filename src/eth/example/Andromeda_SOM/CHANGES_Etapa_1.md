# Cambios para portar el ejemplo Ethernet de la VCU118 al Andromeda XZU90 + PE5

Este documento recoge todo lo que se ha modificado respecto al ejemplo original
`src/eth/example/VCU118` de Taxi (commit `cc70b27`) para obtener
`src/eth/example/Andromeda_SOM`.

- **Hardware destino**: SOM Enclustra Andromeda XZU90 (XCZU17EG-1FFVD1760E) sobre placa base Andromeda PE5.
- **Función**: loopback 10GBASE-R en los cuatro carriles del QSFP28 de la PE5.
- **Configuración construida**: `fpga_10g` (MAC de 32 bits, baja latencia, MAC+PCS combinados).
- **Estado**: las partes 1 y 2 están compiladas y cargadas en placa arrancando desde `BOOT.bin` (FSBL con los hooks que programan el Si5395). El cambio de los LEDs y la corrección del Si5395 de la parte 4 están compilados (timing cumplido) e incluidos en `Taxi/BOOT.bin` del 13-10-2026 a las 19:38, **pendiente de probar en placa**.

Las rutas son relativas a `src/eth/example/Andromeda_SOM/fpga/` salvo que se indique otra cosa.

## 1. Adaptación inicial (antes de la revisión)

### Estructura del proyecto

| Qué | Cambio |
|---|---|
| Directorio | `example/VCU118` se ha renombrado a `example/Andromeda_SOM` (git lo ve como borrado + directorio nuevo sin seguimiento). |
| `doc/` | Añadidos los esquemáticos de usuario del SOM (XZU90 R2.1) y de la PE5 (R1.1). |
| `bd/design_1/` | Block design nuevo con el Zynq UltraScale+ PS. Solo se usa su salida `pl_clk0` a 125 MHz. |
| `tb/fpga_core/baser.py` | El enlace simbólico se ha sustituido por una copia del fichero. |
| `fpga_10g/` | Contiene además el proyecto Vivado generado (`fpga.xpr`, `fpga.runs`, etc.). |

### Makefile (`fpga_10g/Makefile`)

- `FPGA_PART`: `xcvu9p-flga2104-2L-e` → `xczu17eg-ffvd1760-1-e`.
- `FPGA_ARCH`: `virtexuplus` → `zynquplus`.
- `fpga/Makefile` y `fpga_25g/Makefile` **no** se han tocado: siguen apuntando a la VCU118.

### Top-level (`rtl/fpga.sv`)

- **Reloj**: eliminados los puertos `clk_125mhz_p/n` y el `IBUFGDS`. El MMCM se alimenta ahora de `pl_clk0` del PS mediante la instancia `design_1`.
- **Puertos eliminados** (comentados): botones, switches, LEDs, I2C, UART, PHY SGMII, señales de control del QSFP1 y todo el QSFP2.
- **Puertos que quedaron**: `reset`, datos TX/RX del QSFP1 y `qsfp1_mgt_refclk_0_p/n`.
- **Entradas atadas a constante** dentro del top: botones y switches a 0, `uart_rxd`/`uart_rts` a 0, interfaz GMII del PHY a 0.
- **SGMII**: comentada la instancia `sgmii_pcs_pma_0` y el triestado de MDIO.
- **Control del QSFP1**: `modsell`, `resetl` y `lpmode` pasan a ser cables internos con valor fijo.

### Lógica (`rtl/fpga_core.sv`)

- `XFCP_ID_STR`: `"VCU118"` → `"ANDROMEDA_SOM"`.
- Eliminados (comentados) todos los puertos y asignaciones del QSFP2.
- Bucle de cuádruples GT: de 2 iteraciones a 1 (`n < 1`).
- Eliminadas las asignaciones de `qsfp1_modsell/resetl/lpmode` (ahora se fijan en el top).

### Restricciones (`syn/`)

| Fichero | Cambio |
|---|---|
| `qsfp.xdc` | Pines de datos del QSFP1 reasignados al banco GTY 129 (AD/AB/AC/AA 34–42). Señales de control del QSFP1 y todo el QSFP2 comentados. |
| `gpio.xdc` | Todo comentado excepto `reset`, movido a A15 con `LVCMOS33`. |
| `fpga.xdc` | Comentadas las opciones de configuración por SPI (`CFGBVS`, `CONFIG_VOLTAGE`, `SPI_*`, `EXTMASTERCCLK_EN`) y el reloj de 125 MHz LVDS. |
| `i2c.xdc`, `phy.xdc` | Comentados por completo. |
| `eth_cmac.xdc` | `CMACE4_X0Y7` → `CMACE4_X0Y1`; segunda línea comentada. No se usa en `fpga_10g`. |
| `ddr4_c1/c2`, `fmc`, `fmcp`, `pcie`, `pmod0/1`, `qspi` | Comentados por completo. No se usan en el Makefile. |

### Cambios fuera del directorio del ejemplo

Estos dos ficheros pertenecen a otras partes del repositorio y aparecen modificados en `git status`:

- `src/eth/rtl/taxi_eth_phy_10g_usxgmii_an.sv`: `PRESC_CYC = $rtoi(CYC_PER_US*100)` → `PRESC_CYC = CYC_PER_US*100`. Afecta a todos los diseños que usan esta PHY.
- `src/cndm/board/VCU118/fpga/rtl/fpga_core.sv`: `XFCP_ID_STR` cambiado a `"ANDROMEDA_SOM"`. Es el diseño de otra placa; parece un cambio accidental y convendría revertirlo.

## 2. Cambios de la revisión contra esquemáticos

### Correcciones de errores

| Fichero | Antes | Ahora | Motivo |
|---|---|---|---|
| `rtl/fpga.sv` | `mmcm_rst = reset` | `mmcm_rst = ~reset` | A15 es `BTN0#` de la PE5: activo a nivel bajo con pull-up. El MMCM quedaba en reset permanente. |
| `syn/qsfp.xdc` | Refclk P dentro de un comentario (faltaba un salto de línea) y N en AH33 | P en AD32, N en AD33 | Vivado lo había colocado en `MGTREFCLK0_128` (`SFP_SDI_CLK0`). El reloj del QSFP (`QSFP_CLK0`) entra por `MGTREFCLK0_129`. |
| `rtl/fpga_core.sv` | `wire [1:0] qsfp_gtpowergood` | `wire [0:0] qsfp_gtpowergood` | El bit del QSFP2 quedaba sin driver y el `CE` del `BUFG_GT` del refclk salía atado a GND en la netlist. |
| `rtl/fpga_core.sv` | `MAC_CNT = ... ? 2 : 8` | `MAC_CNT = ... ? 1 : 4` | Se generaban 4 FIFOs con relojes sin driver. |

### Limpieza de `FAMILY` y de `fpga_core.sv`

- `rtl/fpga.sv` y `rtl/fpga_core.sv`: valor por defecto de `FAMILY` cambiado de `"virtexuplus"` a `"zynquplus"`.
- `rtl/fpga_core.sv`: eliminados los restos del QSFP2 (puertos comentados, asignaciones comentadas, `STAT_PREFIX_STR_QSFP2` y los selectores `n == 0 ? ... : ...`).
- `rtl/fpga_core.sv`: `XFCP_PORTS` de `1+2` a `1+1`, `axis_eth_stat` de 3 a 2 entradas y buses internos `qsfp_tx/rx_p/n` de 8 a 4.
- Las constantes de `qsfp1_modsell/resetl/lpmode` vuelven a asignarse en `fpga_core.sv` (como en el original) y se quitan de `fpga.sv`, donde el puerto de salida del core quedaba sin driver.

### UART de XFCP en el conector IO (J2700) de la PE5

- `rtl/fpga.sv`: recuperados los puertos `uart_rxd` y `uart_txd`, y el sincronizador `taxi_sync_signal` de entrada. `uart_rts`/`uart_cts` siguen sin sacarse.
- `syn/gpio.xdc`: nuevas restricciones.

| Pin J2700 | Señal | Pin FPGA | Red PE5 |
|---|---|---|---|
| 9 | GND | – | – |
| 7 | TX (salida de la FPGA) | C12 | `IO_X3_D3` |
| 5 | RX (entrada a la FPGA, con pull-up interno) | D12 | `IO_X3_D2` |

El pin 11, contiguo al GND, es alimentación (`V_IO_J`). Parámetros: 921600 baudios, 8N1, 3,3 V.

### LEDs de usuario

- `rtl/fpga.sv`: nuevo puerto `led_n[1:0]`, activo a nivel bajo.
- `syn/gpio.xdc`: nuevas restricciones.

| LED PE5 | Puerto | Pin FPGA | Significado |
|---|---|---|---|
| LED 2 | `led_n[0]` | G14 | Al menos un carril del QSFP con enlace (cambiado en la parte 4) |
| LED 3 | `led_n[1]` | F13 | Los cuatro carriles con enlace (cambiado en la parte 4) |

Los LED 0 y 1 de la PE5 van a MIO del PS y no son accesibles desde la PL.

### Tensión de IO

Todos los pines del banco 91 (reset, UART, LEDs) están en `LVCMOS33`. En la PE5 ese banco se alimenta de `V_IO_GPIO`, unido a `V_3V3`. Los selectores VSEL0/VSEL1 de la PE5 no afectan a estos pines: fijan la tensión de los FMC, que van a bancos HP del SOM (máximo 1,8 V) y deben quedarse en 1,8 V.

## 3. Verificado contra los esquemáticos

- El QSFP28 de la PE5 va por `MGT_W2`, que en el SOM es el banco GTY 129.
- Correspondencia de carriles (la PE5 cruza los carriles 2 y 3):

| Puerto | Canal GTY 129 | Carril QSFP |
|---|---|---|
| `qsfp1_*[0]` | 0 | 1 |
| `qsfp1_*[1]` | 2 | 2 |
| `qsfp1_*[2]` | 1 | 3 |
| `qsfp1_*[3]` | 3 | 4 |

- No hay inversiones de polaridad P/N.
- El QSFP no necesita pines de control desde la FPGA: `MODSELL` va a GND, `LPMODE` tiene pull-down y `RESETL` lo libera `RST_SYS#`.

## 4. Diagnóstico en placa

### LEDs 2 y 3 siempre encendidos

Con el significado de la parte 2, los dos LEDs quedaban encendidos con o sin enlace real. Un LED fijo no distingue entre "la FPGA lo enciende" y "la FPGA no controla el pin": en la PE5 el pull-up de `LED2#_DIP0#` (R2806) figura como no montado y `LED3#_PWR_SYNC` no tiene ninguno, así que un pin sin driver también puede encender el LED. Además `rx_status` solo indica que el PCS recibe 64b/66b válido, no que haya un equipo al otro lado.

Nuevo significado (`rtl/fpga.sv`, `rtl/fpga_core.sv`):

| LED PE5 | Significado |
|---|---|
| LED 2 | Parpadeo de 1 Hz: PL configurada, `pl_clk0` y MMCM en marcha |
| LED 3 | Fijo: al menos un carril con `rx_status`. Parpadeo rápido: se están recibiendo tramas válidas |

`fpga_core.sv` saca ahora por `led[7:4]` la actividad de recepción de cada carril (pulso `m_status_good_frame` de la FIFO alargado a unos 200 ms).

### El Si5395 sacaba 156,25 Hz en lugar de 156,25 MHz (corregido)

La tabla de registros del FSBL (`vitis/Andromeda_SOM/zynqmp_fsbl/peripherials_cfg_init.h`) exportada de ClockBuilder Pro el 13-10-2026 a las 18:48 programaba OUT2 a **156,25 Hz**: N0 = 4095 y divisor R = 20632 sobre un VCO de 13,2 GHz. El propio informe de ClockBuilder incluido en la cabecera lo indica y avisa de "frequency less than 300 kHz". El GTY del QSFP se quedaba sin reloj de referencia válido. La exportación de las 19:29 lo corrige: VCO de 13,75 GHz, N0 = 44, OUT2 a 156,25 MHz en LVDS de 1,8 V, sin avisos.

La tabla del proyecto anterior (`DRD1_Eth_PL/.../Andromeda_10Gbs_OK`) sí genera 156,25 MHz, pero por OUT4 y OUT6, no por OUT2: un `BOOT.bin` de ese proyecto tampoco da reloj al QSFP.

### El QSFP reinicia el sistema al enchufarlo o desenchufarlo

Es comportamiento de la PE5, no del diseño. El pin `RESETL` de la jaula (`QSFP_RST#`) está unido a `RST_SYS#_LS` a través de Q1600A, y `RST_SYS#_LS` a `RST_SYS#` a través de Q2702A (hojas 16 y 27). Los dos son FET de paso, bidireccionales: cualquier cosa que tire de `RESETL` a nivel bajo tira también del reset de sistema, y un módulo sin alimentar lo hace al insertarse (mecanismo deducido del esquemático, no medido). Conviene enchufar el módulo antes de alimentar. El LED `SYS` de la PE5 (D2801) se enciende mientras `RST_SYS#` está activo.

## 5. Pendiente

### Necesario para que funcione en placa

- **Probar en placa** el `BOOT.bin` de las 19:38.
- **Reloj de 156,25 MHz** (hecho en los hooks del FSBL): hay que programar el Si5395 de la PE5 (U1301) para que saque 156,25 MHz por **OUT2**. El esquemático indica la referencia sin plan de frecuencias de fábrica, así que puede no haber reloj hasta programarlo. Camino del reloj: OUT2 (pines 31/30) → condensadores de 100 nF → `QSFP_CLK0_P/N` → `MGT_W2_CLK0` → `MGTREFCLK0_129` (AD32/AD33). Acceso I2C: I2C1 del PS (MIO 24/25) → multiplexor PCA9547 en 0x75, canal 5 → Si5395 en 0x68.
- **Reloj de 125 MHz**: `pl_clk0` solo existe si el PS ha arrancado con un FSBL generado a partir de este diseño. Cargando solo el `.bit` por JTAG no hay reloj. El PS está configurado en "Custom", sin preset de Enclustra (revisar DDR y MIO). Alternativa: el oscilador de 33,3 MHz de la PL que lleva el SOM.
- **Medir el pin 11 de J2700** (debe dar 3,3 V) antes de conectar el adaptador USB-UART.

### Reproducibilidad del build

- El block design `design_1` está añadido a mano en el proyecto Vivado (`fpga.xpr`), pero no figura en el `Makefile` ni en `create_project.tcl`. Un `make` desde cero no lo incluiría.
- Los targets `flash` y `mcs` del Makefile son de la VCU118 y no aplican a un Zynq.

### Limpieza

- El `README.md` y las cabeceras de los XDC siguen describiendo la VCU118.
- El testbench (`tb/fpga_core`) no se ha adaptado a los puertos actuales.
- El proyecto Vivado generado dentro de `fpga_10g/` no debería subirse al repositorio.
