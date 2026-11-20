
`timescale 1ns/1ps
// 100 MHz fabric clock; uniform ADC valid pulses every 104 clocks.
// Fs = 100e6/(4*26) = 961538.4615 samples/s. Not for a 48 kS/s input!
// Conventional carrier-present AM, modulation index <= 1.
module am_envelope_rx #(
    parameter integer AUDIO_GAIN_SHIFT = 1,
    parameter integer STARTUP_AUDIO_SAMPLES = 4800
)(
    input wire clk, input wire rst,
    input wire [11:0] adc_sample, input wire adc_valid,
    output reg [11:0] audio_sample, output reg audio_valid,
    output wire [31:0] envelope_q12,
    output reg adc_clipped, output reg audio_clipped,
    output wire overrun
);
    // All DSP samples have 12 fractional bits; ADC is unsigned offset binary.
    reg signed [31:0] input_dc;
    wire signed [31:0] input_q12 = $signed({8'd0,adc_sample,12'd0});
    wire signed [31:0] centered = input_q12 - input_dc;
    reg signed [31:0] rectified;
    reg rect_valid;
    wire signed [31:0] lp1, lp2;
    wire v1, v2, busy1, busy2, ov1, ov2;
    assign overrun = ov1 | ov2;
    assign envelope_q12 = lp2;

    always @(posedge clk) begin
        if (rst) begin
            input_dc <= 32'sd8388608; // 2048 counts, tracked if actual bias differs
            rectified <= 0; rect_valid <= 0; adc_clipped <= 0;
        end else begin
            rect_valid <= adc_valid;
            if (adc_valid) begin
                input_dc <= input_dc + (centered >>> 12); // ~37 Hz bias tracker
                rectified <= centered[31] ? -centered : centered;
                if (adc_sample <= 12'd8 || adc_sample >= 12'd4087)
                    adc_clipped <= 1; // sticky until reset
            end
        end
    end

    // Fourth order Butterworth, 6 kHz cutoff, coefficients Q28.
    // Distributed numerator gain gives unity DC gain in each section.
    am_biquad_q28 #(.B0(99541), .B1(199083), .B2(99541),
                   .A1(-517710310), .A2(249673020)) section1 (
        .clk(clk),.rst(rst),.din(rectified),.din_valid(rect_valid),
        .dout(lp1),.dout_valid(v1),.busy(busy1),.overrun(ov1));
    am_biquad_q28 #(.B0(101622), .B1(203244), .B2(101622),
                   .A1(-528530343), .A2(260501375)) section2 (
        .clk(clk),.rst(rst),.din(lp1),.din_valid(v1),
        .dout(lp2),.dout_valid(v2),.busy(busy2),.overrun(ov2));

    reg [31:0] audio_phase;
    reg signed [31:0] latest_envelope;
    reg signed [31:0] envelope_dc;
    reg [31:0] startup_count;
    wire signed [31:0] audio_q12 = latest_envelope - envelope_dc;
    //wire signed [31:0] scaled_counts = (audio_q12 >>> 12) <<< AUDIO_GAIN_SHIFT;
    //Added
    // Extend to 64 bits so applying gain has extra headroom.
    wire signed [63:0] audio_extended =
        {{32{audio_q12[31]}}, audio_q12};
    
    // Apply gain while preserving the 12 fractional bits.
    wire signed [63:0] gained_q12 =
        audio_extended <<< AUDIO_GAIN_SHIFT;
    
    // Round to the nearest integer ADC count.
    // Exact halfway cases round toward positive infinity.
    wire signed [63:0] scaled_counts =
        (gained_q12 + 64'sd2048) >>> 12;
        //Added
    // Filter BEFORE taking the latest value at 48 kHz, to suppress aliasing.
    // This is a sample-and-hold rate conversion with <= 1 ADC interval jitter.
    always @(posedge clk) begin
        if (rst) begin
            audio_phase <= 0; latest_envelope <= 0; envelope_dc <= 0;
            startup_count <= 0; audio_sample <= 2048;
            audio_valid <= 0; audio_clipped <= 0;
        end else begin
            audio_valid <= 0;
            if (v2) latest_envelope <= lp2;
            if (audio_phase >= 32'd99952000) begin
                audio_phase <= audio_phase - 32'd99952000;
                envelope_dc <= envelope_dc + (audio_q12 >>> 9); // ~15 Hz
                audio_valid <= 1;
                if (startup_count < STARTUP_AUDIO_SAMPLES) begin
                    startup_count <= startup_count + 1;
                    audio_sample <= 2048;
                end else if (scaled_counts > 2047) begin
                    audio_sample <= 4095; audio_clipped <= 1;
                end else if (scaled_counts < -2048) begin
                    audio_sample <= 0; audio_clipped <= 1;
                end else audio_sample <= scaled_counts + 32'sd2048;
            end else audio_phase <= audio_phase + 32'd48000;
        end
    end
endmodule
