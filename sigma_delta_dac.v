// simple_sigma_delta_dac.v
// Converts 16-bit signed audio to 1-bit PDM output
// Fixed implementation: Uses carry-out for Pulse Density Modulation
module sigma_delta_dac (
    input wire clk,           // High speed FPGA clock (16MHz)
    input wire rst,           // Reset
    input wire [15:0] dac_in, // 16-bit signed audio sample
    output reg dac_out        // 1-bit output to pin
);

    reg [15:0] accumulator;   // Same width as input

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            accumulator <= 0;
            dac_out <= 0;
        end else begin
            // Add the input sample to the accumulator
            // {dac_out, accumulator} creates a 17-bit result where dac_out captures the carry
            {dac_out, accumulator} <= accumulator + {~dac_in[15], dac_in[14:0]};
        end
    end
endmodule
