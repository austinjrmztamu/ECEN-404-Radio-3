`timescale 1ns / 1ps
module Fan_Temp_Controller(
    input wire rst, 
    input wire clk, 
    input wire [11:0] temp_data, 
    
    output reg fan_enable
    );
    
    localparam [11:0] fan_on_temp = 2545;   //Corresponds to 40C
    localparam [11:0] fan_off_temp = 2504;  //Corresponds to 35C
    
    always @(posedge clk) begin
        if(rst) begin
            fan_enable <= 1'b0;  //reset state turns fans off
            
        end
        else begin
            if (temp_data >= fan_on_temp) begin 
            //if above threshold turn fans on (3.3V logic signal to fan controller PCB
                fan_enable <=1'b1; 
            end
            else if (temp_data <= fan_off_temp) begin 
            //If below threshold turn fans off
                fan_enable <= 1'b0; 
            end
        end
    
    end
endmodule

