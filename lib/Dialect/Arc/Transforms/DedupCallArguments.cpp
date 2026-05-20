//===- DedupCallArguments.cpp --------------------------------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Specialize arc.define operations for arc.state and arc.call sites that pass
// the same SSA value to multiple callee argument positions.
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/Arc/ArcOps.h"
#include "circt/Dialect/Arc/ArcPasses.h"
#include "circt/Support/Namespace.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/IRMapping.h"
#include "mlir/Pass/Pass.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringMap.h"
#include "llvm/Support/raw_ostream.h"

#define DEBUG_TYPE "arc-dedup-call-arguments"

namespace circt {
namespace arc {
#define GEN_PASS_DEF_DEDUPCALLARGUMENTS
#include "circt/Dialect/Arc/ArcPasses.h.inc"
} // namespace arc
} // namespace circt

using namespace circt;
using namespace arc;

namespace {

struct ArgumentMerge {
  SmallVector<unsigned> oldToNew;
  SmallVector<unsigned> representativeOldIndices;
  bool hasDuplicate = false;
};

struct DedupCallArgumentsPass
    : public arc::impl::DedupCallArgumentsBase<DedupCallArgumentsPass> {
  void runOnOperation() override;
};

} // namespace

static StringAttr getCalledArcName(Operation *op) {
  if (auto stateOp = dyn_cast<StateOp>(op))
    return stateOp.getArcAttr().getAttr();
  if (auto callOp = dyn_cast<CallOp>(op))
    return callOp.getArcAttr().getAttr();
  return {};
}

static OperandRange getArcInputs(Operation *op) {
  if (auto stateOp = dyn_cast<StateOp>(op))
    return stateOp.getInputs();
  if (auto callOp = dyn_cast<CallOp>(op))
    return callOp.getInputs();
  llvm_unreachable("expected arc.state or arc.call");
}

static void updateCallSite(Operation *op, DefineOp specialized,
                           ArrayRef<Value> newInputs) {
  auto newCallee = SymbolRefAttr::get(specialized.getSymNameAttr());
  if (auto stateOp = dyn_cast<StateOp>(op)) {
    stateOp.setCalleeFromCallable(newCallee);
    stateOp.getInputsMutable().assign(newInputs);
    return;
  }

  auto callOp = cast<CallOp>(op);
  callOp.setCalleeFromCallable(newCallee);
  callOp.getInputsMutable().assign(newInputs);
}

static ArgumentMerge getArgumentMerge(ValueRange inputs) {
  DenseMap<Value, unsigned> valueToNewIndex;
  ArgumentMerge merge;
  merge.oldToNew.reserve(inputs.size());

  for (auto [index, input] : llvm::enumerate(inputs)) {
    auto [it, inserted] =
        valueToNewIndex.try_emplace(input,
                                    merge.representativeOldIndices.size());
    if (inserted)
      merge.representativeOldIndices.push_back(index);
    else
      merge.hasDuplicate = true;
    merge.oldToNew.push_back(it->second);
  }

  return merge;
}

static std::string getSpecializationKey(const ArgumentMerge &merge) {
  std::string key;
  llvm::raw_string_ostream os(key);
  for (auto newIndex : merge.oldToNew)
    os << newIndex << ';';
  return key;
}

static DefineOp createDeduplicatedArc(DefineOp original,
                                      const ArgumentMerge &merge,
                                      StringRef newName) {
  MLIRContext *context = original.getContext();
  OpBuilder moduleBuilder(original);
  Location loc = original.getLoc();
  Block &originalBody = original.getBodyBlock();

  SmallVector<Type> newArgTypes;
  for (auto oldIndex : merge.representativeOldIndices)
    newArgTypes.push_back(originalBody.getArgument(oldIndex).getType());

  auto newType =
      FunctionType::get(context, newArgTypes, original.getResultTypes());
  auto specialized = DefineOp::create(moduleBuilder, loc, newName, newType);

  auto newBlock = std::make_unique<Block>();
  for (auto type : newArgTypes)
    newBlock->addArgument(type, loc);

  OpBuilder bodyBuilder(context);
  bodyBuilder.setInsertionPointToStart(newBlock.get());

  IRMapping mapping;
  for (auto [oldIndex, arg] : llvm::enumerate(originalBody.getArguments()))
    mapping.map(arg, newBlock->getArgument(merge.oldToNew[oldIndex]));

  for (auto &op : originalBody.without_terminator())
    bodyBuilder.clone(op, mapping);

  SmallVector<Value> returnValues;
  for (auto value : originalBody.getTerminator()->getOperands())
    returnValues.push_back(mapping.lookupOrDefault(value));
  OutputOp::create(bodyBuilder, loc, returnValues);

  specialized.getBody().push_back(newBlock.release());
  return specialized;
}

static SmallVector<Value> getDeduplicatedInputs(Operation *op,
                                                const ArgumentMerge &merge) {
  OperandRange inputs = getArcInputs(op);
  SmallVector<Value> newInputs;
  for (auto oldIndex : merge.representativeOldIndices)
    newInputs.push_back(inputs[oldIndex]);
  return newInputs;
}

void DedupCallArgumentsPass::runOnOperation() {
  ModuleOp module = getOperation();

  Namespace names;
  for (auto defOp : module.getOps<DefineOp>())
    names.newName(defOp.getSymName());

  DenseMap<StringAttr, llvm::StringMap<DefineOp>> specializationsByArc;
  SmallVector<DefineOp> originalDefsToCheck;
  bool changed = true;

  while (changed) {
    changed = false;

    DenseMap<StringAttr, SmallVector<Operation *>> sitesByArc;
    module.walk([&](Operation *op) {
      if (isa<StateOp, CallOp>(op))
        sitesByArc[getCalledArcName(op)].push_back(op);
    });

    for (auto defOp : llvm::make_early_inc_range(module.getOps<DefineOp>())) {
      auto siteIt = sitesByArc.find(defOp.getSymNameAttr());
      if (siteIt == sitesByArc.end())
        continue;

      auto &specializations = specializationsByArc[defOp.getSymNameAttr()];
      for (Operation *site : siteIt->second) {
        OperandRange inputs = getArcInputs(site);
        if (inputs.size() != defOp.getNumArguments())
          continue;

        ArgumentMerge merge = getArgumentMerge(inputs);
        if (!merge.hasDuplicate)
          continue;

        std::string key = getSpecializationKey(merge);
        DefineOp specialized = specializations.lookup(key);
        if (!specialized) {
          std::string newName =
              names.newName(defOp.getSymName() + "_dedup").str();
          specialized = createDeduplicatedArc(defOp, merge, newName);
          specializations[key] = specialized;
          ++numArcsCreated;
        }

        SmallVector<Value> newInputs = getDeduplicatedInputs(site, merge);
        updateCallSite(site, specialized, newInputs);
        originalDefsToCheck.push_back(defOp);
        ++numSitesFixed;
        changed = true;
      }
    }
  }

  DenseMap<StringAttr, unsigned> useCounts;
  for (auto defOp : module.getOps<DefineOp>())
    useCounts[defOp.getSymNameAttr()] = 0;
  module.walk([&](mlir::CallOpInterface callOp) {
    auto symRef = dyn_cast<SymbolRefAttr>(callOp.getCallableForCallee());
    if (!symRef)
      return;
    auto it = useCounts.find(symRef.getLeafReference());
    if (it != useCounts.end())
      ++it->second;
  });

  llvm::sort(originalDefsToCheck, [](DefineOp lhs, DefineOp rhs) {
    return lhs.getOperation() < rhs.getOperation();
  });
  originalDefsToCheck.erase(
      std::unique(originalDefsToCheck.begin(), originalDefsToCheck.end()),
      originalDefsToCheck.end());

  for (auto defOp : originalDefsToCheck)
    if (useCounts.lookup(defOp.getSymNameAttr()) == 0)
      defOp.erase();
}
