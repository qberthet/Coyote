// Test bench for icrc (hw/hdl/network/rdma/icrc.sv), which appends the RoCEv2 ICRC on the TX
// path. Every packet must leave with its bytes unchanged, followed by the ICRC of its masked
// headers and payload, computed here by a reference CRC. Packets enter through a small skid FIFO,
// as they do behind roce_stack's register slices, so a sink that stalls lets the first beat of a
// packet queue up right behind the last beat of the previous one. Each scenario starts from a
// reset and reports the cycles per packet, from the first beat in to the last beat out. See run.sh.
`timescale 1ns / 1ps

module tb;

logic clk = 1'b0, rstn = 1'b0;
always #1.28 clk = ~clk;

AXI4S #(.AXI4S_DATA_BITS(512)) s_axis (.aclk(clk), .aresetn(rstn));
AXI4S #(.AXI4S_DATA_BITS(512)) m_axis (.aclk(clk), .aresetn(rstn));

icrc dut (.m_axis_rx(s_axis), .m_axis_tx(m_axis), .nclk(clk), .nresetn(rstn));

// ---- Packets as BALBOA hands them to the icrc: IPv4, UDP, BTH (SEND_ONLY), payload

function automatic logic [7:0] pbyte(int p, int i, int len);
    logic [15:0] il = 16'(len), ul = 16'(len - 20), id = 16'(p), ck = 16'(p * 37);
    logic [23:0] psn = 24'(p);
    case (i)
        0: return 8'h45;       1: return 8'h00;         // version/IHL, TOS (masked)
        2: return il[15:8];    3: return il[7:0];
        4: return id[15:8];    5: return id[7:0];
        6: return 8'h40;       7: return 8'h00;
        8: return 8'h40;       9: return 8'h11;         // TTL (masked), UDP
        10: return ck[15:8];   11: return ck[7:0];      // header checksum (masked)
        12: return 8'hc0;      13: return 8'ha8;        14: return 8'h02;      15: return 8'he6;
        16: return 8'hc0;      17: return 8'ha8;        18: return 8'h02;      19: return 8'hc8;
        20: return 8'hc0;      21: return id[7:0];      // UDP source port
        22: return 8'h12;      23: return 8'hb7;        // 4791
        24: return ul[15:8];   25: return ul[7:0];
        26: return 8'h00;      27: return 8'h00;        // UDP checksum (masked)
        28: return 8'h04;      29: return 8'h40;        30: return 8'hff;      31: return 8'hff;
        32: return 8'h00;                               // resv8a (masked)
        33: return 8'h01;      34: return 8'h52;        35: return 8'(8'h45 + p % 4);
        36: return 8'h80;
        37: return psn[23:16]; 38: return psn[15:8];    39: return psn[7:0];
        default: return 8'(p * 131 + i * 7);
    endcase
endfunction

function automatic bit masked(int i);
    return i == 1 || i == 8 || i == 10 || i == 11 || i == 26 || i == 27 || i == 32;
endfunction

logic [31:0] crc_tab [256];
initial begin
    logic [31:0] c;
    for (int n = 0; n < 256; n++) begin
        c = n;
        for (int j = 0; j < 8; j++) c = c[0] ? (c >> 1) ^ 32'hedb88320 : c >> 1;
        crc_tab[n] = c;
    end
end

// CRC-32 over 8 bytes of ones (RoCEv2's stand-in for the LRH) and the masked packet
function automatic logic [31:0] ref_icrc(int p, int len);
    logic [31:0] c = 32'hffffffff;
    logic [7:0] b;
    for (int i = 0; i < 8; i++) c = (c >> 8) ^ crc_tab[8'(c[7:0] ^ 8'hff)];
    for (int i = 0; i < len; i++) begin
        b = masked(i) ? 8'hff : pbyte(p, i, len);
        c = (c >> 8) ^ crc_tab[8'(c[7:0] ^ b)];
    end
    return ~c;
endfunction

typedef struct packed { logic [511:0] data; logic [63:0] keep; logic last; } beat_t;

function automatic beat_t make_beat(int p, int len, int w);
    beat_t b;
    int i;
    b.data = '0;
    b.keep = '0;
    for (int l = 0; l < 64; l++) begin
        i = w * 64 + l;
        if (i < len) begin
            b.data[l * 8 +: 8] = pbyte(p, i, len);
            b.keep[l] = 1'b1;
        end
    end
    b.last = (w == (len + 63) / 64 - 1);
    return b;
endfunction

// ---- Source: a producer that makes one beat per cycle and idles between packets, and a skid
// FIFO of QD beats in front of the icrc

localparam int QD = 4;
beat_t fifo [$];
beat_t nb;
int todo_p[$], todo_len[$], todo_gap[$];
int exp_p[$], exp_len[$];
int cur_p = -1, cur_len = 0, cur_w = 0, cur_gap = 0, idle = 0;
longint cycle = 0, t_first_in = -1, t_last_out = 0;
always @(posedge clk) cycle++;

always @(posedge clk) begin
    if (!rstn) begin
        fifo.delete();
        cur_p = -1;
        idle = 0;
        s_axis.tvalid <= 1'b0;
    end else begin
        if (s_axis.tvalid && s_axis.tready) begin
            void'(fifo.pop_front());
            if (t_first_in < 0) t_first_in = cycle;
        end
        if (idle > 0) begin
            idle--;
        end else begin
            if (cur_p < 0 && todo_p.size() > 0) begin
                cur_p = todo_p.pop_front();
                cur_len = todo_len.pop_front();
                cur_gap = todo_gap.pop_front();
                cur_w = 0;
                exp_p.push_back(cur_p);
                exp_len.push_back(cur_len);
            end
            if (cur_p >= 0 && fifo.size() < QD) begin
                nb = make_beat(cur_p, cur_len, cur_w);
                fifo.push_back(nb);
                cur_w++;
                if (nb.last) begin
                    cur_p = -1;
                    idle = cur_gap;
                end
            end
        end
        s_axis.tvalid <= fifo.size() > 0;
        if (fifo.size() > 0) begin
            s_axis.tdata <= fifo[0].data;
            s_axis.tkeep <= fifo[0].keep;
            s_axis.tlast <= fifo[0].last;
        end
    end
end

// ---- Sink: ready except for random stalls of up to bp_burst cycles, bp_permil per mille of cycles

int bp_permil = 0, bp_burst = 1, stall_left = 0;
always @(posedge clk) begin
    if (stall_left > 0) begin
        stall_left--;
        m_axis.tready <= 1'b0;
    end else if (bp_permil > 0 && $urandom % 1000 < bp_permil) begin
        stall_left = $urandom % bp_burst;
        m_axis.tready <= 1'b0;
    end else begin
        m_axis.tready <= 1'b1;
    end
end

// ---- Monitor: rebuild each packet and check it against the next one expected

logic [7:0] rx [$];
int n_rx, n_ok, n_crc, n_data, n_len, n_keep, n_unexp;

task automatic check_packet();
    int p, len, bad = 0;
    logic [31:0] got, want;
    n_rx++;
    if (exp_p.size() == 0) begin
        n_unexp++;
        return;
    end
    p = exp_p.pop_front();
    len = exp_len.pop_front();
    if (rx.size() != len + 4) begin
        n_len++;
        if (n_len <= 3) $display("TB   packet %0d (%0d B): %0d B out, expected %0d", p, len, rx.size(), len + 4);
        return;
    end
    for (int i = 0; i < len; i++) if (rx[i] !== pbyte(p, i, len)) bad++;
    got = {rx[len + 3], rx[len + 2], rx[len + 1], rx[len]};
    want = ref_icrc(p, len);
    if (bad > 0) begin
        n_data++;
        if (n_data <= 3) $display("TB   packet %0d (%0d B): %0d bytes changed", p, len, bad);
    end else if (got !== want) begin
        n_crc++;
        if (n_crc <= 3) $display("TB   packet %0d (%0d B): ICRC %08x, expected %08x", p, len, got, want);
    end else begin
        n_ok++;
    end
endtask

always @(posedge clk) begin
    if (rstn && m_axis.tvalid && m_axis.tready) begin
        if ((m_axis.tkeep & (m_axis.tkeep + 64'd1)) != 64'd0) n_keep++;  // keep must be contiguous from byte 0
        for (int l = 0; l < 64; l++) if (m_axis.tkeep[l]) rx.push_back(m_axis.tdata[l * 8 +: 8]);
        if (m_axis.tlast) begin
            t_last_out = cycle;
            check_packet();
            rx.delete();
        end
    end
end

// ---- Scenarios: lens cycles through the given IP packet lengths (random multiples of 4 from 64
// to 4136 when empty), gaps are idle producer cycles after each packet

int next_p = 0, failures = 0;

task automatic run(string name, int lens[], int n, int gap_lo, int gap_hi, int permil, int burst);
    int waited = 0;
    bit pass;
    rstn <= 1'b0;
    bp_permil = 0;
    todo_p.delete(); todo_len.delete(); todo_gap.delete();
    exp_p.delete(); exp_len.delete();
    rx.delete();
    repeat (10) @(posedge clk);
    rstn <= 1'b1;
    repeat (5) @(posedge clk);
    n_rx = 0; n_ok = 0; n_crc = 0; n_data = 0; n_len = 0; n_keep = 0; n_unexp = 0;
    t_first_in = -1;
    bp_permil = permil;
    bp_burst = burst;
    for (int k = 0; k < n; k++) begin
        todo_p.push_back(next_p++);
        todo_len.push_back(lens.size() > 0 ? lens[k % lens.size()] : 64 + 4 * ($urandom % 1019));
        todo_gap.push_back(gap_lo + $urandom % (gap_hi - gap_lo + 1));
    end
    while (n_rx < n && waited < n * 200 + 2000) begin
        @(posedge clk);
        waited++;
    end
    repeat (50) @(posedge clk);
    pass = n_ok == n && n_keep == 0 && n_unexp == 0;
    if (!pass) failures++;
    $display("TB %s: %0d packets, %0d ok, %0d bad ICRC, %0d bad data, %0d bad length, %0d bad keep, %0d missing, %.1f cycles/packet: %s",
             name, n, n_ok, n_crc, n_data, n_len, n_keep, n - n_rx, real'(t_last_out - t_first_in) / n,
             pass ? "PASS" : "FAIL");
endtask

// IP packet lengths: 3008 ends on a full beat, 4072 and 4136 on 40 bytes, 3000 on 56 bytes
int L_ISO[] = '{64, 100, 128, 1244, 2420, 2984, 3000, 3008, 4072, 4136};
int L_40[] = '{4072};
int L_FULL[] = '{3008};
int L_56[] = '{3000};
int L_RANDOM[];
// Every tail, 0 to 60 bytes past the last full beat; short packets of one or two beats; and a
// 3160-byte packet (a 24-byte tail)
int L_TAILS[] = '{3008, 3012, 3016, 3020, 3024, 3028, 3032, 3036, 3040, 3044, 3048, 3052, 3056, 3060, 3064, 3068};
int L_SHORT[] = '{44, 48, 60, 64, 68, 100, 124, 128};
int L_3160[] = '{3160};

initial begin
    s_axis.tvalid = 1'b0;
    s_axis.tdata = '0;
    s_axis.tkeep = '0;
    s_axis.tlast = 1'b0;
    m_axis.tready = 1'b1;
    run("isolated", L_ISO, 30, 6, 6, 0, 1);
    run("back_to_back_40B_tail", L_40, 20, 0, 0, 0, 1);
    run("back_to_back_full_tail", L_FULL, 20, 0, 0, 0, 1);
    run("gap2_sink_stalls_40B_tail", L_40, 400, 2, 2, 30, 8);
    run("gap2_sink_stalls_full_tail", L_FULL, 400, 2, 2, 30, 8);
    run("gap2_sink_stalls_56B_tail", L_56, 200, 2, 2, 30, 8);
    run("random_lengths_gaps_stalls", L_RANDOM, 1000, 0, 3, 50, 8);
    run("back_to_back_every_tail", L_TAILS, 160, 0, 0, 0, 1);
    run("back_to_back_sink_stalls_every_tail", L_TAILS, 480, 0, 0, 30, 8);
    run("back_to_back_short", L_SHORT, 200, 0, 0, 0, 1);
    run("back_to_back_short_sink_stalls", L_SHORT, 400, 0, 0, 50, 8);
    run("back_to_back_3160", L_3160, 100, 0, 0, 0, 1);
    if (failures == 0) $display("TB ALL PASS");
    else $display("TB SOME SCENARIOS FAILED");
    $finish;
end

endmodule
