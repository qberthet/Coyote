#!/usr/bin/env bash
# Simulates rdma_mux_retrans against tb_rdma_mux_retrans.sv with xsim. The package the modules use
# is generated from example 01's configuration for the V80, which defines NET_DCMAC. Needs cmake,
# python3 (jinja2) and Vivado's xsim in PATH.
#   sim/tests/rdma_mux_retrans/run.sh
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
CYT_DIR=$(cd "$TEST_DIR/../../.." && pwd)
HDL=$CYT_DIR/hw/hdl
BUILD=$TEST_DIR/build

rm -rf "$BUILD" && mkdir -p "$BUILD" && cd "$BUILD"
cmake "$CYT_DIR/examples/01_hello_world/hw" -DFDEV_NAME=v80 > cmake.log 2>&1
mkdir -p sim && python3 write_hdl.py 3 0 0 > write_hdl.log
grep -q '`define NET_DCMAC' sim/lynx_pkg.sv

xvlog -sv -i "$HDL/pkg" sim/lynx_pkg.sv "$HDL/pkg/axi_intf.sv" "$HDL/pkg/lynx_intf.sv" \
    "$HDL/common/queues/fifo.sv" "$HDL/common/queues/queue_stream.sv" \
    "$HDL/network/rdma/rdma_mux_retrans.sv" "$TEST_DIR/tb_rdma_mux_retrans.sv" > xvlog.log 2>&1
xelab -timescale 1ns/1ps tb -s tb > xelab.log 2>&1
xsim tb -R > xsim.log 2>&1
grep '^TB' xsim.log
grep -q '^TB PASS' xsim.log
