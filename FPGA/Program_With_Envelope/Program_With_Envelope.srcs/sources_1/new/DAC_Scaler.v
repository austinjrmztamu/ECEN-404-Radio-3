`timescale 1ns / 1ps
//dout = din * GAIN / 4096,  GAIN = round(4096 * VMAX_MV / VREF_MV)
//Added due to scaling issues for the RF front-end (Expecting 0-1V input)
//this module scales down the DAC output. Typical usage 500mV center 0-1V output. 
module DAC_Scaler #(
    parameter integer VREF_MV = 3300,   // DAC reference voltage (mV)
    parameter integer VMAX_MV = 1000    // desired full-scale output (mV)
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [11:0] din,
    input  wire        din_ready,
    output reg  [11:0] dout,
    output reg         dout_ready
);    
    localparam [12:0] GAIN = (4096 * VMAX_MV + VREF_MV / 2) / VREF_MV;
    //Scales 3.3 V isolate output to whatever VMAX_MV is. 
    wire [24:0] product = din * GAIN;                    // 24 bit to prevent bus clipping
    wire [12:0] rounded = product[24:12] + product[11];  // rounds to nearest whole bit

    always @(posedge clk) begin
        if (rst) begin
            dout       <= GAIN >> 1;    //mid range scaling
            dout_ready <= 1'b0; //handshake bit
        end
        else begin
            dout_ready <= din_ready;
            if (din_ready)
                if (rounded > 13'd4095) begin //If Scaled value is larger than 12 bit max round down. 
                    dout <= 12'd4095;
                end else begin
                    dout <= rounded[11:0]; //If not output midscaled value. 
                end
        end
    end
endmodule
