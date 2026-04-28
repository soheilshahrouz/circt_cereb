// RUN: circt-opt %s --arc-inline-call-arcs | FileCheck %s

arc.define @Pred(%arg0: i1, %arg1: i1) -> i1 {
  %0 = comb.xor %arg0, %arg1 : i1
  arc.output %0 : i1
}

arc.define @Comb(%arg0: i1, %arg1: i1) -> i1 {
  %0 = comb.and %arg0, %arg1 : i1
  arc.output %0 : i1
}

arc.define @Use(%arg0: i1, %arg1: i1) -> i1 {
  %0 = comb.or %arg0, %arg1 : i1
  arc.output %0 : i1
}

// CHECK-LABEL: hw.module @M
// CHECK-NOT: arc.call
// CHECK: arc.state @Use_inl
// CHECK-NOT: arc.call
hw.module @M(in %clk: !seq.clock, in %in: i1) {
  %state = arc.state @Use(%pred, %comb) clock %clk latency 1 : (i1, i1) -> i1
  %pred = arc.call @Pred(%state, %in) : (i1, i1) -> i1
  %comb = arc.call @Comb(%pred, %in) : (i1, i1) -> i1
}
