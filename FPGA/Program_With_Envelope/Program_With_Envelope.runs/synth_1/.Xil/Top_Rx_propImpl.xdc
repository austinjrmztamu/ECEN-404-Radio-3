set_property SRC_FILE_INFO {cfile:C:/Users/travi/Downloads/Full_FPGA_Program_1.0/Program_With_Envelope/Program_With_Envelope.srcs/constrs_1/new/Radio_Constraints.xdc rfile:../../../Program_With_Envelope.srcs/constrs_1/new/Radio_Constraints.xdc id:1} [current_design]
set_property src_info {type:XDC file:1 line:14 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN L17   IOSTANDARD LVCMOS33 } [get_ports { sync }]; # JA1 -> SYNC
set_property src_info {type:XDC file:1 line:15 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN L18   IOSTANDARD LVCMOS33 } [get_ports { dinA }]; # JA2 -> DINA (VOUTA)
set_property src_info {type:XDC file:1 line:16 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN N14   IOSTANDARD LVCMOS33 } [get_ports { sclk }]; # JA4 -> SCLK
set_property src_info {type:XDC file:1 line:27 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN R2 IOSTANDARD SSTL135 } [get_ports clk]
set_property src_info {type:XDC file:1 line:31 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN G15 [get_ports reset]
set_property src_info {type:XDC file:1 line:35 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN B13 IOSTANDARD LVCMOS33 } [get_ports {vauxp0}]
set_property src_info {type:XDC file:1 line:36 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN A13 IOSTANDARD LVCMOS33 } [get_ports {vauxn0}]
set_property src_info {type:XDC file:1 line:39 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN R12 IOSTANDARD LVCMOS33 } [get_ports tx]
set_property src_info {type:XDC file:1 line:40 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN V12 IOSTANDARD LVCMOS33 } [get_ports rx]
set_property src_info {type:XDC file:1 line:43 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN U15   IOSTANDARD LVCMOS33 } [get_ports { fan_enable }]; # JC1
