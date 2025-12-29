module top (
    input phi2,             // 8MHz PIX Clock
    input [3:0] pix,        // PIX Data
    input clk,              // 16MHz Onboard Clock (for DAC)
    output audio_out,
    output led              
);

    // --- 1. POWER-ON RESET ---
    reg [15:0] reset_cnt = 0;
    wire rst = !reset_cnt[15]; 
    always @(posedge phi2) if (reset_cnt[15] == 0) reset_cnt <= reset_cnt + 1;

    // --- 2. CONFIGURATION REGISTERS ---
    reg        opl_enabled = 0;         
    reg [15:1] opl_base_addr = 15'h7F80; // Default FF00

    // ------------------------------------------------------------
    // 3. STATE-LOCKED PIX DECODER (Stall-Safe)
    // ------------------------------------------------------------
    reg [15:0] n_shift, p_shift;
    reg [1:0]  cycle;
    reg        locked;

    // Capture nibbles on every edge (The Zipper)
    always @(negedge phi2) n_shift <= {n_shift[11:0], pix};
    always @(posedge phi2) p_shift <= {p_shift[11:0], pix};

    // PIX SYNC RULE: PIX0 MUST be high on Negedge of Cycle 0.
    // If it's not, we stall at Cycle 0 until we find it.
    always @(negedge phi2) begin
        if (rst) begin
            cycle <= 0;
            locked <= 0;
        end else begin
            if (cycle == 2'd0) begin
                if (pix[0]) begin
                    cycle <= 2'd1;
                    locked <= 1'b1;
                end else begin
                    locked <= 1'b0; // Stall at 0
                end
            end else begin
                cycle <= cycle + 2'd1;
            end
        end
    end

    // Reconstruct the 32-bit frame from our zippered registers
    wire [31:0] frame = {n_shift[15:12], p_shift[15:12], n_shift[11:8], p_shift[11:8],
                         n_shift[7:4], p_shift[7:4], n_shift[3:0], p_shift[3:0]};
    
    // We only process the frame at the end of the 4th cycle (cycle 0) 
    // AND only if we were locked.
    wire frame_valid = (cycle == 2'd0) && locked;

    // ------------------------------------------------------------
    // 4. SNIFFER & FIFO
    // ------------------------------------------------------------
    reg [15:0] fifo [0:511];
    reg [8:0]  wr_ptr = 0;
    reg [8:0]  rd_ptr = 0;
    reg [7:0]  latch_reg;
    reg        fifo_flush_req = 0;

    always @(negedge phi2) begin
        if (rst || fifo_flush_req) begin
            wr_ptr <= 0;
            fifo_flush_req <= 0;
        end else if (frame_valid) begin
            // A. Handle XREG Config (Device 2)
            // Even if enabled=0, we must hear the wake-up call!
            if (frame[31:29] == 3'd2) begin
                if (frame[27:24] == 4'd0) begin
                    if (frame[23:16] == 8'h00) opl_enabled <= frame[0];
                    if (frame[23:16] == 8'h01) opl_base_addr <= frame[15:1];
                end
            end
            
            // B. Handle XRAM Sniffer (Device 0)
            else if (frame[31:29] == 3'd0 && opl_enabled) begin
                if (frame[15:1] == opl_base_addr) begin
                    if (frame[0] == 0) latch_reg <= frame[23:16]; // FF00
                    else begin
                        fifo[wr_ptr] <= {latch_reg, frame[23:16]}; // FF01
                        wr_ptr <= wr_ptr + 1;
                    end
                end
                // Flush Register (Base + 2)
                else if (frame[15:0] == ({opl_base_addr, 1'b0} + 16'd2) && frame[23:16] == 8'hAA) begin
                    fifo_flush_req <= 1;
                end
            end
        end
    end

    // ------------------------------------------------------------
    // 5. DRIVER STATE MACHINE (FIFO -> OPL2 Core)
    // ------------------------------------------------------------
    reg [2:0] st = 0; reg [8:0] tm = 0; reg [7:0] cr, cv; reg h_wr_n = 1, h_a0 = 0;

    always @(posedge phi2) begin
        if (rst || fifo_flush_req || !opl_enabled) begin
            st <= 0; rd_ptr <= 0; h_wr_n <= 1;
        end else begin
            case (st)
                0: if (rd_ptr != wr_ptr) begin {cr, cv} <= fifo[rd_ptr]; st <= 1; end
                1: begin h_a0 <= 0; h_wr_n <= 0; tm <= 12; st <= 2; end
                2: begin h_wr_n <= 1; if (tm > 0) tm <= tm - 1; else {tm, st} <= {9'd40, 3'd3}; end
                3: begin h_a0 <= 1; h_wr_n <= 0; tm <= 12; st <= 4; end
                4: begin h_wr_n <= 1; if (tm > 0) tm <= tm - 1; else {tm, st} <= {9'd250, 3'd5}; end
                5: if (tm > 0) tm <= tm - 1; else begin rd_ptr <= rd_ptr + 1; st <= 0; end
            endcase
        end
    end

    // ------------------------------------------------------------
    // 6. OPL2 CORE & DAC
    // ------------------------------------------------------------
    reg cen; always @(posedge phi2) cen <= ~cen;
    wire [15:0] snd;
    jtopl2 opl_inst (
        .clk(phi2), .cen(cen), .rst(rst || !opl_enabled), .cs_n(1'b0),
        .wr_n(h_wr_n), .addr(h_a0), .din(h_a0 ? cv : cr), .snd(snd)
    );
    reg [15:0] db; always @(posedge clk) db <= snd;
    sigma_delta_dac dac_inst (.clk(clk), .rst(1'b0), .dac_in(db), .dac_out(audio_out));

    // ------------------------------------------------------------
    // 7. DIAGNOSTIC LED LOGIC
    // ------------------------------------------------------------
    reg [19:0] lt; reg [23:0] ls;
    always @(posedge phi2) begin
        ls <= ls + 1;
        if (rd_ptr != wr_ptr) lt <= 20'hFFFFF;
        else if (lt > 0) lt <= lt - 1;
    end

    // Visual feedback logic:
    // 1. OFF: Card disabled.
    // 2. HEARTBEAT: Enabled, but sync is stalling (Waiting for framing bit).
    // 3. SOLID ON: Enabled and Sync is Locked.
    // 4. SHIMMER: Enabled, Locked, and data is flowing.
    assign led = !opl_enabled ? 1'b0 :           // Off
                 !locked      ? ls[22] :         // Slow Hearbeat
                 (lt > 0)     ? ls[17] : 1'b1;   // Shimmer vs Solid

endmodule