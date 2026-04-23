//===- DedupClocks.cpp - Deduplicate seq.clock-producing arcs -------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This pass finds arc.define ops that produce !seq.clock values, ensures each
// unique clock source is covered by exactly one canonical arc.call, and strips
// the !seq.clock result from mixed arcs (those that return both a clock and
// non-clock results).
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/Arc/ArcOps.h"
#include "circt/Dialect/Arc/ArcPasses.h"
#include "circt/Dialect/HW/HWOps.h"
#include "circt/Dialect/Seq/SeqOps.h"
#include "circt/Dialect/Seq/SeqTypes.h"
#include "circt/Support/Namespace.h"
#include "mlir/IR/IRMapping.h"
#include "mlir/IR/ImplicitLocOpBuilder.h"
#include "mlir/Pass/Pass.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/SetVector.h"
#include "llvm/Support/Debug.h"

#define DEBUG_TYPE "arc-dedup-clocks"

namespace circt {
namespace arc {
#define GEN_PASS_DEF_DEDUPCLOCKS
#include "circt/Dialect/Arc/ArcPasses.h.inc"
} // namespace arc
} // namespace circt

using namespace circt;
using namespace arc;
using namespace hw;

//===----------------------------------------------------------------------===//
// Helpers
//===----------------------------------------------------------------------===//

namespace {

/// Describes how a clock-producing arc.define generates its !seq.clock result.
struct ClockArcInfo {
  /// Index of the !seq.clock result in the arc's function type.
  unsigned clockResultIdx;
  /// Index of the block argument that is the i1 input to seq.to_clock.
  unsigned clockArgIdx;
};

} // namespace

//===----------------------------------------------------------------------===//
// Pass Implementation
//===----------------------------------------------------------------------===//

namespace {
struct DedupClocksPass
    : public arc::impl::DedupClocksBase<DedupClocksPass> {
  void runOnOperation() override;

private:
  /// Try to identify the ClockArcInfo for a DefineOp.  Returns failure if the
  /// op does not produce a !seq.clock or if the clock cannot be traced to a
  /// direct seq.to_clock of a single block argument.
  LogicalResult analyzeDefine(arc::DefineOp defineOp, ClockArcInfo &info);

  /// Return an existing clock-only arc (i1 -> !seq.clock) if one exists in the
  /// module, or create a fresh one named "__arc_dedup_clock__".
  arc::DefineOp getOrCreateCanonicalClockArc(mlir::ModuleOp moduleOp,
                                             OpBuilder &builder,
                                             Namespace &ns);

  /// Clone defineOp into a new arc that omits the !seq.clock result.  Returns
  /// nullptr when defineOp is already clock-only (no non-clock results left).
  arc::DefineOp createNoClockArc(arc::DefineOp defineOp,
                                  const ClockArcInfo &info,
                                  StringRef newName, OpBuilder &builder);

  /// Update a single hw.module: insert canonical clock calls and rewrite all
  /// clock-producing arc.calls.
  void processHwModule(
      hw::HWModuleOp hwModule,
      const DenseMap<StringAttr, ClockArcInfo> &clockArcInfos,
      arc::DefineOp canonicalClockArc,
      const DenseMap<StringAttr, arc::DefineOp> &noClockArcs);
};
} // namespace

//===----------------------------------------------------------------------===//
// analyzeDefine
//===----------------------------------------------------------------------===//

LogicalResult DedupClocksPass::analyzeDefine(arc::DefineOp defineOp,
                                              ClockArcInfo &info) {
  auto seqClockType = seq::ClockType::get(&getContext());
  auto funcType = defineOp.getFunctionType();

  // Locate the first !seq.clock result.
  int clockResultIdx = -1;
  for (auto [idx, type] : llvm::enumerate(funcType.getResults())) {
    if (type == seqClockType) {
      clockResultIdx = static_cast<int>(idx);
      break;
    }
  }
  if (clockResultIdx < 0)
    return failure();

  // The clock value in the output must trace back to seq.to_clock(%blockArg).
  auto &block = defineOp.getBodyBlock();
  auto *terminator = block.getTerminator();
  Value clockVal = terminator->getOperand(clockResultIdx);

  auto toClockOp = clockVal.getDefiningOp<seq::ToClockOp>();
  if (!toClockOp)
    return failure();

  auto blockArg = dyn_cast<BlockArgument>(toClockOp.getInput());
  if (!blockArg || blockArg.getOwner() != &block)
    return failure();

  info.clockResultIdx = static_cast<unsigned>(clockResultIdx);
  info.clockArgIdx = blockArg.getArgNumber();
  return success();
}

//===----------------------------------------------------------------------===//
// getOrCreateCanonicalClockArc
//===----------------------------------------------------------------------===//

arc::DefineOp
DedupClocksPass::getOrCreateCanonicalClockArc(mlir::ModuleOp moduleOp,
                                               OpBuilder &builder,
                                               Namespace &ns) {
  auto *ctx = &getContext();
  auto seqClockType = seq::ClockType::get(ctx);
  auto i1Type = IntegerType::get(ctx, 1);

  // Reuse an existing arc with signature (i1) -> !seq.clock whose body is a
  // direct seq.to_clock of the single argument.
  for (auto defineOp : moduleOp.getOps<arc::DefineOp>()) {
    auto ft = defineOp.getFunctionType();
    if (ft.getNumInputs() != 1 || ft.getNumResults() != 1)
      continue;
    if (ft.getInput(0) != i1Type || ft.getResult(0) != seqClockType)
      continue;
    ClockArcInfo info;
    if (succeeded(analyzeDefine(defineOp, info)))
      return defineOp;
  }

  // Nothing found – create a fresh canonical clock arc at the top of the
  // module so all hw.modules can reach it.
  builder.setInsertionPointToStart(moduleOp.getBody());
  auto loc = moduleOp.getLoc();
  auto ft = FunctionType::get(ctx, {i1Type}, {seqClockType});
  std::string name = ns.newName("__arc_dedup_clock__").str();
  auto clockArc = arc::DefineOp::create(builder, loc, name, ft);

  auto &bodyBlock = clockArc.getBody().emplaceBlock();
  bodyBlock.addArgument(i1Type, loc);
  OpBuilder bb = OpBuilder::atBlockEnd(&bodyBlock);
  Value clkOut = seq::ToClockOp::create(bb, loc, bodyBlock.getArgument(0));
  arc::OutputOp::create(bb, loc, ValueRange{clkOut});

  return clockArc;
}

//===----------------------------------------------------------------------===//
// createNoClockArc
//===----------------------------------------------------------------------===//

arc::DefineOp DedupClocksPass::createNoClockArc(arc::DefineOp defineOp,
                                                  const ClockArcInfo &info,
                                                  StringRef newName,
                                                  OpBuilder &builder) {
  auto *ctx = &getContext();
  auto funcType = defineOp.getFunctionType();

  // Build result types without the clock.
  SmallVector<Type> newResults;
  for (auto [idx, type] : llvm::enumerate(funcType.getResults()))
    if (idx != info.clockResultIdx)
      newResults.push_back(type);

  if (newResults.empty())
    return nullptr; // clock-only arc, nothing remains

  auto newFuncType = FunctionType::get(ctx, funcType.getInputs(), newResults);

  builder.setInsertionPoint(defineOp);
  auto loc = defineOp.getLoc();
  auto noClockArc = arc::DefineOp::create(builder, loc, newName, newFuncType);

  // Clone the body, remapping arguments.
  auto *srcBlock = &defineOp.getBodyBlock();
  auto &dstBodyBlock = noClockArc.getBody().emplaceBlock();
  dstBodyBlock.addArguments(funcType.getInputs(),
                             SmallVector<Location>(funcType.getNumInputs(), loc));

  IRMapping mapping;
  for (auto [srcArg, dstArg] :
       llvm::zip(srcBlock->getArguments(), dstBodyBlock.getArguments()))
    mapping.map(srcArg, dstArg);

  OpBuilder bb = OpBuilder::atBlockEnd(&dstBodyBlock);
  for (auto &op : srcBlock->without_terminator())
    bb.clone(op, mapping);

  // Rebuild arc.output omitting the clock result.
  SmallVector<Value> newOutputVals;
  for (auto [idx, operand] :
       llvm::enumerate(srcBlock->getTerminator()->getOperands()))
    if (idx != info.clockResultIdx)
      newOutputVals.push_back(mapping.lookupOrDefault(operand));

  arc::OutputOp::create(bb, loc, newOutputVals);
  return noClockArc;
}

//===----------------------------------------------------------------------===//
// processHwModule
//===----------------------------------------------------------------------===//

void DedupClocksPass::processHwModule(
    hw::HWModuleOp hwModule,
    const DenseMap<StringAttr, ClockArcInfo> &clockArcInfos,
    arc::DefineOp canonicalClockArc,
    const DenseMap<StringAttr, arc::DefineOp> &noClockArcs) {

  auto seqClockType = seq::ClockType::get(&getContext());
  StringAttr canonicalName = canonicalClockArc.getNameAttr();

  // Collect all arc.call ops inside this module that produce a !seq.clock.
  SmallVector<arc::CallOp> clockCalls;
  hwModule.walk([&](arc::CallOp callOp) {
    if (clockArcInfos.count(callOp.getArcAttr().getAttr()))
      clockCalls.push_back(callOp);
  });

  if (clockCalls.empty())
    return;

  // Find the set of unique i1 SSA values used as clock sources.
  llvm::SetVector<Value> uniqueClockInputs;
  for (auto callOp : clockCalls) {
    StringAttr arcName = callOp.getArcAttr().getAttr();
    unsigned argIdx = clockArcInfos.find(arcName)->second.clockArgIdx;
    uniqueClockInputs.insert(callOp.getOperand(argIdx));
  }

  // For each unique clock input, insert ONE call to the canonical clock arc at
  // the very beginning of the module body.  The inputs are always module ports
  // (block arguments), so they dominate all operations in the body.
  DenseMap<Value, Value> canonicalClockValues; // i1 value -> !seq.clock value
  {
    Block *body = hwModule.getBodyBlock();
    OpBuilder bodyBuilder(body, body->begin());
    Location loc = hwModule.getLoc();
    for (Value clockInput : uniqueClockInputs) {
      auto call = arc::CallOp::create(
          bodyBuilder, loc, TypeRange{seqClockType},
          FlatSymbolRefAttr::get(canonicalName), ValueRange{clockInput});
      canonicalClockValues[clockInput] = call.getResult(0);
    }
  }

  // Replace each clock-producing arc.call with a no-clock version (or erase
  // it for clock-only arcs) and redirect !seq.clock result uses.
  for (auto callOp : clockCalls) {
    StringAttr arcName = callOp.getArcAttr().getAttr();
    const ClockArcInfo &info = clockArcInfos.find(arcName)->second;
    Value clockInput = callOp.getOperand(info.clockArgIdx);
    Value canonicalClock = canonicalClockValues.at(clockInput);

    // Replace all uses of the clock result first.
    callOp.getResult(info.clockResultIdx).replaceAllUsesWith(canonicalClock);

    // Look up the no-clock replacement arc.
    auto noClockIt = noClockArcs.find(arcName);
    if (noClockIt == noClockArcs.end() || !noClockIt->second) {
      // Clock-only arc or not eligible for splitting – just erase.
      callOp.erase();
      continue;
    }

    arc::DefineOp noClockArc = noClockIt->second;

    // Build new result type list (same order, clock result removed).
    SmallVector<Type> newResultTypes;
    for (auto [idx, type] : llvm::enumerate(callOp.getResultTypes()))
      if (idx != info.clockResultIdx)
        newResultTypes.push_back(type);

    // Create the replacement call (same operands, updated callee + results).
    OpBuilder insertBuilder(callOp);
    auto newCall = arc::CallOp::create(
        insertBuilder, callOp.getLoc(), newResultTypes,
        FlatSymbolRefAttr::get(noClockArc.getNameAttr()),
        callOp.getOperands());

    // Remap surviving results.
    unsigned newIdx = 0;
    for (auto [idx, result] : llvm::enumerate(callOp.getResults())) {
      if (idx == info.clockResultIdx)
        continue;
      result.replaceAllUsesWith(newCall.getResult(newIdx++));
    }

    callOp.erase();
  }
}

//===----------------------------------------------------------------------===//
// runOnOperation
//===----------------------------------------------------------------------===//

void DedupClocksPass::runOnOperation() {
  mlir::ModuleOp moduleOp = getOperation();
  MLIRContext *ctx = &getContext();

  // Build a namespace from all existing symbols to avoid name collisions when
  // generating new arc names.
  Namespace ns;
  ns.add(moduleOp);

  OpBuilder builder(ctx);

  // -----------------------------------------------------------------------
  // Step 1: Find all arc.define ops that produce !seq.clock and are eligible.
  // -----------------------------------------------------------------------
  DenseMap<StringAttr, ClockArcInfo> clockArcInfos;
  SmallVector<arc::DefineOp> clockDefines;

  for (auto defineOp : moduleOp.getOps<arc::DefineOp>()) {
    ClockArcInfo info;
    if (failed(analyzeDefine(defineOp, info)))
      continue;
    clockArcInfos[defineOp.getNameAttr()] = info;
    clockDefines.push_back(defineOp);
  }

  if (clockArcInfos.empty())
    return;

  // -----------------------------------------------------------------------
  // Step 2: Obtain the canonical clock arc (reuse or create).
  // -----------------------------------------------------------------------
  arc::DefineOp canonicalClockArc =
      getOrCreateCanonicalClockArc(moduleOp, builder, ns);
  StringAttr canonicalName = canonicalClockArc.getNameAttr();

  // -----------------------------------------------------------------------
  // Step 3: For mixed arcs, create companion "no-clock" arc.define ops.
  // -----------------------------------------------------------------------
  DenseMap<StringAttr, arc::DefineOp> noClockArcs;

  for (auto defineOp : clockDefines) {
    StringAttr name = defineOp.getNameAttr();

    // The canonical clock arc is handled as a clock-only arc below.
    bool isMixed = defineOp.getFunctionType().getNumResults() > 1;
    if (!isMixed || name == canonicalName) {
      noClockArcs[name] = nullptr; // clock-only, no residual arc needed
      continue;
    }

    std::string noClockName =
        ns.newName((defineOp.getSymName() + "_no_clock").str()).str();
    arc::DefineOp noClockArc =
        createNoClockArc(defineOp, clockArcInfos.at(name), noClockName, builder);
    noClockArcs[name] = noClockArc;
    if (noClockArc)
      ns.newName(noClockArc.getSymName()); // reserve the name
  }

  // -----------------------------------------------------------------------
  // Step 4: Rewrite every hw.module.
  // -----------------------------------------------------------------------
  for (auto hwModule : moduleOp.getOps<hw::HWModuleOp>())
    processHwModule(hwModule, clockArcInfos, canonicalClockArc, noClockArcs);

  // -----------------------------------------------------------------------
  // Step 5: Remove the original clock-producing arc.define ops (all callers
  //         have been updated in step 4).  Keep the canonical clock arc.
  // -----------------------------------------------------------------------
  for (auto defineOp : clockDefines) {
    if (defineOp.getNameAttr() == canonicalName)
      continue;
    defineOp.erase();
  }
}
