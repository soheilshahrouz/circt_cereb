#!/usr/bin/env bash
# Push dual_ram_mix.sv through circt-verilog and arcilator.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

DESIGN_SV="${SCRIPT_DIR}/dual_ram_mix.sv"
TOP_MODULE="DualRamMix"
BUILD_DIR="${SCRIPT_DIR}/build"
ARCILATOR_IR_DUMP_DIR="${ARCILATOR_IR_DUMP_DIR:-${BUILD_DIR}/arcilator_pass_ir}"
PASS_IR_DIR="${BUILD_DIR}/pass_ir"

HW_MLIR="${BUILD_DIR}/dual_ram_mix_hw.mlir"
STATE_JSON="${BUILD_DIR}/dual_ram_mix_state.json"
LLVM_IR="${BUILD_DIR}/dual_ram_mix.ll"
OBJECT_FILE="${BUILD_DIR}/dual_ram_mix.o"

CIRCT_VERILOG="${CIRCT_VERILOG:-${REPO_ROOT}/build/bin/circt-verilog}"
CIRCT_OPT="${CIRCT_OPT:-${REPO_ROOT}/build/bin/circt-opt}"
ARCILATOR="${ARCILATOR:-${REPO_ROOT}/build/bin/arcilator}"
OPT="${OPT:-${REPO_ROOT}/llvm/build/bin/opt}"
LLC="${LLC:-${REPO_ROOT}/llvm/build/bin/llc}"

ARCILATOR_ARGS=(
  --dedup-clocks=true
  --inline-call-arcs=true
  --specialize-state-constants=true
  --dedup-call-arguments=true
  --remove-unused-defines=true
)

if [[ -n "${ARCILATOR_IR_DUMP_DIR}" ]]; then
  ARCILATOR_ARGS+=(
    -mlir-print-ir-after-all
    -mlir-print-ir-tree-dir="${ARCILATOR_IR_DUMP_DIR}"
  )
fi

copy_pass_ir() {
  local pass_suffix="$1"
  local out_name="$2"
  local src=""

  src="$(find "${ARCILATOR_IR_DUMP_DIR}" -name "*_${pass_suffix}.mlir" -print -quit)"
  if [[ -z "${src}" ]]; then
    echo "warning: arcilator did not dump pass '${pass_suffix}'" >&2
    return 1
  fi

  cp "${src}" "${PASS_IR_DIR}/${out_name}"
}

write_enabled_pass_outputs() {
  local specialize_ir="${PASS_IR_DIR}/after_specialize_state_constants.mlir"

  mkdir -p "${PASS_IR_DIR}"

  copy_pass_ir "arc-dedup-clocks" "after_dedup_clocks.mlir"
  copy_pass_ir "arc-inline-call-arcs" "after_inline_call_arcs.mlir"
  copy_pass_ir "arc-specialize-state-constants" "after_specialize_state_constants.mlir"

  if [[ ! -f "${specialize_ir}" ]]; then
    echo "error: missing input for enabled arcilator passes" >&2
    exit 1
  fi

  echo "==> Writing enabled-pass outputs to ${PASS_IR_DIR}"
  "${CIRCT_OPT}" "${specialize_ir}" \
    --arc-dedup-call-arguments \
    -o "${PASS_IR_DIR}/after_dedup_call_arguments.mlir"
  "${CIRCT_OPT}" "${PASS_IR_DIR}/after_dedup_call_arguments.mlir" \
    --arc-remove-unused-defines \
    -o "${PASS_IR_DIR}/after_remove_unused_defines.mlir"
}

require_tool() {
  if [[ ! -x "$1" ]]; then
    echo "error: missing executable: $1" >&2
    echo "hint: export PATH=\"${REPO_ROOT}/build/bin:${REPO_ROOT}/llvm/build/bin:\$PATH\"" >&2
    exit 1
  fi
}

require_tool "${CIRCT_VERILOG}"
require_tool "${ARCILATOR}"
require_tool "${CIRCT_OPT}"

mkdir -p "${BUILD_DIR}"

echo "==> Importing ${DESIGN_SV} to HW MLIR"
"${CIRCT_VERILOG}" --ir-hw --top="${TOP_MODULE}" -o "${HW_MLIR}" "${DESIGN_SV}"

echo "==> Running arcilator"
if [[ -n "${ARCILATOR_IR_DUMP_DIR}" ]]; then
  rm -rf "${ARCILATOR_IR_DUMP_DIR}"
  mkdir -p "${ARCILATOR_IR_DUMP_DIR}"
fi
"${ARCILATOR}" "${HW_MLIR}" \
  --state-file="${STATE_JSON}" \
  -o "${LLVM_IR}" \
  "${ARCILATOR_ARGS[@]}"

if [[ -n "${ARCILATOR_IR_DUMP_DIR}" ]]; then
  write_enabled_pass_outputs
fi

if [[ "${COMPILE_OBJECT:-1}" == "1" ]]; then
  require_tool "${OPT}"
  require_tool "${LLC}"

  echo "==> Compiling LLVM IR to object file"
  "${OPT}" -O3 --strip-debug -S "${LLVM_IR}" | "${LLC}" -O3 --filetype=obj -o "${OBJECT_FILE}"
fi

echo "==> Done"
echo "  HW MLIR:    ${HW_MLIR}"
echo "  State JSON: ${STATE_JSON}"
echo "  LLVM IR:    ${LLVM_IR}"
if [[ "${COMPILE_OBJECT:-1}" == "1" ]]; then
  echo "  Object:     ${OBJECT_FILE}"
fi
if [[ -n "${ARCILATOR_IR_DUMP_DIR}" ]]; then
  echo "  Enabled pass IR:"
  for pass_file in \
    after_dedup_clocks.mlir \
    after_inline_call_arcs.mlir \
    after_specialize_state_constants.mlir \
    after_dedup_call_arguments.mlir \
    after_remove_unused_defines.mlir; do
    echo "    ${PASS_IR_DIR}/${pass_file}"
  done
  echo "  Full pass tree: ${ARCILATOR_IR_DUMP_DIR}"
fi
