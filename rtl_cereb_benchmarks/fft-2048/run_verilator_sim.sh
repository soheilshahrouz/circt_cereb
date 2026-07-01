#!/usr/bin/env bash
# Verilator simulation for fftmain_wrapper; dumps the first N outputs as hex.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOP_MODULE="fftmain_wrapper"
BUILD_DIR="${SCRIPT_DIR}/build/verilator"
OBJ_DIR="${BUILD_DIR}/obj_dir"
SIM_CPP="${SCRIPT_DIR}/sim/fftmain_wrapper_tb.cpp"
NUM_OUTPUTS="${NUM_OUTPUTS:-20000}"
OUTPUT_FILE="${OUTPUT_FILE:-${SCRIPT_DIR}/build/fftmain_wrapper_outputs.txt}"

DESIGN_SOURCES=(
  "${SCRIPT_DIR}/bimpy.v"
  "${SCRIPT_DIR}/bitreverse.v"
  "${SCRIPT_DIR}/butterfly.v"
  "${SCRIPT_DIR}/convround.v"
  "${SCRIPT_DIR}/fftmain.v"
  "${SCRIPT_DIR}/fftmain_wrapper.v"
  "${SCRIPT_DIR}/fftstage.v"
  "${SCRIPT_DIR}/hwbfly.v"
  "${SCRIPT_DIR}/laststage.v"
  "${SCRIPT_DIR}/longbimpy.v"
  "${SCRIPT_DIR}/qtrstage.v"
)

if [[ -n "${VERILATOR_ROOT:-}" && -x "${VERILATOR_ROOT}/bin/verilator" ]]; then
  VERILATOR="${VERILATOR_ROOT}/bin/verilator"
else
  VERILATOR="${VERILATOR:-verilator}"
fi

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: missing executable: $1" >&2
    exit 1
  fi
}

require_tool "${VERILATOR}"
require_tool g++

mkdir -p "${BUILD_DIR}" "${SCRIPT_DIR}/build"
rm -rf "${OBJ_DIR}"

echo "==> Verilating ${TOP_MODULE}"
"${VERILATOR}" --cc --exe --build --timing -Wall -Wno-fatal \
  -Mdir "${OBJ_DIR}" \
  --top-module "${TOP_MODULE}" \
  -CFLAGS "-O2 -std=c++17" \
  -LDFLAGS "-lpthread" \
  -o "V${TOP_MODULE}" \
  "${DESIGN_SOURCES[@]}" \
  "${SIM_CPP}"

echo "==> Running simulation (${NUM_OUTPUTS} outputs -> ${OUTPUT_FILE})"
"${OBJ_DIR}/V${TOP_MODULE}" "${NUM_OUTPUTS}" "${OUTPUT_FILE}"

echo "==> Done"
echo "  Output file: ${OUTPUT_FILE}"
echo "  Line format: <o_result_hex_44b> <o_sync>"
