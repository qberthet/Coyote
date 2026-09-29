`timescale 1ns / 1ps
// Test bench for rdma_mux_retrans on the DCMAC path (NET_DCMAC), where roce_stack ties off the
// card memory that holds the retransmission buffer: the memory command queues always accept and
// no memory read data ever arrives. Four transfers go through: a WRITE (payload pushed on the
// request stream), a retransmission (actv 0), a READ response, and another WRITE. The wire must
// get every beat, in request order. See run.sh.
import lynxTypes::*;

// Behavioural stand-ins for the Xilinx FIFO IPs that meta_queue and the mux's data queues wrap
module meta_queue #(parameter integer DATA_BITS = 32) (
    input logic aclk,
    input logic aresetn,
    metaIntf.s  s_meta,
    metaIntf.m  m_meta
);
    logic [DATA_BITS-1:0] mem [16];
    logic [4:0] wp, rp;
    wire empty = wp == rp;
    wire full = (wp[3:0] == rp[3:0]) && (wp[4] != rp[4]);
    assign s_meta.ready = aresetn && !full;
    assign m_meta.valid = !empty;
    assign m_meta.data = mem[rp[3:0]];
    always_ff @(posedge aclk) begin
        if (!aresetn) begin wp <= 0; rp <= 0; end
        else begin
            if (s_meta.valid && s_meta.ready) begin mem[wp[3:0]] <= s_meta.data; wp <= wp + 1; end
            if (m_meta.ready && !empty) rp <= rp + 1;
        end
    end
endmodule

module axis_data_fifo_512 (
    input  logic         s_axis_aresetn,
    input  logic         s_axis_aclk,
    input  logic         s_axis_tvalid,
    output logic         s_axis_tready,
    input  logic [511:0] s_axis_tdata,
    input  logic [63:0]  s_axis_tkeep,
    input  logic         s_axis_tlast,
    output logic         m_axis_tvalid,
    input  logic         m_axis_tready,
    output logic [511:0] m_axis_tdata,
    output logic [63:0]  m_axis_tkeep,
    output logic         m_axis_tlast
);
    logic [576:0] mem [16];
    logic [4:0] wp, rp;
    wire empty = wp == rp;
    wire full = (wp[3:0] == rp[3:0]) && (wp[4] != rp[4]);
    assign s_axis_tready = s_axis_aresetn && !full;
    assign m_axis_tvalid = !empty;
    assign {m_axis_tlast, m_axis_tkeep, m_axis_tdata} = mem[rp[3:0]];
    always_ff @(posedge s_axis_aclk) begin
        if (!s_axis_aresetn) begin wp <= 0; rp <= 0; end
        else begin
            if (s_axis_tvalid && s_axis_tready) begin
                mem[wp[3:0]] <= {s_axis_tlast, s_axis_tkeep, s_axis_tdata};
                wp <= wp + 1;
            end
            if (m_axis_tready && !empty) rp <= rp + 1;
        end
    end
endmodule

module tb;
    logic aclk = 0;
    logic aresetn = 0;
    always #1 aclk = ~aclk;

    metaIntf #(.STYPE(req_t)) req_net (.*);
    metaIntf #(.STYPE(req_t)) req_user (.*);
    metaIntf #(.STYPE(logic[MEM_CMD_BITS-1:0])) ddr_rd (.*);
    metaIntf #(.STYPE(logic[MEM_CMD_BITS-1:0])) ddr_wr (.*);
    AXI4S #(.AXI4S_DATA_BITS(AXI_NET_BITS)) user_req (.*);
    AXI4S #(.AXI4S_DATA_BITS(AXI_NET_BITS)) user_rsp (.*);
    AXI4S #(.AXI4S_DATA_BITS(AXI_NET_BITS)) net (.*);
    AXI4S #(.AXI4S_DATA_BITS(AXI_NET_BITS)) ddr_in (.*);
    AXI4S #(.AXI4S_DATA_BITS(AXI_NET_BITS)) ddr_out (.*);

    rdma_mux_retrans dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_req_net(req_net), .m_req_user(req_user),
        .s_axis_user_req(user_req), .s_axis_user_rsp(user_rsp), .m_axis_net(net),
        .m_req_ddr_rd(ddr_rd), .m_req_ddr_wr(ddr_wr), .s_axis_ddr(ddr_in), .m_axis_ddr(ddr_out)
    );

    // The DCMAC tie-off in roce_stack
    assign ddr_rd.ready = 1'b1;
    assign ddr_wr.ready = 1'b1;
    assign ddr_out.tready = 1'b1;
    assign ddr_in.tvalid = 1'b0;
    assign ddr_in.tdata = '0;
    assign ddr_in.tkeep = '0;
    assign ddr_in.tlast = 1'b0;
    assign net.tready = 1'b1;
    assign req_user.ready = 1'b1;

    function automatic req_t mkreq(logic [4:0] op, logic actv, logic host, logic [47:0] vaddr, int len);
        req_t r = '0;
        r.opcode = op; r.actv = actv; r.host = host; r.vaddr = vaddr; r.len = len; r.last = 1'b1;
        return r;
    endfunction

    // Beat tag: vaddr[31:16] of the transfer it belongs to, and the beat index
    function automatic logic [31:0] tag(logic [47:0] vaddr, int beat);
        return {vaddr[31:16], 16'(beat)};
    endfunction

    int errors = 0;

    // Requests from the stack: WRITE, retransmission, READ response, WRITE
    req_t reqs [4];
    initial begin
        reqs[0] = mkreq(RC_RDMA_WRITE_ONLY,     1, 0, 48'h1000_0000, 128);
        reqs[1] = mkreq(RC_RDMA_WRITE_ONLY,     0, 0, 48'h2000_0000, 128);
        reqs[2] = mkreq(RC_RDMA_READ_RESP_ONLY, 1, 1, 48'h3000_0000, 64);
        reqs[3] = mkreq(RC_RDMA_WRITE_ONLY,     1, 0, 48'h4000_0000, 64);
        req_net.valid = 0;
        req_net.data = '0;
        wait (aresetn);
        foreach (reqs[i]) begin
            @(posedge aclk);
            req_net.valid <= 1; req_net.data <= reqs[i];
            do @(posedge aclk); while (!req_net.ready);
            req_net.valid <= 0;
        end
    end

    // Payloads of local WRITEs arrive pushed on the request stream, in order
    initial begin
        user_req.tvalid = 0; user_req.tdata = '0; user_req.tkeep = '1; user_req.tlast = 0;
        wait (aresetn);
        for (int i = 0; i < 4; i++) begin
            if (reqs[i].actv && reqs[i].opcode == RC_RDMA_WRITE_ONLY) begin
                for (int b = 0; b < reqs[i].len / 64; b++) begin
                    @(posedge aclk);
                    user_req.tvalid <= 1; user_req.tdata <= tag(reqs[i].vaddr, b);
                    user_req.tlast <= (b == reqs[i].len / 64 - 1);
                    do @(posedge aclk); while (!user_req.tready);
                    user_req.tvalid <= 0;
                end
            end
        end
    end

    // User side: serves each request from "host memory" on the response stream, some cycles later
    req_t served [$];
    int n_user_reqs = 0;
    always @(posedge aclk) if (req_user.valid && req_user.ready) begin
        served.push_back(req_user.data);
        n_user_reqs++;
    end
    initial begin
        user_rsp.tvalid = 0; user_rsp.tdata = '0; user_rsp.tkeep = '1; user_rsp.tlast = 0;
        forever begin
            req_t r;
            wait (served.size() > 0);
            r = served.pop_front();
            repeat (10) @(posedge aclk);
            for (int b = 0; b < r.len / 64; b++) begin
                user_rsp.tvalid <= 1; user_rsp.tdata <= tag(r.vaddr, b);
                user_rsp.tlast <= (b == r.len / 64 - 1);
                do @(posedge aclk); while (!user_rsp.tready);
                user_rsp.tvalid <= 0;
            end
        end
    end

    // Checks on what the mux asks of each side
    int n_ddr_rd = 0, n_ddr_wr = 0;
    always @(posedge aclk) begin
        if (ddr_rd.valid && ddr_rd.ready) n_ddr_rd++;
        if (ddr_wr.valid && ddr_wr.ready) n_ddr_wr++;
        if (req_user.valid && req_user.ready) begin
            $display("TB user request: vaddr %h opcode %h actv %b host %b len %0d",
                     req_user.data.vaddr, req_user.data.opcode, req_user.data.actv, req_user.data.host, req_user.data.len);
            if (!req_user.data.actv || !req_user.data.host) begin
                $display("TB FAIL: user request without actv/host set"); errors++;
            end
        end
    end

    // The wire must see every beat, in request order
    localparam int N_BEATS = 6;
    localparam bit [31:0] EXPECTED [N_BEATS] = '{32'h1000_0000, 32'h1000_0001, 32'h2000_0000,
                                                 32'h2000_0001, 32'h3000_0000, 32'h4000_0000};
    int n_net = 0;
    always @(posedge aclk) if (net.tvalid && net.tready) begin
        bit [31:0] got;
        got = net.tdata[31:0];
        $display("TB wire beat %0d: %h", n_net, got);
        if (n_net >= N_BEATS || got != EXPECTED[n_net]) begin
            $display("TB FAIL: unexpected beat %0d", n_net); errors++;
        end
        n_net++;
    end

    initial begin
        repeat (5) @(posedge aclk);
        aresetn <= 1;
        repeat (2000) @(posedge aclk);
        if (n_net != N_BEATS) begin
            $display("TB FAIL: the wire got %0d of %0d beats (the mux stalled)", n_net, N_BEATS); errors++;
        end
        if (n_user_reqs != 2) begin
            $display("TB FAIL: %0d user requests, expected 2 (the retransmission and the READ response)", n_user_reqs); errors++;
        end
        if (n_ddr_rd != 0) begin
            $display("TB FAIL: %0d reads from the tied-off retransmission memory", n_ddr_rd); errors++;
        end
        $display("TB memory write commands: %0d (sunk by the tie-off)", n_ddr_wr);
        if (errors == 0) $display("TB PASS");
        else $display("TB FAILED with %0d error(s)", errors);
        $finish;
    end
endmodule
