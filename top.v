module top (
    input phi2,             // 8MHz PIX Clock
    input [3:0] pix,        // PIX Data
    input clk,              // 16MHz Onboard Clock
    output audio_out,
    output led              
);

    // ------------------------------------------------------------
    // 1. MASTER 3.579545 MHz GENERATOR (NCO)
    // ------------------------------------------------------------
    // Formula: (TargetFreq / SourceFreq) * 2^24
    // (3.579545 / 16.0) * 16777216 = 3753446
    reg [23:0] phase_acc;
    wire cen_3_58;

    always @(posedge clk) begin
        phase_acc <= phase_acc + 24'd3753446;
    end
    
    // This creates a single-cycle pulse at exactly 3.579 MHz
    assign cen_3_58 = (phase_acc < 24'd3753446);

    // ------------------------------------------------------------
    // 2. SYSTEM RESET
    // ------------------------------------------------------------
    reg [15:0] reset_cnt = 0;
    wire rst = !reset_cnt[15]; 
    always @(posedge clk) if (reset_cnt[15] == 0) reset_cnt <= reset_cnt + 1;

    // ------------------------------------------------------------
    // 3. PIX DECODER (Synchronized to PHI2)
    // ------------------------------------------------------------
    reg [15:0] n_shift, p_shift;
    reg [1:0]  cycle;
    reg        locked;

    always @(negedge phi2) begin
        n_shift <= {n_shift[11:0], pix};
        if (rst) begin cycle <= 0; locked <= 0; end
        else if (cycle == 0) begin
            if (pix[0]) begin cycle <= 1; locked <= 1; end
            else locked <= 0;
        end else cycle <= cycle + 1;
    end
    always @(posedge phi2) p_shift <= {p_shift[11:0], pix};

    wire [31:0] frame = {n_shift[15:12], p_shift[15:12], n_shift[11:8], p_shift[11:8],
                         n_shift[7:4], p_shift[7:4], n_shift[3:0], p_shift[3:0]};
    wire frame_valid = (cycle == 0) && locked;

    // ------------------------------------------------------------
    // 4. FIFO (512 Entries)
    // ------------------------------------------------------------
    reg [15:0] fifo [0:511];
    reg [8:0]  wr_ptr = 0;
    reg [8:0]  rd_ptr = 0;
    reg [7:0]  l_reg;
    reg        f_flush = 0;
    reg        opl_enabled = 0;
    reg [15:1] opl_base_addr = 15'h7F80;

    always @(negedge phi2) begin
        if (rst || f_flush) begin wr_ptr <= 0; f_flush <= 0; end
        else if (frame_valid) begin
            if (frame[31:29] == 3'd2) begin // XREG Config
                if (frame[27:24] == 4'd0) begin
                    if (frame[23:16] == 8'h00) opl_enabled <= frame[0];
                    if (frame[23:16] == 8'h01) opl_base_addr <= frame[15:1];
                end
            end else if (frame[31:29] == 3'd0 && opl_enabled) begin // XRAM
                if (frame[15:1] == opl_base_addr) begin
                    if (frame[0] == 0) l_reg <= frame[23:16];
                    else begin
                        fifo[wr_ptr] <= {l_reg, frame[23:16]};
                        wr_ptr <= wr_ptr + 1;
                    end
                end else if (frame[15:0] == ({opl_base_addr, 1'b0} + 16'd2) && frame[23:16] == 8'hAA) f_flush <= 1;
            end
        end
    end

    // ------------------------------------------------------------
    // 5. OPL2 DRIVER (Running on 16MHz clk with 3.58MHz cen)
    // ------------------------------------------------------------
    reg [2:0] st = 0; 
    reg [8:0] tm = 0; 
    reg [7:0] cr, cv; 
    reg h_wr = 1, h_a0 = 0;
    
    // --- NEW: CLOCK DOMAIN SYNCHRONIZER ---
    // wr_ptr is updated on 8MHz phi2. We sync it to 16MHz clk for the driver.
    reg [8:0] wr_ptr_sync;
    always @(posedge clk) wr_ptr_sync <= wr_ptr;

    always @(posedge clk) begin
        if (rst || !opl_enabled) begin
            st <= 0; rd_ptr <= 0; h_wr <= 1;
        end else if (cen_3_58) begin
            case (st)
                0: if (rd_ptr != wr_ptr_sync) begin {cr, cv} <= fifo[rd_ptr]; st <= 1; end
                1: begin h_a0 <= 0; h_wr <= 0; tm <= 12; st <= 2; end
                2: begin h_wr <= 1; if (tm > 0) tm <= tm - 1; else {tm, st} <= {9'd20, 3'd3}; end
                3: begin h_a0 <= 1; h_wr <= 0; tm <= 12; st <= 4; end
                4: begin h_wr <= 1; if (tm > 0) tm <= tm - 1; else {tm, st} <= {9'd100, 3'd5}; end
                5: if (tm > 0) tm <= tm - 1; else begin rd_ptr <= rd_ptr + 1; st <= 0; end
            endcase
        end
    end

    // ------------------------------------------------------------
    // 6. OPL2 CORE & DAC
    // ------------------------------------------------------------
    wire [15:0] snd;
    jtopl2 opl_inst (
        .clk(clk), 
        .cen(cen_3_58),  // Throttled to 3.58MHz
        .rst(rst || !opl_enabled), 
        .cs_n(1'b0), .wr_n(h_wr), .addr(h_a0), .din(h_a0 ? cv : cr), .snd(snd)
    );

    sigma_delta_dac dac_inst (.clk(clk), .rst(1'b0), .dac_in(snd), .dac_out(audio_out));

    // ------------------------------------------------------------
    // 7. NEW: ENHANCED LED PATTERN LOGIC
    // ------------------------------------------------------------
    reg [20:0] activity_timer; // Holds the "pulse" for ~130ms
    reg [23:0] slow_cnt;       // Provides the shimmer frequency

    always @(posedge clk) begin
        slow_cnt <= slow_cnt + 1;
        
        // If the driver is busy draining the FIFO, reset the pulse timer
        if (rd_ptr != wr_ptr_sync) begin
            activity_timer <= 21'h1FFFFF; 
        end else if (activity_timer > 0) begin
            activity_timer <= activity_timer - 1;
        end
    end

    // The Pattern Logic:
    // 1. Off to start: If !opl_enabled, LED is 0.
    // 2. Pulse when active: If timer > 0, shimmer at ~60Hz (bit 18).
    // 3. On when enabled: If enabled but no timer, LED is 1 (Solid).
    assign led = opl_enabled ? (activity_timer > 0 ? slow_cnt[17] : 1'b1) : 1'b0;

endmodule