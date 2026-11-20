`timescale 1ns / 1ps
 
module s_clk_divider #(
    parameter integer HALF_DIV = 5,   // 100 MHz / (2*5) = 10 MHz
    parameter integer MSB_POS  = 15
)(
    input  wire [1:0]  state,
    input  wire [15:0] data_in,
    input  wire        reset,
    input  wire        clk,
    output reg         sclk,
    output reg         dinA,
    output reg         data_sent
);
    localparam IDLE     = 2'b00;
    localparam TRANSMIT = 2'b01;
    localparam END      = 2'b10;
 
    reg [$clog2(HALF_DIV):0] divcnt;
    reg [1:0] state_d;
    reg [4:0] bit_idx;
 
    // One-cycle delay on state for entry-edge detection
    wire entering_tx = (state == TRANSMIT) && (state_d != TRANSMIT);
 
    always @(posedge clk) begin
        state_d <= state;
 
        if (reset) begin
            sclk      <= 1'b1;  // CPOL=1: idle HIGH
            dinA      <= 1'b0;
            data_sent <= 1'b0;
            divcnt    <= 0;
            bit_idx   <= MSB_POS[4:0];
            state_d   <= IDLE;
        end else begin
            data_sent <= 1'b0; // default: pulse only when done
 
            case (state)
 
                IDLE, END: begin
                    sclk    <= 1'b1;  // CPOL=1: idle HIGH
                    divcnt  <= 0;
                    bit_idx <= MSB_POS[4:0];
                    dinA    <= 1'b0;
                end
 
                TRANSMIT: begin
                    if (entering_tx) begin
                        // sclk already HIGH from IDLE (CPOL=1)
                        divcnt  <= 0;
                        bit_idx <= MSB_POS[4:0];
                        dinA    <= data_in[MSB_POS];  // MSB set up before first falling edge
                    end else begin
                        if (divcnt == HALF_DIV - 1) begin
                            divcnt <= 0;
                            sclk   <= ~sclk;
                
                            if (sclk == 1'b1) begin
                                // *** FALLING EDGE - DAC samples dinA here, don't touch it ***
                                // data_sent is NOT asserted here; we let SCLK complete
                                // the full cycle (rising edge) before ending the frame,
                                // so SCLK returns HIGH before SYNC goes HIGH (matches Fig 2).
                            end else begin
                                // *** RISING EDGE - update dinA, or end frame if last bit done ***
                                if (bit_idx != 0) begin
                                    bit_idx <= bit_idx - 1;
                                    dinA    <= data_in[bit_idx - 1];
                                end else begin
                                    // bit_idx == 0: the 16th falling edge already captured DB0.
                                    // Now SCLK has just gone HIGH - assert done so SYNC rises
                                    // while SCLK is already HIGH, matching Figure 2 timing.
                                    data_sent <= 1'b1;
                                end
                            end
                        end else begin
                            divcnt <= divcnt + 1;
                        end
                    end
                end
 
                default: begin
                    sclk    <= 1'b1;  // CPOL=1: idle HIGH
                    divcnt  <= 0;
                    bit_idx <= MSB_POS[4:0];
                    dinA    <= 1'b0;
                end
 
            endcase
        end
    end
endmodule

