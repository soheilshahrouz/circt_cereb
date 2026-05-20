// RUN: circt-opt %s --arc-dedup-call-arguments | FileCheck %s

// CHECK-LABEL: arc.define @Dup_dedup(%arg0: i1, %arg1: i4) -> i4
// CHECK:         comb.mux %arg0, %arg1, %arg1 : i4
// CHECK:         comb.mux %arg0
// CHECK:         arc.output

// CHECK-LABEL: arc.define @Dup(%arg0: i1, %arg1: i4, %arg2: i1) -> i4
arc.define @Dup(%arg0: i1, %arg1: i4, %arg2: i1) -> i4 {
  %0 = comb.mux %arg0, %arg1, %arg1 : i4
  %1 = comb.mux %arg2, %0, %arg1 : i4
  arc.output %1 : i4
}

// CHECK-LABEL: arc.define @UseCall
// CHECK:         arc.call @Dup_dedup(%arg0, %arg1) : (i1, i4) -> i4
arc.define @UseCall(%arg0: i1, %arg1: i4) -> i4 {
  %0 = arc.call @Dup(%arg0, %arg1, %arg0) : (i1, i4, i1) -> i4
  arc.output %0 : i4
}

// CHECK-LABEL: arc.define @Pair_dedup(%arg0: i1, %arg1: i4) -> i4
// CHECK:         arc.output %arg1 : i4
arc.define @Pair(%arg0: i1, %arg1: i4, %arg2: i1, %arg3: i4) -> i4 {
  arc.output %arg3 : i4
}

// CHECK-LABEL: hw.module @M
hw.module @M(in %clk: !seq.clock, in %en: i1, in %other: i1, in %x: i4,
             out out0: i4, out out1: i4, out out2: i4, out out3: i4) {
  // CHECK: %[[S0:.*]] = arc.state @Dup_dedup(%en, %x) clock %clk latency 1 : (i1, i4) -> i4
  %s0 = arc.state @Dup(%en, %x, %en) clock %clk latency 1 : (i1, i4, i1) -> i4

  // CHECK: %[[C0:.*]] = arc.call @Dup_dedup(%en, %x) : (i1, i4) -> i4
  %c0 = arc.call @Dup(%en, %x, %en) : (i1, i4, i1) -> i4

  // CHECK: %[[S1:.*]] = arc.state @Dup(%en, %x, %other) clock %clk latency 1 : (i1, i4, i1) -> i4
  %s1 = arc.state @Dup(%en, %x, %other) clock %clk latency 1 : (i1, i4, i1) -> i4

  // CHECK: %[[S2:.*]] = arc.state @Pair_dedup(%en, %x) clock %clk latency 1 : (i1, i4) -> i4
  %s2 = arc.state @Pair(%en, %x, %en, %x) clock %clk latency 1 : (i1, i4, i1, i4) -> i4

  // CHECK: hw.output %[[S0]], %[[C0]], %[[S1]], %[[S2]] : i4, i4, i4, i4
  hw.output %s0, %c0, %s1, %s2 : i4, i4, i4, i4
}
