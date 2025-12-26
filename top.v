module top (
    input phi2,             // 8MHz PIX Clock
    input [3:0] pix,        // PIX Data
    input clk,              // 16MHz Onboard Clock (for DAC)
    output audio_out,
    output reg led          
);

    // ------------------------------------------------------------
    // 1. POWER-ON RESET
    // ------------------------------------------------------------
    reg [15:0] reset_cnt = 0;
    wire rst = !reset_cnt[15]; // Active-high reset for ~8ms at 8MHz
    always @(posedge phi2) if (reset_cnt[15] == 0) reset_cnt <= reset_cnt + 1;

    // ------------------------------------------------------------
    // 2. PIX DECODER (phi2 Domain)
    // ------------------------------------------------------------
    reg [15:0] n_shift, p_shift;
    always @(negedge phi2) n_shift <= {n_shift[11:0], pix};
    always @(posedge phi2) p_shift <= {p_shift[11:0], pix};

    wire [31:0] frame = {
        n_shift[15:12], p_shift[15:12], 
        n_shift[11:8],  p_shift[11:8],  
        n_shift[7:4],   p_shift[7:4],   
        n_shift[3:0],   p_shift[3:0]    
    };

    wire is_ria   = (frame[31:29] == 3'b000) && frame[28];
    wire is_opl2  = (frame[15:1] == 15'h7F80); // Addresses FF00 and FF01
    
    // Logic to capture and EXTEND the write pulse
    reg [2:0] we_extend;
    reg [7:0] opl_din;
    reg opl_a0;
    reg [23:0] led_timer;

    always @(negedge phi2) begin
        if (pix[0] && is_ria && is_opl2) begin
            we_extend <= 3'b111;       // Hold write for 4 cycles
            opl_din   <= frame[23:16];
            opl_a0    <= frame[0];
            led_timer <= 24'h800000;
        end else begin
            if (we_extend > 0) we_extend <= we_extend - 1;
            if (led_timer > 0) led_timer <= led_timer - 1;
        end
    end

    always @(phi2) led = (led_timer > 0);

    // ------------------------------------------------------------
    // 3. OPL2 CLOCK ENABLE & WRITE SIGNAL
    // ------------------------------------------------------------
    reg cen_toggle;
    always @(posedge phi2) cen_toggle <= ~cen_toggle;

    // Active-low Write Enable pulse
    wire wr_n = !(we_extend > 0);

    // ------------------------------------------------------------
    // 4. JTOPL2 (YM3812) CORE
    // ------------------------------------------------------------
    wire signed [15:0] opl_snd;
    
    jtopl2 opl_inst (
        .clk    (phi2),      
        .cen    (cen_toggle),  
        .rst    (rst),       // Power-on reset
        .cs_n   (1'b0),      
        .wr_n   (wr_n),      
        .addr   (opl_a0),
        .din    (opl_din),
        .dout   (),          
        .snd    (opl_snd),   
        .sample (),
        .irq_n  ()
    );

    // ------------------------------------------------------------
    // 5. AUDIO OUTPUT (Sigma-Delta DAC)
    // ------------------------------------------------------------
    reg signed [15:0] dac_buffer;
    always @(posedge clk) dac_buffer <= opl_snd;

    sigma_delta_dac dac_inst (
        .clk(clk),
        .rst(1'b0),
        .dac_in(dac_buffer),
        .dac_out(audio_out)
    );

endmodule