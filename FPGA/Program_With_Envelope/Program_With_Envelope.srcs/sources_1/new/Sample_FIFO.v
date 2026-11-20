`timescale 1ns / 1ps
 
module Sample_FIFO #(  //Parameters are used to allow for values to be passed in the top level file. 
    parameter DATA_WIDTH = 16,
    parameter DEPTH = 1024,
    parameter ADDR_WIDTH = 10   // log2(1024) = 10
)(
    input  wire                  clk,
    input  wire                  rst,
 
    input  wire                  wr_en,    //wr_en can i write to the fifo?
    input  wire [DATA_WIDTH-1:0] wr_data,  //Data to be written to the FIFO array. 
 
    input  wire                  rd_en,    //rd_en can i read out of the fifo?
    output reg  [DATA_WIDTH-1:0] rd_data,  //Data to be read out of the FIFO array. 
    output reg                   rd_valid, //Rd_valid pulses only when fifo is in read state 
 
    output wire                  full,
    output wire                  empty,
    output reg  [15:0]           level
);
 
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1]; //declares FIFO array storing data of size 16 to a level of 1024. 
    reg [ADDR_WIDTH-1:0] wr_ptr; //points to the next written value. 
    reg [ADDR_WIDTH-1:0] rd_ptr; //points to the next value to be read. 
 
    assign empty = (level == 0); //combinational port if empty assign empty to 1. 
    assign full  = (level == DEPTH); //if full assign full to 1. No reason for these assignments to be clocked. 
 
    always @(posedge clk) begin
        if (rst) begin
            wr_ptr   <= 0;
            rd_ptr   <= 0;
            rd_data  <= 0;
            rd_valid <= 1'b0;
            level    <= 0;
        end
        else begin
            rd_valid <= 1'b0;   // default: pulse for one cycle only
 
            case ({wr_en && !full, rd_en && !empty})
            //The line above creates a 2 bit vector that describes the following states and does so combinationally. 
            //case 1: If new data to write and the FIFO is not full allow for writing to occur. If FIFO is empty do not read data
            //case 2: if fifo is full do not write new data. If fifo is full and data is requested read out of the array. 
            //case 3: If both above cases are valid set read and write to enable. 
            //case 4: default dont allow reading or writing to occur. 
                // write only
                2'b10: begin
                    mem[wr_ptr] <= wr_data;
                    wr_ptr      <= wr_ptr + 1'b1;
                    level       <= level + 1'b1;
                end
 
                // read only
                2'b01: begin
                    rd_data     <= mem[rd_ptr];
                    rd_valid    <= 1'b1;
                    rd_ptr      <= rd_ptr + 1'b1;
                    level       <= level - 1'b1;
                end
 
                // simultaneous read/write
                2'b11: begin
                    mem[wr_ptr] <= wr_data;
                    wr_ptr      <= wr_ptr + 1'b1;
 
                    rd_data     <= mem[rd_ptr];
                    rd_valid    <= 1'b1;
                    rd_ptr      <= rd_ptr + 1'b1;
 
                    level       <= level;
                end
 
                default: begin //prevents floating register state and defines case 00. 
                    level <= level;
                end
            endcase
        end
    end
 
endmodule
