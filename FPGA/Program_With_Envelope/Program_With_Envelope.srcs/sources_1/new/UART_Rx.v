`timescale 1ns / 1ps

module UART_Rx#(
    parameter baud = 2_000_000, //500 ns period used for data transfer.
    parameter hlf_clk = 50,     //Takes 50 100MHz clk cycles to reach next bit. 
    parameter cent_clk = 25     //Used for centering to middle of rx byte_data low. 
    )(
    input wire reset,    //Reset active high
    input wire clk,      //100MHz clock
    input wire rx,       //8N1 USB-UART line stream
    
    output reg [7:0] byte_data, //One fully transmitted byte_data received from the GUI. 
    output reg dat_rdy //Signifies that one whole byte_data has been processed.
    );
    reg [1:0] state; //state internal register (IDLE, START, DATA, END)
    reg [5:0] count; //Internal counting register
    reg [2:0] index; //Register index for little endian. 
    reg [7:0] dat;   //Dat internal register. Collects rx line data. 
    reg rx_init; 
    reg rx_sync; 
    
    localparam IDLE = 2'b00;  //Waiting for rx line to go low.
    localparam START = 2'b01; //Wait till the center of first bit
    localparam DATA = 2'b10;  //Start processing data every 50 clock cycles. 
    localparam END = 2'b11;   //Wait 50 clock cycles to ensure end bit went high. 
    
    always @(posedge clk) begin //synchronizes the input data stream to prevent working with async values. 
        if (reset) begin
            rx_init <= 1'b1; //during reset set idle high. 
            rx_sync <= 1'b1;
        end
        else begin
            rx_init <= rx;   //Receiver async line. 
            rx_sync <= rx_init; //descync the line and append to register. 
        end
    end
    
    
    always @(posedge clk) begin
        if (reset) begin
            byte_data <= 8'd0; 
            state <= IDLE; 
            count <= 6'd0; 
            index <= 3'd0;
            dat <= 8'd0;
            dat_rdy <= 1'b0;
        end
        else begin
            dat_rdy <= 1'b0; //Default low, creates 1-cycle pulse when asserted
            case(state)
                IDLE: begin
                    state <= IDLE; //Remain in idle until start bit detected
                    index <= 3'd0; 
                    count <= 6'd0;
                    dat <= 8'd0;  //Clear data register for next reception  
                    if (rx_sync == 1'b0) begin
                        state <= START;        //Transititon to start state to begin bit centering.
                        count <= cent_clk - 1; //Set counter to half clk to center start bit.
                    end
                end
                START: begin
                    if(rx_sync == 1'b1) begin //If rx flips back high, start bit invalid ? go idle
                        state <= IDLE;   
                    end
                    else if(count == 0) begin
                        state <= DATA;          //If line is still low for 25 cycles switch to data mode. 
                        count <= hlf_clk - 1;   //Set to 50 cycles to sample at center of each bit.
                    end
                    else begin
                        count <= count - 1;     //Decrement clock counter
                    end
                end
                DATA: begin
                    if (count == 0) begin
                        dat[index] <= rx_sync;  //Sample data bit at center of bit period
                        if(index == 3'd7) begin
                            state <= END;        //All 8 bits received ? move to stop bit
                            count <= hlf_clk - 1; //Wait full bit time to center of stop bit
                        end
                        else begin
                            index <= index + 1;  //Increment index for next bit
                            count <= hlf_clk - 1; //Restart bit timer
                        end
                    end
                    else begin
                        count <= count - 1; //Decrement every clk cycle (100MHz)
                    end
                end
                END: begin
                    if(count == 0) begin
                        state <= IDLE;   //Return to idle after stop bit
                        if(rx_sync == 1'b1) begin //Ensure stop bit is HIGH (valid frame)
                            dat_rdy <= 1'b1; //Signal byte_data is ready (1 clock pulse)
                            byte_data <= dat;     //Transfer collected data to output
                        end
                    end
                    else begin
                        count <= count -1; 
                    end
                end
            endcase
        end
    end
endmodule
