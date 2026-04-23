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
// non-clock results).  When the clock argument of a mixed arc is used solely
// to produce the clock output it is also removed from the no-clock arc's
// signature.
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
// Data structures
//===----------------------------------------------------------------------===//

namespace {

/// How a clock-producing arc.define generates its !seq.clock result.
struct ClockArcInfo {
  unsigned clockResultIdx; ///< Index of the !seq.clock result.
  unsigned clockArgIdx;    ///< Index of the i1 argument fed to seq.to_clock.
};

/// Companion "no-clock" arc together with the mapping from each original
/// operand position to the corresponding position in the new call (-1 when
/// the operand has been dropped because it was only used to produce the clock).
struct NoClockArcInfo {
  /// nullptr when the original arc was clock-only and has no remaining results.
  arc::DefineOp defineOp;
  /// argMapping[i] = new operand index for original operand i, or -1 if dropped.
  SmallVector<int> argMapping;
};

} // namespace

//===----------------------------------------------------------------------===//
// Pass
//===----------------------------------------------------------------------===//

namespace {
struct DedupClocksPass
    : public arc::impl::DedupClocksBase<DedupClocksPass> {
  void runOnOperation() override;

private:
  LogicalResult analyzeDefine(arc::DefineOp defineOp, ClockArcInfo &info);

  arc::DefineOp getOrCreateCanonicalClockArc(mlir::ModuleOp moduleOp,
                                             OpBuilder &builder, Namespace &ns);

  /// Build the no-clock companion arc.  Returns a populated NoClockArcInfo;
  /// defineOp is nullptr when nothing remains after removing the clock result.
  NoClockArcInfo createNoClockArc(arc::DefineOp defineOp,
                                   const ClockArcInfo &info, StringRef newName,
                                   OpBuilder &builder);

  void processHwModule(
      hw::HWModuleOp hwModule,
      const DenseMap<StringAttr, ClockArcInfo> &clockArcInfos,
      arc::DefineOp canonicalClockArc,
      const DenseMap<StringAttr, NoClockArcInfo> &noClockArcs);
};
} // namespace

//===----------------------------------------------------------------------===//
// analyzeDefine
//===----------------------------------------------------------------------===//

LogicalResult DedupClocksPass::analyzeDefine(arc::DefineOp defineOp,
                                              ClockArcInfo &info) {
  auto seqClockType = seq::ClockType::get(&getContext());
  auto funcType = defineOp.getFunctionType();

  int clockResultIdx = -1;
  for (auto [idx, type] : llvm::enumerate(funcType.getResults())) {
    if (type == seqClockType) {
      clockResultIdx = static_cast<int>(idx);
      break;
    }
  }
  if (clockResultIdx < 0)
    return failure();

  auto &block = defineOp.getBodyBlock();
  Value clockVal = block.getTerminator()->getOperand(clockResultIdx);

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

NoClockArcInfo DedupClocksPass::createNoClockArc(arc::DefineOp defineOp,
                                                   const ClockArcInfo &info,
                                                   StringRef newName,
                                                   OpBuilder &builder) {
  auto *ctx = &getContext();
  auto funcType = defineOp.getFunctionType();
  auto loc = defineOp.getLoc();

  auto *srcBlock = &defineOp.getBodyBlock();

  // Identify the seq.to_clock op that directly feeds the clock output.
  Value clockOutputVal =
      srcBlock->getTerminator()->getOperand(info.clockResultIdx);
  Operation *toClockOp = clockOutputVal.getDefiningOp();

  // If the clock argument's only use is that seq.to_clock, it becomes entirely
  // unused once we drop that op — remove it from the no-clock signature.
  BlockArgument clockArg = srcBlock->getArgument(info.clockArgIdx);
  bool dropClockArg = llvm::all_of(clockArg.getUsers(), [&](Operation *user) {
    return user == toClockOp;
  });

  // Build the operand mapping: original index → new index, or -1 if dropped.
  NoClockArcInfo result;
  result.argMapping.resize(funcType.getNumInputs());
  SmallVector<Type> newInputTypes;
  int nextNewIdx = 0;
  for (unsigned i = 0; i < funcType.getNumInputs(); ++i) {
    if (i == info.clockArgIdx && dropClockArg) {
      result.argMapping[i] = -1;
    } else {
      result.argMapping[i] = nextNewIdx++;
      newInputTypes.push_back(funcType.getInput(i));
    }
  }

  // Build result types without the clock.
  SmallVector<Type> newResultTypes;
  for (auto [idx, type] : llvm::enumerate(funcType.getResults()))
    if (idx != info.clockResultIdx)
      newResultTypes.push_back(type);

  if (newResultTypes.empty()) {
    result.defineOp = nullptr;
    return result;
  }

  auto newFuncType = FunctionType::get(ctx, newInputTypes, newResultTypes);

  builder.setInsertionPoint(defineOp);
  result.defineOp = arc::DefineOp::create(builder, loc, newName, newFuncType);

  // Build the body block with only the kept arguments.
  auto &dstBlock = result.defineOp.getBody().emplaceBlock();
  IRMapping mapping;
  for (unsigned i = 0; i < funcType.getNumInputs(); ++i) {
    if (result.argMapping[i] == -1)
      continue;
    Value newArg = dstBlock.addArgument(funcType.getInput(i), loc);
    mapping.map(srcBlock->getArgument(i), newArg);
  }

  // Clone all non-terminator ops, skipping the clock-feeding seq.to_clock op.
  OpBuilder bb = OpBuilder::atBlockEnd(&dstBlock);
  for (auto &op : srcBlock->without_terminator()) {
    if (&op == toClockOp)
      continue;
    bb.clone(op, mapping);
  }

  // Rebuild arc.output without the clock result.
  SmallVector<Value> newOutputVals;
  for (auto [idx, operand] :
       llvm::enumerate(srcBlock->getTerminator()->getOperands()))
    if (idx != info.clockResultIdx)
      newOutputVals.push_back(mapping.lookupOrDefault(operand));

  arc::OutputOp::create(bb, loc, newOutputVals);
  return result;
}

//===----------------------------------------------------------------------===//
// processHwModule
//===----------------------------------------------------------------------===//

void DedupClocksPass::processHwModule(
    hw::HWModuleOp hwModule,
    const DenseMap<StringAttr, ClockArcInfo> &clockArcInfos,
    arc::DefineOp canonicalClockArc,
    const DenseMap<StringAttr, NoClockArcInfo> &noClockArcs) {

  auto seqClockType = seq::ClockType::get(&getContext());
  StringAttr canonicalName = canonicalClockArc.getNameAttr();

  // Collect arc.call ops that produce !seq.clock.
  SmallVector<arc::CallOp> clockCalls;
  hwModule.walk([&](arc::CallOp callOp) {
    if (clockArcInfos.count(callOp.getArcAttr().getAttr()))
      clockCalls.push_back(callOp);
  });

  if (clockCalls.empty())
    return;

  // Collect unique i1 SSA values used as clock sources.
  llvm::SetVector<Value> uniqueClockInputs;
  for (auto callOp : clockCalls) {
    StringAttr arcName = callOp.getArcAttr().getAttr();
    unsigned argIdx = clockArcInfos.find(arcName)->second.clockArgIdx;
    uniqueClockInputs.insert(callOp.getOperand(argIdx));
  }

  // Insert one canonical clock arc.call per unique clock source at the very
  // beginning of the module body (clock inputs are always block arguments and
  // therefore dominate every op in the body).
  DenseMap<Value, Value> canonicalClockValues;
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

  // Replace every clock-producing arc.call.
  for (auto callOp : clockCalls) {
    StringAttr arcName = callOp.getArcAttr().getAttr();
    const ClockArcInfo &info = clockArcInfos.find(arcName)->second;
    Value clockInput = callOp.getOperand(info.clockArgIdx);
    Value canonicalClock = canonicalClockValues.at(clockInput);

    // Redirect all uses of the !seq.clock result to the canonical value.
    callOp.getResult(info.clockResultIdx).replaceAllUsesWith(canonicalClock);

    auto noClockIt = noClockArcs.find(arcName);
    if (noClockIt == noClockArcs.end() || !noClockIt->second.defineOp) {
      callOp.erase();
      continue;
    }

    const NoClockArcInfo &noClockInfo = noClockIt->second;
    arc::DefineOp noClockDef = noClockInfo.defineOp; // non-const for method calls

    // Build the reduced result type list.
    SmallVector<Type> newResultTypes;
    for (auto [idx, type] : llvm::enumerate(callOp.getResultTypes()))
      if (idx != info.clockResultIdx)
        newResultTypes.push_back(type);

    // Build the reduced operand list, dropping removed arguments.
    SmallVector<Value> newOperands;
    for (auto [i, operand] : llvm::enumerate(callOp.getOperands()))
      if (noClockInfo.argMapping[i] != -1)
        newOperands.push_back(operand);

    OpBuilder insertBuilder(callOp);
    auto newCall = arc::CallOp::create(
        insertBuilder, callOp.getLoc(), newResultTypes,
        FlatSymbolRefAttr::get(noClockDef.getNameAttr()), newOperands);

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

  Namespace ns;
  ns.add(moduleOp);
  OpBuilder builder(ctx);

  // Step 1: Analyse arc.define ops that produce !seq.clock.
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

  // Step 2: Obtain or create the canonical clock arc.
  arc::DefineOp canonicalClockArc =
      getOrCreateCanonicalClockArc(moduleOp, builder, ns);
  StringAttr canonicalName = canonicalClockArc.getNameAttr();

  // Step 3: Create no-clock companion arcs for mixed arcs.
  DenseMap<StringAttr, NoClockArcInfo> noClockArcs;

  for (auto defineOp : clockDefines) {
    StringAttr name = defineOp.getNameAttr();
    bool isMixed = defineOp.getFunctionType().getNumResults() > 1;

    if (!isMixed || name == canonicalName) {
      noClockArcs[name] = NoClockArcInfo{nullptr, {}};
      continue;
    }

    std::string noClockName =
        ns.newName((defineOp.getSymName() + "_no_clock").str()).str();
    NoClockArcInfo noClockInfo = createNoClockArc(
        defineOp, clockArcInfos.at(name), noClockName, builder);
    if (noClockInfo.defineOp)
      ns.newName(noClockInfo.defineOp.getSymName()); // reserve
    noClockArcs[name] = std::move(noClockInfo);
  }

  // Step 4: Rewrite every hw.module.
  for (auto hwModule : moduleOp.getOps<hw::HWModuleOp>())
    processHwModule(hwModule, clockArcInfos, canonicalClockArc, noClockArcs);

  // Step 5: Remove the original clock-producing arc.define ops.
  for (auto defineOp : clockDefines) {
    if (defineOp.getNameAttr() == canonicalName)
      continue;
    defineOp.erase();
  }
}
