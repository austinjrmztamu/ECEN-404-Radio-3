// Direct Form I: y = b0*x + b1*x1 + b2*x2 - a1*y1 - a2*y2.
// One shared registered multiplier, followed by a separate accumulator stage.
// Finishes within 18 fabric clocks/sample; input valid spacing must exceed 18 clocks.
module am_biquad_q28 #(
    parameter signed [31:0] B0=0, B1=0, B2=0, A1=0, A2=0
)(
    input wire clk, input wire rst,
    input wire signed [31:0] din, input wire din_valid,
    output reg signed [31:0] dout, output reg dout_valid,
    output wire busy, output reg overrun
);
    reg signed [31:0] x0,x1,x2,y1,y2;
    reg signed [31:0] mul_a,mul_b;
    (* use_dsp = "yes" *) reg signed [63:0] product;
    reg signed [67:0] acc;
    reg [2:0] state, term;
    wire signed [67:0] product_ext = {{4{product[63]}},product};
    wire signed [67:0] rounded_y = (acc + 68'sd134217728) >>> 28;
    assign busy = state != 0;
    always @(posedge clk) begin
        if (rst) begin
            state<=0; term<=0; x0<=0; x1<=0; x2<=0; y1<=0; y2<=0;
            mul_a<=0; mul_b<=0; product<=0; acc<=0;
            dout<=0; dout_valid<=0; overrun<=0;
        end else begin
            dout_valid<=0;
            if (din_valid && busy) overrun<=1;
            case(state)
                0: if (din_valid) begin x0<=din; acc<=0; term<=0; state<=1; end
                1: begin
                    case(term)
                        0: begin mul_a<=x0; mul_b<=B0; end
                        1: begin mul_a<=x1; mul_b<=B1; end
                        2: begin mul_a<=x2; mul_b<=B2; end
                        3: begin mul_a<=y1; mul_b<=-A1; end
                        4: begin mul_a<=y2; mul_b<=-A2; end
                    endcase
                    state<=2;
                end
                2: begin product<=mul_a*mul_b; state<=3; end
                3: begin
                    acc<=acc+product_ext;
                    if (term==4) state<=4;
                    else begin term<=term+1; state<=1; end
                end
                4: begin
                    dout<=rounded_y[31:0]; y2<=y1; y1<=rounded_y[31:0];
                    x2<=x1; x1<=x0; dout_valid<=1; state<=0;
                end
                default: state<=0;
            endcase
        end
    end
endmodule
