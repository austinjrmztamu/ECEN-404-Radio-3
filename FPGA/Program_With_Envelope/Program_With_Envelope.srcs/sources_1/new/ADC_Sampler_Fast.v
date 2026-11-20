`timescale 1ns/1ps
// XADC Wizard must use INDEPENDENT ADC mode: ADC B converts VAUX0 only,
// ADC A monitors internal sensors. No external-channel averaging or extended
// acquisition. 100 MHz DCLK / 4 / 26 = 961538.46 VAUX0 conversions/s.
module adc_sampler_fast #(
    parameter integer TEMP_INTERVAL_SAMPLES = 9600
)(
    input wire clk, input wire rst,
    input wire vauxp0, input wire vauxn0,
    output reg [11:0] sample, output reg sample_ready,
    output reg [11:0] temp_code, output reg temp_valid,
    output reg timing_error, output reg drp_error
);
    wire [15:0] adc_data;
    wire eoc, drdy;
    wire [4:0] channel;
    reg [6:0] address;
    reg den;
    reg [1:0] state;
    reg [31:0] temp_count;
    reg [15:0] age;
    reg seen_eoc;
    reg [7:0] wait_count;
    xadc_wiz_0 adc_inst(
        .daddr_in(address), .dclk_in(clk), .den_in(den),
        .di_in(16'd0), .dwe_in(1'b0), .reset_in(rst),
        .vauxp0(vauxp0), .vauxn0(vauxn0),
        .do_out(adc_data), .drdy_out(drdy), .eoc_out(eoc),
        .busy_out(), .channel_out(channel), .eos_out(), .alarm_out(),
        .vp_in(1'b0), .vn_in(1'b0)
    );
    always @(posedge clk) begin
        if (rst) begin
            sample<=2048; sample_ready<=0; temp_code<=0; temp_valid<=0;
            timing_error<=0; drp_error<=0; address<=7'h10; den<=0;
            state<=0; temp_count<=0; age<=0; seen_eoc<=0; wait_count<=0;
        end else begin
            sample_ready<=0; den<=0;
            if (age != 16'hffff) age<=age+1'b1;
            // In independent mode, the external sequence contains only VAUX0.
            if (eoc && channel==5'h10) begin
                if (seen_eoc && age!=16'd103) timing_error<=1;
                seen_eoc<=1; age<=0;
                if (state!=0) drp_error<=1;
            end
            if (seen_eoc && age>=16'd208) timing_error<=1;
            if (state!=0) begin
                wait_count<=wait_count+1'b1;
                if (wait_count==8'd63) begin
                    drp_error<=1; state<=0;
                end
            end
            case(state)
                0: if(eoc && channel==5'h10) begin
                    address<=7'h10; den<=1; state<=1; wait_count<=0;
                end
                1: if(drdy) begin
                    sample<=adc_data[15:4]; sample_ready<=1;
                    if (temp_count>=TEMP_INTERVAL_SAMPLES-1) begin
                        temp_count<=0; state<=2;
                    end else begin temp_count<=temp_count+1; state<=0; end
                end
                2: begin
                    // Read ADC A's temperature status; do NOT switch channels
                    // or interrupt ADC B's external conversions.
                    address<=7'h00; den<=1; state<=3;
                end
                3: if(drdy) begin
                    temp_code<=adc_data[15:4]; temp_valid<=1; state<=0;
                end
            endcase
        end
    end
endmodule

