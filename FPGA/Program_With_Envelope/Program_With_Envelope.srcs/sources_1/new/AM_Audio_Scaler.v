`timescale 1ns/1ps
//Written with the assistance of a Large Language Model. (ChatGPT)
//Review and technical check performed by Travis G. 
module am_audio_scaler #(
    parameter integer ADC_FS_MV=3300,
    parameter integer SIG_MAX_MV=1000
)(
    input wire clk,
    input wire rst,
    input wire [11:0] din, 
    input wire din_ready,
    output reg [15:0] dout,
    output reg dout_ready,
    output reg clipped
);
    localparam integer GAIN_Q12 = (4096 * ADC_FS_MV + SIG_MAX_MV/2) / SIG_MAX_MV; 
    //Calculated Gain coefficient from set parameters (Top level)
    localparam integer GW = $clog2(GAIN_Q12 + 1) + 1;
    //Number of bits used to store the gain
    localparam integer PW = 12 + GW;
    //Number of bits used to store the product
    localparam signed [GW-1:0] GAIN = GAIN_Q12;
    //Setting localparam used to calculate the clipping values
    localparam signed [63:0] HIGH_CENTER = (64'sd8386560 + GAIN_Q12 - 1) / GAIN_Q12;
    //Calculate positive and negative clipping values. Will be referenced for set values of FS_MV and SIG_MAX
    localparam signed [63:0] LOW_MAG = 64'sd8390656 / GAIN_Q12 + 1;
    localparam [11:0] HIGH_INPUT = 2048 + HIGH_CENTER;
    localparam [11:0] LOW_INPUT = 2048 - LOW_MAG;
    
    wire high_clip;
    wire low_clip;
    
    generate
        if (HIGH_CENTER <= 2047) begin : g_high
            assign high_clip = din >= HIGH_INPUT;
            //Signal is above threshold assign clipping value
        end else begin : g_no_high
            assign high_clip = 1'b0;
            //Signal is below threshold assign clipping value
        end
        if (LOW_MAG <= 2048) begin : g_low
            assign low_clip = din <= LOW_INPUT;
            
        end else begin : g_no_low
            assign low_clip = 1'b0;
        end
    endgenerate

    // Offset binary to signed flip the sign bit- no subtractor.
    wire signed [11:0] centered = {~din[11], din[10:0]};
    wire signed [PW-1:0] product = centered * GAIN;
    wire signed [PW:0] extended_product = {product[PW-1], product};
    wire signed [PW:0] rounded = extended_product + 2048;
    wire signed [11:0] scaled = rounded >>> 12;
    // For non-clipped samples convert back by flipping the sign bit.
    wire [11:0] offset_binary = {~scaled[11], scaled[10:0]};

    always @(posedge clk) begin
        if (rst) begin
            dout <= 16'd2048;
            dout_ready <= 1'b0;
            clipped <= 1'b0;
        end else begin //Sets up data output and handles clipping logic. 
            dout_ready <= din_ready;
            if (din_ready) begin //High clip on data ready handshake
                if (high_clip) begin
                    dout <= 16'd4095;
                    clipped <= 1'b1;
                    
                end else if (low_clip) begin //Low clip on data ready handshake
                    dout <= 16'd0;
                    clipped <= 1'b1;
                    
                end else begin //data ready and no clipping behavior output input*gain value
                    dout <= {4'b0, offset_binary};
                end
            end
        end
    end
endmodule
