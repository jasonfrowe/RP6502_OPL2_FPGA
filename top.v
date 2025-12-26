module top (
    input phi2,             // 8MHz PIX Clock
    input [3:0] pix,        // PIX Data
    input clk,              // 16MHz Onboard Clock (for DAC)
    output audio_out,
    output reg led          
);

    // 1. Power-On Reset
    reg [15:0] reset_cnt = 0;
    wire rst = !reset_cnt[15]; 
    always @(posedge phi2) if (reset_cnt[15] == 0) reset_cnt <= reset_cnt + 1;

    // 2. PIX Decoder
    reg [15:0] n_shift, p_shift;
    always @(negedge phi2) n_shift <= {n_shift[11:0], pix};
    always @(posedge phi2) p_shift <= {p_shift[11:0], pix};
    wire [31:0] frame = {n_shift[15:12], p_shift[15:12], n_shift[11:8], p_shift[11:8],
                         n_shift[7:4], p_shift[7:4], n_shift[3:0], p_shift[3:0]};

    wire is_ria      = (frame[31:29] == 3'b000) && frame[28];
    wire is_opl_data = (frame[15:1] == 15'h7F80); // FF00-FF01
    wire is_opl_fifo_clr = (frame[15:0] == 16'hFF02); // FF02 to clear buffer

    // ------------------------------------------------------------
    // 3. 256-ENTRY FIFO (Covers full chip init)
    // ------------------------------------------------------------
    reg [15:0] fifo [0:255];
    reg [7:0]  wr_ptr = 0;
    reg [7:0]  rd_ptr = 0;
    reg [7:0]  latched_index;
    
    // Internal Flush Signal
    reg fifo_flush = 0;

    always @(negedge phi2) begin
        if (rst || fifo_flush) begin
            wr_ptr <= 0;
            fifo_flush <= 0;
        end else if (pix[0] && is_ria) begin
            if (is_opl_data) begin
                if (frame[0] == 0) latched_index <= frame[23:16]; 
                else begin
                    fifo[wr_ptr] <= {latched_index, frame[23:16]};
                    wr_ptr <= wr_ptr + 1;
                end
            end else if (is_opl_fifo_clr) begin
                fifo_flush <= 1; // Mark for clear on next cycle
            end
        end
    end

    // ------------------------------------------------------------
    // 4. DRIVER STATE MACHINE (Drip-feed OPL2)
    // ------------------------------------------------------------
    reg [2:0] state = 0;
    reg [8:0] wait_timer = 0;
    reg [7:0] out_reg, out_val;
    reg hw_wr_n = 1;
    reg hw_a0 = 0;

    always @(posedge phi2) begin
        if (rst || fifo_flush) begin
            state <= 0;
            rd_ptr <= 0;
            hw_wr_n <= 1;
        end else begin
            case (state)
                0: if (rd_ptr != wr_ptr) begin // Grab next pair
                    {out_reg, out_val} <= fifo[rd_ptr];
                    state <= 1;
                end
                1: begin // ADDR Pulse
                    hw_a0 <= 0; hw_wr_n <= 0;
                    wait_timer <= 12; state <= 2;
                end
                2: begin // ADDR Wait (3.3us)
                    hw_wr_n <= 1;
                    if (wait_timer > 0) wait_timer <= wait_timer - 1;
                    else {wait_timer, state} <= {9'd30, 3'd3};
                end
                3: begin // DATA Pulse
                    hw_a0 <= 1; hw_wr_n <= 0;
                    wait_timer <= 12; state <= 4;
                end
                4: begin // DATA Wait (23us)
                    hw_wr_n <= 1;
                    if (wait_timer > 0) wait_timer <= wait_timer - 1;
                    else {wait_timer, state} <= {9'd200, 3'd5};
                end
                5: if (wait_timer > 0) wait_timer <= wait_timer - 1;
                   else begin rd_ptr <= rd_ptr + 1; state <= 0; end
            endcase
        end
    end

    // ------------------------------------------------------------
    // 5. CORE & DAC
    // ------------------------------------------------------------
    reg cen_toggle;
    always @(posedge phi2) cen_toggle <= ~cen_toggle;

    wire signed [15:0] opl_snd;
    jtopl2 opl_inst (
        .clk(phi2), .cen(cen_toggle), .rst(rst), .cs_n(1'b0),
        .wr_n(hw_wr_n), .addr(hw_a0), .din(hw_a0 ? out_val : out_reg),
        .snd(opl_snd)
    );

    reg [15:0] dac_buf;
    always @(posedge clk) dac_buf <= opl_snd;
    sigma_delta_dac dac_inst (.clk(clk), .rst(1'b0), .dac_in(dac_buf), .dac_out(audio_out));
    
    // LED: Dim when busy, Fast flash if overflowed
    assign led = (rd_ptr != wr_ptr);

endmodule