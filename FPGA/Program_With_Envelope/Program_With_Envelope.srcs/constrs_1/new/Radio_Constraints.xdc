#MASTER XDC DECLARATIONS FOUND HERE
#https://github.com/Digilent/digilent-xdc/blob/master/Arty-S7-50-Master.xdc

#set_property -dict { PACKAGE_PIN L17   IOSTANDARD LVCMOS33 } [get_ports { sync }]; #IO_L4P_T0_D04_14 Sch=ja_p[1]
#set_property -dict { PACKAGE_PIN L18   IOSTANDARD LVCMOS33 } [get_ports { dinA }]; #IO_L4N_T0_D05_14 Sch=ja_n[1]
#set_property -dict { PACKAGE_PIN M14   IOSTANDARD LVCMOS33 } [get_ports { dinA }]; #IO_L5P_T0_D06_14 Sch=ja_p[2]
#set_property -dict { PACKAGE_PIN N14   IOSTANDARD LVCMOS33 } [get_ports { sclk }]; #IO_L5N_T0_D07_14 Sch=ja_n[2]
#set_property -dict { PACKAGE_PIN M16   IOSTANDARD LVCMOS33 } [get_ports { ja[4] }]; #IO_L7P_T1_D09_14 Sch=ja_p[3]
#set_property -dict { PACKAGE_PIN M17   IOSTANDARD LVCMOS33 } [get_ports { ja[5] }]; #IO_L7N_T1_D10_14 Sch=ja_n[3]
#set_property -dict { PACKAGE_PIN M18   IOSTANDARD LVCMOS33 } [get_ports { ja[6] }]; #IO_L8P_T1_D11_14 Sch=ja_p[4]
#set_property -dict { PACKAGE_PIN N18   IOSTANDARD LVCMOS33 } [get_ports { ja[7] }]; #IO_L8N_T1_D12_14 Sch=ja_n[4]

# DA2 on JA (top row)
set_property -dict { PACKAGE_PIN L17   IOSTANDARD LVCMOS33 } [get_ports { sync }]; # JA1 -> SYNC
set_property -dict { PACKAGE_PIN L18   IOSTANDARD LVCMOS33 } [get_ports { dinA }]; # JA2 -> DINA (VOUTA)
set_property -dict { PACKAGE_PIN N14   IOSTANDARD LVCMOS33 } [get_ports { sclk }]; # JA4 -> SCLK
#set_property -dict { PACKAGE_PIN V15   IOSTANDARD LVCMOS33 } [get_ports { sync }]; #IO_L20N_T3_A07_D23_14 Sch=jd1/ck_io[33]
#set_property -dict { PACKAGE_PIN U12   IOSTANDARD LVCMOS33 } [get_ports { dinA }]; #IO_L21P_T3_DQS_14 Sch=jd2/ck_io[32]
#set_property -dict { PACKAGE_PIN V13   IOSTANDARD LVCMOS33 } [get_ports { dinA }]; #IO_L21N_T3_DQS_A06_D22_14 Sch=jd3/ck_io[31]
#set_property -dict { PACKAGE_PIN T12   IOSTANDARD LVCMOS33 } [get_ports { sclk }]; #IO_L22P_T3_A05_D21_14 Sch=jd4/ck_io[30]
#set_property -dict { PACKAGE_PIN T13   IOSTANDARD LVCMOS33 } [get_ports { jd[4] }]; #IO_L22N_T3_A04_D20_14 Sch=jd7/ck_io[29]
#set_property -dict { PACKAGE_PIN R11   IOSTANDARD LVCMOS33 } [get_ports { jd[5] }]; #IO_L23P_T3_A03_D19_14 Sch=jd8/ck_io[28]
#set_property -dict { PACKAGE_PIN T11   IOSTANDARD LVCMOS33 } [get_ports { jd[6] }]; #IO_L23N_T3_A02_D18_14 Sch=jd9/ck_io[27]
#set_property -dict { PACKAGE_PIN U11   IOSTANDARD LVCMOS33 } [get_ports { jd[7] }]; #IO_L24P_T3_A01_D17_14 Sch=jd10/ck_io[26]

# ?? 100 MHz system clock ?????????????????????????????????????????????
set_property -dict { PACKAGE_PIN R2 IOSTANDARD SSTL135 } [get_ports clk]
create_clock -add -name sys_clk_pin -period 10.000 -waveform {0 5.000} [get_ports clk]

# ?? Reset (BTN0) ?????????????????????????????????????????????????????
set_property PACKAGE_PIN G15 [get_ports reset]
set_property IOSTANDARD LVCMOS33 [get_ports reset]

# ?? XADC analog input (Arduino A0, single-ended) ????????????????????
set_property -dict { PACKAGE_PIN B13 IOSTANDARD LVCMOS33 } [get_ports {vauxp0}]
set_property -dict { PACKAGE_PIN A13 IOSTANDARD LVCMOS33 } [get_ports {vauxn0}]

# ?? USB-UART ?????????????????????????????????????????????????????????
set_property -dict { PACKAGE_PIN R12 IOSTANDARD LVCMOS33 } [get_ports tx]
set_property -dict { PACKAGE_PIN V12 IOSTANDARD LVCMOS33 } [get_ports rx]

# Fan driver output on Pmod JC pin 1
set_property -dict { PACKAGE_PIN U15   IOSTANDARD LVCMOS33 } [get_ports { fan_enable }]; # JC1