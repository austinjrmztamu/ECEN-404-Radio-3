`timescale 1ns / 1ps

module Top_Rx(
    input wire reset,
    input wire clk,
    input wire rx,
    input wire vauxp0,
    input wire vauxn0,

    output wire dinA,
    output wire sclk,
    output wire sync,

    output wire tx,
    output wire fan_enable      // fan driver output (needs a pin in the XDC)

    );

    wire [7:0] rx_byte;
    wire rx_dat_rdy;

    wire [11:0] rx_sample;
    wire rx_samples_ready;

    wire [11:0] to_DAC;
    wire to_DAC_ready;

    wire [11:0] to_DAC_scaled;          // 0-1 V DAC codes (for RF board)
    wire        to_DAC_scaled_ready;

    wire [11:0] fifo_out;
    wire fifo_full;
    wire fifo_empty;
    wire fifo_rd_en;
    wire [15:0] fifo_level;
    wire tick_48k;
    wire fifo_rd_valid;
    wire fan_temp_enable;       // from temperature controller (AUTO)
    wire fan_manual_override;   // from GUI command 0xC1 / 0xC0
    wire [11:0] temp_code;

    Fan_Temp_Controller Fan_Controller(
        .rst(reset),
        .clk(clk),
        .temp_data(temp_code),
        .fan_enable(fan_temp_enable)
    );

    // Fans run if the temperature is high OR the GUI forces them on
    // Hold fans on until a real temperature read has arrived, or on DRP failure.
    assign fan_enable = fan_temp_enable | fan_manual_override;

    Sampling_48k dac_tick_gen(
        .reset(reset),
        .clk(clk),
        .tick_48k(tick_48k)
    );

    Sample_FIFO #(
        .DATA_WIDTH(12),
        .DEPTH(1024),
        .ADDR_WIDTH(10)
    ) Audio_FIFO (
        .clk(clk),
        .rst(reset),

        .wr_en(rx_samples_ready && !fifo_full),
        .wr_data(rx_sample),

        .rd_en(fifo_rd_en),
        .rd_data(fifo_out),
        .rd_valid(fifo_rd_valid),

        .full(fifo_full),
        .empty(fifo_empty),
        .level(fifo_level)
    );

    UART_Rx Receiver(
        .reset(reset),
        .clk(clk),
        .rx(rx),
        .byte_data(rx_byte),
        .dat_rdy(rx_dat_rdy)
    );

    // Fan UART command decoder (shares the RX byte_data stream with the audio decoder)
    //   0xC1 = force fans ON
    //   0xC0 = release override, return to AUTO temperature control
    Fan_Command_Decoder Fan_Command (
        .clk            (clk),
        .reset          (reset),
        .rx_byte        (rx_byte),
        .rx_dat_rdy     (rx_dat_rdy),
        .manual_override(fan_manual_override)
    );

    UART_Sample_Decoder Decoder (
        .reset       (reset),
        .clk         (clk),
        .byte_data        (rx_byte),
        .dat_ready   (rx_dat_rdy),

        .sample      (rx_sample),
        .sample_ready(rx_samples_ready)
    );

    FIFO_to_DAC_Player Player (
        .clk(clk),
        .rst(reset),

        .tick_48k(tick_48k),

        .fifo_data(fifo_out),
        .fifo_data_valid(fifo_rd_valid),
        .fifo_empty(fifo_empty),
        .fifo_level(fifo_level),
        .fifo_rd_en(fifo_rd_en),

        .to_DAC(to_DAC),
        .to_DAC_ready(to_DAC_ready)
    );

    // DAC scaling: 0-4095 -> codes for 0-1 V on the 3.3 V DAC reference (RF board)
    DAC_Scaler #(
        .VREF_MV(3300),
        .VMAX_MV(1000)
    ) Scaler (
        .clk        (clk),
        .rst        (reset),
        .din        (to_DAC),
        .din_ready  (to_DAC_ready),
        .dout       (to_DAC_scaled),
        .dout_ready (to_DAC_scaled_ready)
    );

    DAC_serial Interface(
        .clk(clk),
        .data(to_DAC_scaled),
        .reset(reset),
        .DAT_ready(to_DAC_scaled_ready),
        .sync(sync),
        .dinA(dinA),
        .sclk(sclk)
    );

    wire [15:0] adc_scaled;             // centered recovered audio, with receive gain
    wire        adc_scaled_ready;

    wire [7:0]  uart_tx_data;
    wire        uart_tx_start;

    wire        uart_tx_ready;

    wire [11:0] adc_fast;
    wire adc_fast_ready;
    wire [11:0] envelope_audio;
    wire envelope_audio_ready;
    wire temp_valid;
    wire adc_timing_error, adc_drp_error;
    wire adc_clip, envelope_clip, detector_overrun, receive_gain_clip;

    adc_sampler_fast Sampler (
        .clk(clk), .rst(reset), .vauxp0(vauxp0), .vauxn0(vauxn0),
        .sample(adc_fast), .sample_ready(adc_fast_ready),
        .temp_code(temp_code), .temp_valid(temp_valid),
        .timing_error(adc_timing_error), .drp_error(adc_drp_error)
    );

    am_envelope_rx #(.AUDIO_GAIN_SHIFT(1)) Envelope (
        .clk(clk), .rst(reset), .adc_sample(adc_fast),
        .adc_valid(adc_fast_ready), .audio_sample(envelope_audio),
        .audio_valid(envelope_audio_ready), .envelope_q12(),
        .adc_clipped(adc_clip), .audio_clipped(envelope_clip),
        .overrun(detector_overrun)
    );

    // Keep your x3.3 receive gain, but apply it to centered AUDIO, not its DC bias.
    am_audio_scaler #(.ADC_FS_MV(3300), .SIG_MAX_MV(1000)) ADC_Gain (
        .clk(clk), .rst(reset), .din(envelope_audio),
        .din_ready(envelope_audio_ready), .dout(adc_scaled),
        .dout_ready(adc_scaled_ready), .clipped(receive_gain_clip)
    );

    Tx_Processing Processor (
        .clk        (clk),
        .reset      (reset),
        .data_in    (adc_scaled),
        .data_valid (adc_scaled_ready),
        .tx_ready   (uart_tx_ready),
        .tx_data    (uart_tx_data),
        .tx_start   (uart_tx_start)
    );

    UART_Tx Transmitter (
        .clk           (clk),
        .rst           (reset),
        .data          (uart_tx_data),
        .new_data      (uart_tx_start),
        .tx            (tx),
        .new_data_ready(uart_tx_ready)
    );

endmodule
