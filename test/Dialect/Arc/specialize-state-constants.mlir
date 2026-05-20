// RUN: circt-opt %s --arc-specialize-state-constants | FileCheck %s

// CHECK-LABEL: arc.define @Add_const(%arg0: i4, %arg1: i4) -> i4
// CHECK:         %c2_i4 = hw.constant 2 : i4
// CHECK:         comb.add %arg0, %c2_i4 : i4
// CHECK:         comb.add {{.*}}, %arg1 : i4
arc.define @Add(%arg0: i4, %arg1: i4, %arg2: i4) -> i4 {
  %0 = comb.add %arg0, %arg1 : i4
  %1 = comb.add %0, %arg2 : i4
  arc.output %1 : i4
}

// CHECK-LABEL: arc.define @Add_const_0(%arg0: i4, %arg1: i4) -> i4
// CHECK:         %c3_i4 = hw.constant 3 : i4
// CHECK:         comb.add %arg0, %c3_i4 : i4
// CHECK:         comb.add {{.*}}, %arg1 : i4

// CHECK-LABEL: arc.define @Add(%arg0: i4, %arg1: i4, %arg2: i4) -> i4
// CHECK:         comb.add %arg0, %arg1 : i4
// CHECK:         comb.add {{.*}}, %arg2 : i4

// CHECK-LABEL: hw.module @M
hw.module @M(in %clk: !seq.clock, in %x: i4, in %y: i4, in %z: i4,
             out out0: i4, out out1: i4, out out2: i4, out out3: i4) {
  // CHECK-NOT: hw.constant
  // CHECK: %[[S0:.*]] = arc.state @Add_const(%x, %y) clock %clk latency 1 : (i4, i4) -> i4
  // CHECK: %[[S1:.*]] = arc.state @Add_const_0(%x, %y) clock %clk latency 1 : (i4, i4) -> i4
  // CHECK: %[[S2:.*]] = arc.state @Add_const(%y, %x) clock %clk latency 1 : (i4, i4) -> i4
  // CHECK: %[[S3:.*]] = arc.state @Add(%x, %y, %z) clock %clk latency 1 : (i4, i4, i4) -> i4
  // CHECK: hw.output %[[S0]], %[[S1]], %[[S2]], %[[S3]] : i4, i4, i4, i4
  %c2_i4 = hw.constant 2 : i4
  %c3_i4 = hw.constant 3 : i4
  %s0 = arc.state @Add(%x, %c2_i4, %y) clock %clk latency 1 : (i4, i4, i4) -> i4
  %s1 = arc.state @Add(%x, %c3_i4, %y) clock %clk latency 1 : (i4, i4, i4) -> i4
  %s2 = arc.state @Add(%y, %c2_i4, %x) clock %clk latency 1 : (i4, i4, i4) -> i4
  %s3 = arc.state @Add(%x, %y, %z) clock %clk latency 1 : (i4, i4, i4) -> i4
  hw.output %s0, %s1, %s2, %s3 : i4, i4, i4, i4
}
