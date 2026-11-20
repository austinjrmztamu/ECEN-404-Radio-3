`timescale 1ns / 1ps

///Fan UART command decoder bytes 11xx xxxx will never occur in audio transmission
///0xC1 = force fans ON
///0xC0 = release override and return to AUTO temperature control
module Fan_Command_Decoder (
    input  wire       clk,
    input  wire       reset,
    input  wire [7:0] rx_byte,
    input  wire       rx_dat_rdy,
    output reg        manual_override
);
    always @(posedge clk) begin
        if (reset) begin
            manual_override <= 1'b0;
        end
        else if (rx_dat_rdy) begin
            case (rx_byte)
                // Force fans ON
                8'hC1:
                    manual_override <= 1'b1;
                // Release override
                8'hC0:
                    manual_override <= 1'b0;
                // Ignore all other UART/audio bytes
                default://Not required but good practice to include. 
                    manual_override <= manual_override;
            endcase
        end
    end

endmodule
