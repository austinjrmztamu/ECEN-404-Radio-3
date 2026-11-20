`timescale 1ns / 1ps

module DAC_serial #(
    parameter integer SYNC_HOLD_CYCLES = 6,    // FIX 1: min SYNC high between frames
    parameter integer WATCHDOG_CYCLES  = 2000  // FIX 3: ~20 us @ 100 MHz - well above 16*100ns
)(
    input  wire        clk,
    input  wire [11:0] data,
    input  wire        reset,
    input  wire        DAT_ready,
 
    output reg         sync,
    output wire        dinA,
    output wire        sclk
);
 
    reg [1:0]  state;
    reg [15:0] D_extend;
    wire       data_done;
 
    // FIX 1: hold counter - sized to cover SYNC_HOLD_CYCLES
    reg [$clog2(SYNC_HOLD_CYCLES+1)-1:0] hold_cnt;
 
    // FIX 3: watchdog counter - sized to cover WATCHDOG_CYCLES
    reg [$clog2(WATCHDOG_CYCLES+1)-1:0]  wdog_cnt;
 
    s_clk_divider clk_gen (
        .state    (state),
        .data_in  (D_extend),
        .reset    (reset),
        .clk      (clk),
        .sclk     (sclk),
        .dinA     (dinA),
        .data_sent(data_done)
    );
 
    localparam IDLE     = 2'b00;
    localparam TRANSMIT = 2'b01;
    localparam END      = 2'b10;
 
    always @(posedge clk) begin
        if (reset) begin
            sync     <= 1'b1;
            state    <= IDLE;
            D_extend <= 16'd0;
            hold_cnt <= 0;
            wdog_cnt <= 0;
        end
        else begin
            case (state)
 
                // ----------------------------------------------------------
                IDLE: begin
                    sync     <= 1'b1;
                    D_extend <= 16'd0;
                    hold_cnt <= 0;
                    wdog_cnt <= 0;
 
                    if (DAT_ready) begin
                        //D_extend <= {4'b0000, 12'h000}; 
                        D_extend <= {4'b0000, data};
                        sync     <= 1'b0;
                        state    <= TRANSMIT;
                    end
                end
 
                // ----------------------------------------------------------
                TRANSMIT: begin
                    // FIX 3: increment watchdog every cycle we stay here
                    wdog_cnt <= wdog_cnt + 1;
 
                    if (data_done) begin
                        sync     <= 1'b1;
                        // FIX 2: D_extend cleared in END, not here
                        wdog_cnt <= 0;
                        state    <= END;
                    end
                    // FIX 3: watchdog escape
                    else if (wdog_cnt >= WATCHDOG_CYCLES - 1) begin
                        sync     <= 1'b1;
                        D_extend <= 16'd0;
                        wdog_cnt <= 0;
                        state    <= IDLE;
                    end
                end
 
                // ----------------------------------------------------------
                // FIX 1 + FIX 2: hold SYNC high for at least SYNC_HOLD_CYCLES
                // before allowing a new frame.  D_extend is cleared here.
                END: begin
                    sync     <= 1'b1;
                    // FIX 2: safe to zero now - s_clk_divider is in END/IDLE
                    D_extend <= 16'd0;
 
                    if (hold_cnt < SYNC_HOLD_CYCLES - 1) begin
                        // FIX 1: still counting minimum high time
                        hold_cnt <= hold_cnt + 1;
                    end else begin
                        hold_cnt <= 0;
                        // Minimum SYNC high time satisfied - accept new data
                        if (DAT_ready) begin
                            //D_extend <= {4'b0000, 12'h000}; 
                            D_extend <= {4'b0000, data};
                            sync     <= 1'b0;
                            state    <= TRANSMIT;
                        end else begin
                            state <= IDLE;
                        end
                    end
                end
 
                default: begin
                    sync  <= 1'b1;
                    state <= IDLE;
                end
 
            endcase
        end
    end
endmodule

