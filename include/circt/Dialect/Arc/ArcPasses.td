//===- ArcPasses.td - Arc dialect passes -------------------*- tablegen -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef CIRCT_DIALECT_ARC_ARCPASSES_TD
#define CIRCT_DIALECT_ARC_ARCPASSES_TD

include "mlir/IR/EnumAttr.td"
include "mlir/Pass/PassBase.td"

def AddTaps : Pass<"arc-add-taps", "mlir::ModuleOp"> {
  let summary = "Add taps to ports and wires such that they remain observable";
  let dependentDialects = ["arc::ArcDialect", "seq::SeqDialect"];
  let options = [
    Option<"tapPorts", "ports", "bool", "true", "Make module ports observable">,
    Option<"tapWires", "wires", "bool", "true", "Make wires observable">,
    Option<"tapNamedValues", "named-values", "bool", "false",
           "Make values with `sv.namehint` observable">
  ];
}

def AllocateState : Pass<"arc-allocate-state", "arc::ModelOp"> {
  let summary = "Allocate and layout the global simulation state";
  let dependentDialects = ["arc::ArcDialect"];
  let options = [Option<"insertTraceTaps", "trace-taps", "bool", "false",
                        "Insert TraceTap attributes for signal tracing">,
  ];
}

def ArcCanonicalizer : Pass<"arc-canonicalizer", "mlir::ModuleOp"> {
  let summary = "Simulation centric canonicalizations";
  let dependentDialects = ["hw::HWDialect",
                           "comb::CombDialect",
                           "arc::ArcDialect"];
  let statistics = [
    Statistic<"numArcArgsRemoved", "num-arc-args-removed",
      "Number of arguments removed from DefineOps">,
  ];
}

def DedupClocks : Pass<"arc-dedup-clocks", "mlir::ModuleOp"> {
  let summary = "Deduplicate seq.clock-producing arcs";
  let description = [{
    This pass eliminates redundant seq.clock values produced by arc.call
    operations. It analyses all arc.define ops that return a !seq.clock by
    applying seq.to_clock to one of their i1 arguments and:

    1. Creates (or reuses) a single canonical clock arc with signature
       `(%arg0: i1) -> !seq.clock`.
    2. For each arc that returns !seq.clock together with other results,
       creates a companion "no-clock" arc that returns only the non-clock
       results and keeps the same argument list.
    3. Inside every hw.module, inserts exactly one arc.call to the canonical
       clock arc per unique i1 clock-source value, and replaces all other
       !seq.clock results with that single value.
    4. Removes the original mixed / clock-only arc definitions that are now
       superseded.
  }];
  let dependentDialects = [
    "arc::ArcDialect", "seq::SeqDialect", "hw::HWDialect"
  ];
}

def DedupCallArguments : Pass<"arc-dedup-call-arguments", "mlir::ModuleOp"> {
  let summary = "Specialize arcs for call sites with duplicate arguments";
  let description = [{
    This pass rewrites `arc.state` and `arc.call` operations that pass the same
    SSA value to multiple input positions of a callee. For each distinct
    duplicate-argument pattern, the referenced `arc.define` is cloned with one
    argument per unique input value at that call site. All original block
    arguments in a duplicate group are mapped to the same new block argument,
    and the call site is updated to pass each distinct value once.

    Different duplicate patterns on the same `arc.define` create separate
    specialized definitions. The original definition is kept while any call site
    still uses its full arity.
  }];
  let dependentDialects = ["arc::ArcDialect"];
  let statistics = [
    Statistic<"numSitesFixed", "sites-fixed",
      "Number of arc.state or arc.call operations deduplicated">,
    Statistic<"numArcsCreated", "arcs-created",
      "Number of deduplicated arc definitions created">,
  ];
}

def Dedup : Pass<"arc-dedup", "mlir::ModuleOp"> {
  let summary = "Deduplicate identical arc definitions";
  let description = [{
    This pass deduplicates identical arc definitions. If two arcs differ only by
    constants, the constants are outlined such that the arc can be deduplicated.
  }];
  let dependentDialects = ["arc::ArcDialect"];
  let statistics = [
    Statistic<"dedupPassNumArcsDeduped", "dedupPassNumArcsDeduped",
      "Number of arcs deduped">,
    Statistic<"dedupPassTotalOps", "dedupPassTotalOps",
      "Total number of ops deduped">,
  ];
}

def PrintCostModel : Pass<"arc-print-cost-model", "mlir::ModuleOp"> {
  let summary = "A dummy pass to test analysis passes";
  let dependentDialects = ["arc::ArcDialect"];
  let statistics = [
    Statistic<"moduleCost", "Operation(s)",
      "Number of operations in the module">,
    Statistic<"packingCost", "Pack operations(s)",
      "Number of scalar to vector packking in the module">,
    Statistic<"shufflingCost", "Shuffle operation(s)",
      "Number of shuffles done to set up the VectorizeOps">,
    Statistic<"vectoroizeOpsBodyCost", "VectorizeOps Body Cost",
      "Number of operations inside the body of the VectorizeOps">,
    Statistic<"allVectorizeOpsCost", "All VectorizeOps Cost",
      "Total Cost of all VectorizeOps in the module">
  ];
}

def FindInitialVectors : Pass<"arc-find-initial-vectors", "mlir::ModuleOp"> {
  let summary = "Find initial groups of vectorizable ops";
  let dependentDialects = ["arc::ArcDialect"];
  let statistics = [
    Statistic<"numOfVectorizedOps", "vectorizedOps",
      "Total number of ops that were vectorized">,
    Statistic<"numOfSavedOps", "numOfSavedOps",
      "Total number of ops saved after FindInitialVectors pass">,
    Statistic<"biggestSeedVector", "biggestSeedVector",
      "Size of the biggest seed vector">,
    Statistic<"numOfVectorsCreated", "numOfVectorsCreated",
      "Total number of VectorizeOps the pass inserted">,
  ];
}

def InferMemories : Pass<"arc-infer-memories", "mlir::ModuleOp"> {
  let summary = "Convert `FIRRTL_Memory` instances to dedicated memory ops";
  let dependentDialects = [
    "arc::ArcDialect", "comb::CombDialect", "seq::SeqDialect"
  ];
  let options = [
    Option<"tapPorts", "tap-ports", "bool", "true",
      "Make memory ports observable">,
    Option<"tapMemories", "tap-memories", "bool", "true",
      "Make memory contents observable">,
  ];
}

def InlineCallArcs : Pass<"arc-inline-call-arcs", "mlir::ModuleOp"> {
  let summary = "Inline arc.call combinational logic into consuming arc bodies";
  let description = [{
    This pass inlines `arc.call` operations (combinational arcs) into the arc
    definitions of consuming `arc.state` and `arc.call` operations.

    After `ConvertToArcs`, the hw.module body contains both `arc.call` (pure
    combinational) and `arc.state` (clocked/latency) operations.  When the
    results of an `arc.call` are only used as inputs to other arcs it is
    beneficial to fold the combinational logic directly into those consuming arc
    definitions, removing the intermediate SSA value.

    For each eligible `arc.call @A(u0..uK)` whose non-clock results are consumed
    as inputs by `arc.state @B` or `arc.call @C`, the pass:

      1. Creates a new arc definition `@B_inlined` whose argument list is
         `[kept-B-args...] ++ [A-args...]` and whose body first clones `@A`'s
         body then clones `@B`'s body (with the removed arguments replaced by
         the corresponding `@A` result values).
      2. Updates the call site to pass the kept inputs plus `@A`'s inputs,
         referencing the new arc definition.
      3. Removes the original `arc.call @A` and any arc definitions that are no
         longer referenced.

    Clock-producing arc.calls (wrapping `seq.to_clock`) are not modified.
    The pass accepts intentional code duplication; a subsequent `arc-dedup` run
    can eliminate identical copies.
  }];
  let dependentDialects = ["arc::ArcDialect"];
  let statistics = [
    Statistic<"numCallsInlined", "calls-inlined",
      "Number of arc.call operations whose results were inlined into consumers">,
  ];
}

def SpecializeStateConstants : Pass<"arc-specialize-state-constants",
                                    "mlir::ModuleOp"> {
  let summary = "Specialize arcs for state inputs driven by constants";
  let description = [{
    This pass rewrites `arc.state` operations that pass `hw.constant` values as
    arc inputs. For each distinct constant input pattern, the referenced
    `arc.define` is cloned, the constant arguments are removed from the clone's
    signature, and equivalent `hw.constant` operations are materialized inside
    the cloned arc body. The state operation is then updated to call the
    specialized arc without passing those constants.

    If a single `arc.define` is used by multiple states with different constant
    values, the pass creates one specialized `arc.define` per distinct constant
    pattern and leaves the original definition available for non-specialized
    users.
  }];
  let dependentDialects = ["arc::ArcDialect", "hw::HWDialect"];
  let statistics = [
    Statistic<"numSpecializedStates", "states-specialized",
      "Number of arc.state operations specialized">,
    Statistic<"numSpecializedArcs", "arcs-created",
      "Number of specialized arc definitions created">,
  ];
}

def InlineArcs : Pass<"arc-inline" , "mlir::ModuleOp"> {
  let summary = "Inline very small arcs";
  let statistics = [
    Statistic<"numInlinedArcs", "inlined-arcs", "Arcs inlined at a use site">,
    Statistic<"numRemovedArcs", "removed-arcs",
      "Arcs removed after full inlining">,
    Statistic<"numTrivialArcs", "trivial-arcs", "Arcs with very few ops">,
    Statistic<"numSingleUseArcs", "single-use-arcs", "Arcs with a single use">,
  ];
  let options = [
    Option<"intoArcsOnly", "into-arcs-only", "bool", "false",
           "Call operations to inline">,
    Option<"maxNonTrivialOpsInBody", "max-body-ops", "unsigned", "3",
           "Max number of non-trivial ops in the region to be inlined">,
  ];
}

def InferStateProperties : Pass<"arc-infer-state-properties",
                                "mlir::ModuleOp"> {
  let summary = "Add resets and enables explicitly to the state operations";
  let dependentDialects = ["circt::hw::HWDialect", "circt::comb::CombDialect"];
  let options = [
    Option<"detectEnables", "enables", "bool", "true", "Infer enable signals">,
    Option<"detectResets", "resets", "bool", "true", "Infer reset signals">,
  ];
  let statistics = [
    Statistic<"addedEnables", "added-enables",
      "Enables added explicitly to a StateOp">,
    Statistic<"addedResets", "added-resets",
      "Resets added explicitly to a StateOp">,
    Statistic<"missedEnables", "missed-enables",
      "Detected enables that could not be added explicitly to a StateOp">,
    Statistic<"missedResets", "missed-resets",
      "Detected resets that could not be added explicitly to a StateOp">,
  ];
}

def InsertRuntime : Pass<"arc-insert-runtime", "mlir::ModuleOp"> {
  let summary = "Insert structs and function calls for the ArcRuntime library";
  let dependentDialects = ["mlir::LLVM::LLVMDialect",  "mlir::scf::SCFDialect"];
  let options = [
    Option<"extraArgs", "extra-args", "std::string", "",
     "Extra arguments passed to the runtime when creating simulation instances">,
    Option<"traceFileName", "trace-file", "std::string", "",
     "Output file name for signal trace">
  ];
}

def IsolateClocks : Pass<"arc-isolate-clocks", "mlir::ModuleOp"> {
  let summary = "Group clocked operations into clock domains";
  let dependentDialects = ["arc::ArcDialect"];
}

def LatencyRetiming : Pass<"arc-latency-retiming", "mlir::ModuleOp"> {
  let summary = "Push latencies through the design";
  let dependentDialects = ["arc::ArcDialect"];

  let statistics = [
    Statistic<"numOpsRemoved", "num-ops-removed",
      "Number of zero-latency passthrough states removed">,
    Statistic<"latencyUnitsSaved", "latency-units-saved",
      "Number of latency units saved by merging them in a successor state">
  ];
}

def LowerArcsToFuncs : Pass<"arc-lower-arcs-to-funcs", "mlir::ModuleOp"> {
  let summary = "Lower arc definitions into functions";
  let dependentDialects = ["mlir::func::FuncDialect", "mlir::LLVM::LLVMDialect"];
}

def LowerClocksToFuncs : Pass<"arc-lower-clocks-to-funcs", "mlir::ModuleOp"> {
  let summary = "Lower clock trees into functions";
  let dependentDialects = ["mlir::func::FuncDialect", "mlir::scf::SCFDialect"];
}

def LowerLUT : Pass<"arc-lower-lut", "arc::DefineOp"> {
  let summary = "Lowers arc.lut into a comb and hw only representation.";
  let dependentDialects = ["hw::HWDialect", "comb::CombDialect"];
}

def LowerStatePass : Pass<"arc-lower-state", "mlir::ModuleOp"> {
  let summary = "Split state into read and write ops grouped by clock tree";
  let dependentDialects = [
    "arc::ArcDialect",
    "comb::CombDialect",
    "mlir::LLVM::LLVMDialect",
    "mlir::func::FuncDialect",
    "mlir::scf::SCFDialect",
    "seq::SeqDialect",
  ];
}

def LowerVectorizationsMode : I32EnumAttr<
  "LowerVectorizationsModeEnum", "Lowering Mode", [
    I32EnumAttrCase<"Boundary", 0, "boundary">,
    I32EnumAttrCase<"Body", 1, "body">,
    I32EnumAttrCase<"InlineBody", 2, "inline-body">,
    I32EnumAttrCase<"Full", 3>,
  ]> {
  let cppNamespace = "circt::arc";
}

def LowerVectorizations : Pass<"arc-lower-vectorizations", "mlir::ModuleOp"> {
  let summary = "lower `arc.vectorize` operations";
  let description = [{
    This pass lowers `arc.vectorize` operations. By default, the operation will
    be fully lowered (i.e., the op disappears in the IR). Alternatively, it can
    be partially lowered.

    The "mode" pass option allows to only lower the boundary, only the body, or
    only inline the body given that both the boundary and the body are already
    lowered.

    The pass supports vectorization within scalar registers and SIMD
    vectorization and prioritizes vectorization by packing the vector elements
    into a scalar value if it can fit into 64 bits.

    Example:
    ```mlir
    hw.module @example(%in0: i8, %in1: i8, %in2: i8) -> (out0: i8, out1: i8) {
      %0:2 = arc.vectorize (%in0, %in1), (%in2, %in2) :
        (i8, i8, i8, i8) -> (i8, i8) {
      ^bb0(%arg0: i8, %arg1: i8):
        %1 = comb.and %arg0, %arg1 : i8
        arc.vectorize.return %1 : i8
      }
      hw.output %0#0, %0#1 : i8, i8
    }
    ```
    This piece of IR is lowered to the following fully vectorized IR:
    ```mlir
    hw.module @example(%in0: i8, %in1: i8, %in2: i8) -> (out0: i8, out1: i8) {
      %0 = comb.concat %in0, %in1 : i8, i8
      %1 = comb.concat %in2, %in2 : i8, i8
      %2 = comb.and %0, %1 : i16
      %3 = comb.extract %2 from 0 : (i16) -> i8
      %4 = comb.extract %2 from 8 : (i16) -> i8
      hw.output %3, %4 : i8, i8
    }
    ```
  }];

  let options = [
    Option<"mode", "mode", "circt::arc::LowerVectorizationsModeEnum",
           /*default=*/"circt::arc::LowerVectorizationsModeEnum::Full",
           "Select what should be lowered.",
           [{::llvm::cl::values(
             clEnumValN(circt::arc::LowerVectorizationsModeEnum::Boundary,
             "boundary", "Lower boundary only."),
             clEnumValN(circt::arc::LowerVectorizationsModeEnum::Body,
             "body", "Lower body only."),
             clEnumValN(circt::arc::LowerVectorizationsModeEnum::InlineBody,
             "inline-body", "Inline already vectorized ops only."),
             clEnumValN(circt::arc::LowerVectorizationsModeEnum::Full,
             "full", "Perform the complete lowering.")
           )}]>,
  ];

  let dependentDialects = [
    "arc::ArcDialect", "circt::comb::CombDialect", "mlir::arith::ArithDialect",
    "mlir::vector::VectorDialect",
  ];
}

def LowerVerifSimulationsPass : Pass<"arc-lower-verif-simulations",
                                     "mlir::ModuleOp"> {
  let summary = "Lower verif.simulation ops to main functions";
  let dependentDialects = [
    "arc::ArcDialect",
    "hw::HWDialect",
    "mlir::arith::ArithDialect",
    "mlir::cf::ControlFlowDialect",
    "mlir::func::FuncDialect",
    "mlir::scf::SCFDialect",
    "seq::SeqDialect",
  ];
}

def MakeTables : Pass<"arc-make-tables", "mlir::ModuleOp"> {
  let summary = "Transform appropriate arc logic into lookup tables";
  let dependentDialects = ["arc::ArcDialect"];
}

def MergeIfsPass : Pass<"arc-merge-ifs"> {
  let summary = "Merge control flow structures";
  let description = [{
    This pass optimizes control flow in a few ways. It moves operations closer
    to their earliest user, if possible sinking them into blocks if all uses are
    nested in the same block. It merges adjacent `scf.if` operations with the
    same condition. And it moves operations in between two `scf.if` operations
    ahead of the first if op to allow them to be merged. The pass runs on any
    SSACFG regions nested under the operation it is applied to.

    Note that this pass assumes that `!arc.state` and `!arc.memory` values can
    never alias. That is, different values are assumed to never point to the
    same storage location in simulation memory.
  }];
  let statistics = [
    Statistic<"numOpsSunk", "sunk", "Ops sunk into blocks">,
    Statistic<"numOpsMovedToUser", "moved-to-user", "Ops moved to first user">,
    Statistic<"numIfsMerged", "ifs-merged", "Adjacent scf.if ops merged">,
    Statistic<"numOpsMovedFromBetweenIfs", "moved-from-between-ifs",
      "Ops moved from between ifs to enable merging">,
    Statistic<"numIterations", "iterations",
      "Number of iterations until no more ops were sunk/merged">,
  ];
}

def MergeTaps : Pass<"arc-merge-taps", "hw::HWModuleOp"> {
  let summary = "Merge TapOps observing the same value in the same Block.";
  let dependentDialects = ["arc::ArcDialect"];
}

def MuxToControlFlow : Pass<"arc-mux-to-control-flow", "mlir::ModuleOp"> {
  let summary = "Convert muxes with large independent fan-ins to if-statements";
  let dependentDialects = ["mlir::scf::SCFDialect"];
}

def SimplifyVariadicOps : Pass<"arc-simplify-variadic-ops", "mlir::ModuleOp"> {
  let summary = "Convert variadic ops into distributed binary ops";
  let statistics = [
    Statistic<"numOpsSkippedMultipleBlocks", "skipped-multiple-blocks",
      "Ops skipped due to operands in different blocks">,
    Statistic<"numOpsSimplified", "simplified",
      "Ops simplified into binary ops">,
    Statistic<"numOpsCreated", "created",
      "Ops created as part of simplification">,
    Statistic<"numOpsReordered", "reordered",
      "Ops where simplification reordered operands">,
  ];
}

def SplitFuncs : Pass<"arc-split-funcs", "mlir::ModuleOp"> {
  let summary = "Split large funcs into multiple smaller funcs";
  let dependentDialects = ["mlir::func::FuncDialect"];
  let options = [
    Option<"splitBound", "split-bound", "unsigned", "20000",
      "Size threshold (in ops) above which to split funcs">
  ];
  let statistics = [
    Statistic<"numFuncsCreated", "funcs-created",
      "Number of new functions created">,
  ];
}

def SplitLoops : Pass<"arc-split-loops", "mlir::ModuleOp"> {
  let summary = "Split arcs to break zero latency loops";
  let dependentDialects = ["arc::ArcDialect"];
  let statistics = [
    Statistic<"numArcsCreated", "created", "Arcs created during the splitting">,
    Statistic<"numArcsRemoved", "removed", "Arcs removed during the splitting">,
  ];
}

def StripSV : Pass<"arc-strip-sv", "mlir::ModuleOp"> {
  let summary = "Remove SV wire, reg, and assigns";
  let dependentDialects = ["arc::ArcDialect", "comb::CombDialect",
                           "hw::HWDialect", "seq::SeqDialect"];
  let options = [
    Option<"asyncResetsAsSync", "async-resets-as-sync", "bool", "false",
      "Treat asynchronous resets as synchronous.">
  ];
}

def ResolveXMRRef : Pass<"arc-resolve-xmr", "mlir::ModuleOp"> {
  let summary = "Resolve sv.xmr.ref into direct signal references";
  let description = [{
    This pass traverses hw.hierpath metadata to replace sv.xmr.ref operations
    with direct SSA value references, preserving observability before flattening.
  }];

  let options = [
    Option<"lowerBlackBoxInternalToZero", "lower-blackbox-internal-to-zero",
           "bool", "false",
           "Lower unresolved references to internal blackbox symbols to constant zero.">
  ];

  let dependentDialects = [
    "circt::sv::SVDialect",
    "circt::hw::HWDialect"
  ];
}

#endif // CIRCT_DIALECT_ARC_ARCPASSES_TD
