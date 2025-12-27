module top (
    input phi2,             // 8MHz PIX Clock
    input [3:0] pix,        // PIX Data
    input clk,              // 16MHz Onboard Clock (for DAC)
    output audio_out,
    output led              // Removed 'reg' here so 'assign' works
);

    // --- 1. POWER-ON RESET (Added back) ---
    reg [15:0] reset_cnt = 0;
    wire rst = !reset_cnt[15]; 
    always @(posedge phi2) if (reset_cnt[15] == 0) reset_cnt <= reset_cnt + 1;

    // --- 2. CONFIGURATION REGISTERS ---
    reg        opl_enabled = 0;         
    reg [15:1] opl_base_addr = 15'h7F80; // Default FF00

    // --- 3. PIX DECODER ---
    reg [15:0] n_shift, p_shift;
    always @(negedge phi2) n_shift <= {n_shift[11:0], pix};
    always @(posedge phi2) p_shift <= {p_shift[11:0], pix};
    
    wire [31:0] frame = {n_shift[15:12], p_shift[15:12], n_shift[11:8], p_shift[11:8],
                         n_shift[7:4], p_shift[7:4], n_shift[3:0], p_shift[3:0]};

    wire [2:0] device   = frame[31:29];
    wire       f_bit    = frame[28];
    wire [3:0] channel  = frame[27:24];
    wire [7:0] x_addr   = frame[23:16];
    wire [15:0] x_val   = frame[15:0];

    // --- 4. FIFO STORAGE ---
    reg [15:0] fifo [0:511];
    reg [8:0]  wr_ptr = 0;
    reg [8:0]  rd_ptr = 0;
    reg [7:0]  latch_reg;
    reg        fifo_flush_req = 0;

    // Sniffer / Logic logic (Falling Edge)
    always @(negedge phi2) begin
        if (rst || fifo_flush_req) begin
            wr_ptr <= 0;
            fifo_flush_req <= 0;
        end else if (pix[0] && f_bit) begin
            // A. Handle XREG Config (Device 2)
            if (device == 3'd2 && channel == 4'd0) begin
                case (x_addr)
                    8'h00: opl_enabled <= x_val[0];
                    8'h01: opl_base_addr <= x_val[15:1];
                endcase
            end
            
            // B. Handle XRAM Writes (Device 0)
            else if (device == 3'd0 && opl_enabled) begin
                // Match Base (Index) and Base+1 (Data)
                if (frame[15:1] == opl_base_addr[15:1]) begin
                    if (frame[0] == 0) latch_reg <= frame[23:16]; // FF00
                    else begin
                        fifo[wr_ptr] <= {latch_reg, frame[23:16]}; // FF01
                        wr_ptr <= wr_ptr + 1;
                    end
                end
                // Match Base+2 (Flush Register)
                else if (frame[15:0] == ({opl_base_addr, 1'b0} + 16'd2)) begin
                    if (frame[23:16] == 8'hAA) fifo_flush_req <= 1;
                end
            end
        end
    end

    // --- 5. DRIVER STATE MACHINE (Rising Edge) ---
    reg [2:0] state = 0;
    reg [8:0] timer = 0;
    reg [7:0] cur_r, cur_v;
    reg h_wr_n = 1, h_a0 = 0;

    always @(posedge phi2) begin
        if (rst || fifo_flush_req) begin
            state <= 0; rd_ptr <= 0; h_wr_n <= 1;
        end else begin
            case (state)
                0: if (rd_ptr != wr_ptr) begin {cur_r, cur_v} <= fifo[rd_ptr]; state <= 1; end
                1: begin h_a0 <= 0; h_wr_n <= 0; timer <= 12; state <= 2; end
                2: begin h_wr_n <= 1; if (timer > 0) timer <= timer - 1; else {timer, state} <= {9'd30, 3'd3}; end
                3: begin h_a0 <= 1; h_wr_n <= 0; timer <= 12; state <= 4; end
                4: begin h_wr_n <= 1; if (timer > 0) timer <= timer - 1; else {timer, state} <= {9'd200, 3'd5}; end
                5: if (timer > 0) timer <= timer - 1; else begin rd_ptr <= rd_ptr + 1; state <= 0; end
            endcase
        end
    end

    // --- 6. OPL2 CORE & DAC ---
    reg cen;
    always @(posedge phi2) cen <= ~cen;

    wire [15:0] snd;
    jtopl2 opl_inst (
        .clk(phi2), .cen(cen), .rst(rst), .cs_n(1'b0),
        .wr_n(h_wr_n), .addr(h_a0), .din(h_a0 ? cur_v : cur_r), 
        .snd(snd)
    );

    reg [15:0] dac_buf;
    always @(posedge clk) dac_buf <= snd;
    sigma_delta_dac dac_inst (.clk(clk), .rst(1'b0), .dac_in(dac_buf), .dac_out(audio_out));

    // LED: On if OPL is enabled, flickers when processing data
    assign led = opl_enabled ? (rd_ptr == wr_ptr ? 1'b1 : cen) : 1'b0;

endmodule