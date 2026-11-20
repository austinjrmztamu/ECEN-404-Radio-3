`timescale 1ns / 1ps
//important to note that this will fill rapidly, but timing between bursts is realiably 20.83us 
//data is sampled by the gui at 48kHz and read out of the fifo at 48kHz to ensure synchronization. 

module FIFO_to_DAC_Player(
    input  wire        clk,
    input  wire        rst,
    input  wire        tick_48k, 
    //input from 48kHz tick generator module. Uses first order delta sigma modulator to approximate fractional value
 
    input  wire [11:0] fifo_data, //data read in from fifo. 
    input  wire        fifo_data_valid, //
    input  wire        fifo_empty,
    input  wire [15:0] fifo_level,
    
    output reg         fifo_rd_en,
 
    output reg  [11:0] to_DAC,
    output reg         to_DAC_ready
);
 
    reg started;
    reg waiting_for_sample;
 
    always @(posedge clk) begin
        if (rst) begin
            started            <= 1'b0;
            waiting_for_sample <= 1'b0;
            fifo_rd_en         <= 1'b0;
            to_DAC             <= 12'd2048; //if reset is triggered just output midlevel value.
            to_DAC_ready       <= 1'b0;
        end
        else begin
            fifo_rd_en   <= 1'b0; //Default declarations to ensure triggers only hold one clock cycle. Prevent multiple reads. 
            to_DAC_ready <= 1'b0;

            if (!started && fifo_level >= 16'd512) //Ensures that the fifo has accumulated sufficient samples before reading out of the array. 
                started <= 1'b1;
 
            // ask FIFO for exactly one sample on each 48 kHz tick
            if (tick_48k && started && !fifo_empty && !waiting_for_sample) begin
                fifo_rd_en         <= 1'b1;
                waiting_for_sample <= 1'b1;
            end
 
            // only consume FIFO output when FIFO explicitly says it is valid
            if (waiting_for_sample && fifo_data_valid) begin
                to_DAC <= fifo_data;
                to_DAC_ready       <= 1'b1;
                waiting_for_sample <= 1'b0;
            end
 
            if (tick_48k && started && fifo_empty && !waiting_for_sample) begin
                to_DAC       <= 12'd2048;  // mid-scale = 0 V (no click)
                to_DAC_ready <= 1'b1;
                // started intentionally NOT cleared
            end
        end
    end
 
endmodule
