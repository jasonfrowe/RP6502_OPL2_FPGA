module top (
    input phi2,
    input [3:0] pix,
    output reg led
);

    // 1. Capture data on both edges of the bus clock
    // This creates two 16-bit shift registers that stay perfectly in sync
    reg [15:0] n_shift;
    reg [15:0] p_shift;

    always @(negedge phi2) n_shift <= {n_shift[11:0], pix};
    always @(posedge phi2) p_shift <= {p_shift[11:0], pix};

    // 2. The "Zipper" Logic
    // We combine them into a 32-bit word. 
    // We will check for the Framing Bit (Bit 28) on the Falling Edge (n_shift)
    wire [31:0] frame = {
        n_shift[15:12], p_shift[15:12], // Bits 31-24
        n_shift[11:8],  p_shift[11:8],  // Bits 23-16
        n_shift[7:4],   p_shift[7:4],   // Bits 15-8
        n_shift[3:0],   p_shift[3:0]    // Bits 7-0
    };

    // 3. Decoding Fields
    wire is_ria  = (frame[31:29] == 3'b000) && frame[28];
    wire is_ff00 = (frame[15:0] == 16'hFF00 || frame[15:0] == 16'hFF01);
    wire d_bit_0 = frame[16]; // Data Bit 0

    // 4. Latch logic
    // We evaluate the frame only on the Falling Edge of PHI2,
    // specifically when we see the "next" framing bit starting.
    // This ensures the "previous" 32 bits are fully shifted in.
    always @(negedge phi2) begin
        if (pix[0]) begin // Framing bit detected for the START of a new message
            if (is_ria && is_ff00) begin
                led <= d_bit_0;
            end
        end
    end

endmodule