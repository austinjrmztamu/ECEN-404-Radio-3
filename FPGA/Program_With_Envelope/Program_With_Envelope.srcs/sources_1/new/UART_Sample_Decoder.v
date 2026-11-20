`timescale 1ns / 1ps


module UART_Sample_Decoder(
    input  wire        reset,
    input  wire        clk,
    input  wire [7:0]  byte_data,
    input  wire        dat_ready,

    output reg  [11:0] sample,
    output reg         sample_ready
);

    reg [5:0] low_six;
    reg       have_low_byte;

    always @(posedge clk) begin
        if (reset) begin
            low_six       <= 6'd0;
            have_low_byte <= 1'b0;
            sample        <= 12'd2048;
            sample_ready  <= 1'b0;
        end
        else begin
            // Default low makes sample_ready a one-clock pulse.
            sample_ready <= 1'b0;

            if (dat_ready) begin
                case (byte_data[7:6])

                    // 01xxxxxx: first byte_data
                    2'b01: begin
                        low_six       <= byte_data[5:0];
                        have_low_byte <= 1'b1;
                    end

                    // 10xxxxxx: second byte_data
                    2'b10: begin
                        if (have_low_byte) begin
                            sample <= {
                                byte_data[5:0],
                                low_six
                            };

                            sample_ready  <= 1'b1;
                            have_low_byte <= 1'b0;
                        end
                    end

                    // 00xxxxxx or 11xxxxxx: invalid identifier
                    default: begin
                        have_low_byte <= 1'b0;
                    end

                endcase
            end
        end
    end

endmodule
