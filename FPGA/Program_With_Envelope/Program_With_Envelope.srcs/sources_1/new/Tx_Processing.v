`timescale 1ns / 1ps

module Tx_Processing(
    input  wire        clk,
    input  wire        reset,
    input  wire [15:0] data_in,
    input  wire        data_valid,
    input  wire        tx_ready,

    output reg  [7:0]  tx_data,
    output reg         tx_start
);

    localparam IDLE         = 3'd0;
    localparam SEND_BYTE0   = 3'd1;
    localparam WAIT_BUSY0   = 3'd2;
    localparam WAIT_READY0  = 3'd3;
    localparam SEND_BYTE1   = 3'd4;
    localparam WAIT_BUSY1   = 3'd5;
    localparam WAIT_READY1  = 3'd6;

    reg [2:0] state;
    reg [15:0] buffer;

    always @(posedge clk) begin
        if (reset) begin
            state    <= IDLE;
            buffer   <= 16'd0;
            tx_data  <= 8'd0;
            tx_start <= 1'b0;
        end else begin
            tx_start <= 1'b0;  // default pulse low

            case (state)
                IDLE: begin
                    if (data_valid) begin
                        buffer <= data_in;
                        state  <= SEND_BYTE0;
                    end
                end

                SEND_BYTE0: begin
                    if (tx_ready) begin
                        tx_data <= {2'b01, buffer[5:0]};
                        tx_start <= 1'b1;
                        state    <= WAIT_BUSY0;
                    end
                end

                WAIT_BUSY0: begin
                    if (!tx_ready)
                        state <= WAIT_READY0;
                end

                WAIT_READY0: begin
                    if (tx_ready)
                        state <= SEND_BYTE1;
                end

                SEND_BYTE1: begin
                    if (tx_ready) begin
                        tx_data <= {2'b10, buffer[11:6]};
                        tx_start <= 1'b1;
                        state    <= WAIT_BUSY1;
                    end
                end

                WAIT_BUSY1: begin
                    if (!tx_ready)
                        state <= WAIT_READY1;
                end

                WAIT_READY1: begin
                    if (tx_ready)
                        state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
