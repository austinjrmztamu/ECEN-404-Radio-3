`timescale 1ns / 1ps

module UART_Tx #(
    parameter BAUD        = 2000000,
    parameter CLK_PER_BIT = 50,
    parameter HALF_BIT    = 25
)(
    input  wire       rst,
    input  wire [7:0] data,
    input  wire       clk,
    input  wire       new_data,
    output reg        tx,
    output reg        new_data_ready
);

    localparam IDLE  = 2'b00;
    localparam START = 2'b01;
    localparam DATA  = 2'b10;
    localparam STOP  = 2'b11;
    
    reg [15:0] clk_count;
    reg [1:0]  state;
    reg [3:0]  index;
    reg [7:0]  data_reg;   // latched transmit byte_data
    
    always @(posedge clk) begin
        if (rst) begin
            state          <= IDLE;
            clk_count      <= 16'd0;
            index          <= 4'd0;
            data_reg       <= 8'd0;
            new_data_ready <= 1'b1;
            tx             <= 1'b1;
        end else begin
            case (state)
    
                IDLE: begin
                    tx             <= 1'b1;
                    clk_count      <= 16'd0;
                    index          <= 4'd0;
                    new_data_ready <= 1'b1;
    
                    if (new_data) begin
                        data_reg       <= data;              // latch byte_data here
                        state          <= START;
                        tx             <= 1'b0;              // start bit
                        clk_count      <= CLK_PER_BIT - 1;
                        new_data_ready <= 1'b0;
                    end
                end
    
                START: begin
                    if (clk_count == 0) begin
                        state     <= DATA;
                        clk_count <= CLK_PER_BIT - 1;
                        index     <= 4'd1;
                        tx        <= data_reg[0];
                    end else begin
                        clk_count <= clk_count - 1;
                    end
                end
    
                DATA: begin
                    if (clk_count == 0) begin
                        clk_count <= CLK_PER_BIT - 1;
    
                        if (index < 8) begin
                            tx    <= data_reg[index];
                            index <= index + 1;
                        end else begin
                            state <= STOP;
                            tx    <= 1'b1;
                        end
                    end else begin
                        clk_count <= clk_count - 1;
                    end
                end
    
                STOP: begin
                    if (clk_count == 0) begin
                        state          <= IDLE;
                        new_data_ready <= 1'b1;
                        tx             <= 1'b1;
                    end else begin
                        clk_count <= clk_count - 1;
                        tx        <= 1'b1;
                    end
                end
    
            endcase
        end
    end
endmodule
