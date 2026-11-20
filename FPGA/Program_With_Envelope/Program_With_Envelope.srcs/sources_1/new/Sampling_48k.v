`timescale 1ns / 1ps

//This module creates ticks for sampling the ADC approximately every 20.8333 us
//This occurs by randomly sampling between 2083 clock cycles and 2084 which converges
//to 2083.333 clock cycles. 

module Sampling_48k( //Creates a long term tick at 48kHz
    input wire reset,
    input wire clk,
    output reg tick_48k
    );
    reg [31:0] offset; 
    
    localparam clk_freq = 100000000;
    localparam des_freq = 48000;
    
    always @(posedge clk) begin
        if(reset) begin
            tick_48k <= 1'b0; 
            offset <= 32'd0; 
        end
        
        else begin
            if (offset + des_freq >= clk_freq) begin //Defines accumulator Behavior to oscillate between 2083 & 2084
            //Approximates 2083.333 us.
                offset <= offset + des_freq - clk_freq; //Resets output state with offset. 
                tick_48k <= 1'b1; 
            end
            else begin
                tick_48k <= 1'b0; 
                offset <= offset + des_freq; //Increments by step size. (occurs approx 2083 times)
            end
        end
    end
endmodule
