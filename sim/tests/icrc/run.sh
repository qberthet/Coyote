#!/usr/bin/env bash
# Checks icrc's UNSHIFT table (unshift.py), then simulates icrc against tb_icrc.sv with xsim. The
# package the modules use is generated from example 01's configuration. Needs cmake, python3
# (jinja2) and Vivado's xsim in PATH.
#   sim/tests/icrc/run.sh [FDEV_NAME]      (default u55c)
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
CYT_DIR=$(cd "$TEST_DIR/../../.." && pwd)
BUILD=$TEST_DIR/build

python3 "$TEST_DIR/unshift.py" "$CYT_DIR/hw/hdl/network/rdma/icrc.sv"

rm -rf "$BUILD" && mkdir -p "$BUILD" && cd "$BUILD"
cmake "$CYT_DIR/examples/01_hello_world/hw" -DFDEV_NAME="${1:-u55c}" > cmake.log 2>&1
mkdir -p sim && python3 write_hdl.py 3 0 0 > write_hdl.log

xvlog -sv sim/lynx_pkg.sv "$CYT_DIR/hw/hdl/pkg/axi_intf.sv" "$CYT_DIR/hw/hdl/network/rdma/buffer_fifo.sv" \
    "$CYT_DIR/hw/hdl/network/rdma/icrc.sv" "$TEST_DIR/tb_icrc.sv" > xvlog.log 2>&1
xelab -timescale 1ns/1ps tb -s tb > xelab.log 2>&1
xsim tb -R > xsim.log 2>&1
grep '^TB' xsim.log
grep -q '^TB ALL PASS' xsim.log
