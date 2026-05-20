//===- SpecializeStateConstants.cpp ---------------------------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Specialize arc.define operations for arc.state operands driven by hw.constant
// values by moving those constants into cloned arc bodies.
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/Arc/ArcOps.h"
#include "circt/Dialect/Arc/ArcPasses.h"
#include "circt/Dialect/HW/HWOps.h"
#include "circt/Support/Namespace.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/IRMapping.h"
#include "mlir/Pass/Pass.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/StringMap.h"
#include "llvm/Support/raw_ostream.h"

#define DEBUG_TYPE "arc-specialize-state-constants"

namespace circt {
namespace arc {
#define GEN_PASS_DEF_SPECIALIZESTATECONSTANTS
#include "circt/Dialect/Arc/ArcPasses.h.inc"
} // namespace arc
} // namespace circt

using namespace circt;
using namespace arc;

namespace {

struct ConstantInput {
  unsigned index;
  hw::ConstantOp constant;
};

struct SpecializeStateConstantsPass
    : public arc::impl::SpecializeStateConstantsBase<
          SpecializeStateConstantsPass> {
  void runOnOperation() override;
};

} // namespace

static SmallVector<ConstantInput> getConstantInputs(StateOp stateOp) {
  SmallVector<ConstantInput> constants;
  for (auto [index, input] : llvm::enumerate(stateOp.getInputs()))
    if (auto constant = input.getDefiningOp<hw::ConstantOp>())
      constants.push_back({static_cast<unsigned>(index), constant});
  return constants;
}

static std::string getSpecializationKey(ArrayRef<ConstantInput> constants) {
  std::string key;
  llvm::raw_string_ostream os(key);
  for (auto constantInput : constants) {
    os << constantInput.index << ':';
    constantInput.constant.getValueAttr().print(os);
    os << ':';
    constantInput.constant.getResult().getType().print(os);
    os << ';';
  }
  return key;
}

static DefineOp createSpecializedArc(DefineOp original,
                                     ArrayRef<ConstantInput> constants,
                                     StringRef newName) {
  MLIRContext *context = original.getContext();
  OpBuilder moduleBuilder(original);
  Location loc = original.getLoc();
  Block &originalBody = original.getBodyBlock();

  BitVector constantIndices(originalBody.getNumArguments());
  for (auto constantInput : constants)
    constantIndices.set(constantInput.index);

  SmallVector<Type> newArgTypes;
  for (auto [index, arg] : llvm::enumerate(originalBody.getArguments()))
    if (!constantIndices[index])
      newArgTypes.push_back(arg.getType());

  auto newType =
      FunctionType::get(context, newArgTypes, original.getResultTypes());
  auto specialized = DefineOp::create(moduleBuilder, loc, newName, newType);

  auto newBlock = std::make_unique<Block>();
  for (auto type : newArgTypes)
    newBlock->addArgument(type, loc);

  OpBuilder bodyBuilder(context);
  bodyBuilder.setInsertionPointToStart(newBlock.get());

  IRMapping mapping;
  unsigned nextNewArg = 0;
  unsigned nextConstant = 0;
  for (auto [index, arg] : llvm::enumerate(originalBody.getArguments())) {
    if (!constantIndices[index]) {
      mapping.map(arg, newBlock->getArgument(nextNewArg++));
      continue;
    }

    assert(nextConstant < constants.size());
    assert(constants[nextConstant].index == index);
    Operation *clonedConstant =
        bodyBuilder.clone(*constants[nextConstant].constant);
    mapping.map(arg, clonedConstant->getResult(0));
    ++nextConstant;
  }

  for (auto &op : originalBody.without_terminator())
    bodyBuilder.clone(op, mapping);

  SmallVector<Value> returnValues;
  for (auto value : originalBody.getTerminator()->getOperands())
    returnValues.push_back(mapping.lookupOrDefault(value));
  OutputOp::create(bodyBuilder, loc, returnValues);

  specialized.getBody().push_back(newBlock.release());
  return specialized;
}

static void updateStateOp(StateOp stateOp, DefineOp specialized,
                          ArrayRef<ConstantInput> constants) {
  BitVector constantIndices(stateOp.getInputs().size());
  for (auto constantInput : constants)
    constantIndices.set(constantInput.index);

  SmallVector<Value> newInputs;
  for (auto [index, input] : llvm::enumerate(stateOp.getInputs()))
    if (!constantIndices[index])
      newInputs.push_back(input);

  stateOp.setCalleeFromCallable(
      SymbolRefAttr::get(specialized.getSymNameAttr()));
  stateOp.getInputsMutable().assign(newInputs);

  SmallPtrSet<Operation *, 4> maybeDeadConstants;
  for (auto constantInput : constants)
    maybeDeadConstants.insert(constantInput.constant.getOperation());
  for (auto *constant : maybeDeadConstants)
    if (constant->use_empty())
      constant->erase();
}

void SpecializeStateConstantsPass::runOnOperation() {
  ModuleOp module = getOperation();

  Namespace names;
  for (auto defOp : module.getOps<DefineOp>())
    names.newName(defOp.getSymName());

  DenseMap<StringAttr, SmallVector<StateOp>> statesByArc;
  module.walk([&](StateOp stateOp) {
    statesByArc[stateOp.getArcAttr().getAttr()].push_back(stateOp);
  });

  SmallVector<DefineOp> originalDefsToCheck;
  for (auto defOp : llvm::make_early_inc_range(module.getOps<DefineOp>())) {
    auto stateIt = statesByArc.find(defOp.getSymNameAttr());
    if (stateIt == statesByArc.end())
      continue;

    llvm::StringMap<DefineOp> specializations;
    for (auto stateOp : stateIt->second) {
      if (stateOp.getInputs().size() != defOp.getNumArguments())
        continue;

      SmallVector<ConstantInput> constants = getConstantInputs(stateOp);
      if (constants.empty())
        continue;

      std::string key = getSpecializationKey(constants);
      DefineOp specialized = specializations.lookup(key);
      if (!specialized) {
        std::string newName =
            names.newName(defOp.getSymName() + "_const").str();
        specialized = createSpecializedArc(defOp, constants, newName);
        specializations[key] = specialized;
        ++numSpecializedArcs;
      }

      updateStateOp(stateOp, specialized, constants);
      originalDefsToCheck.push_back(defOp);
      ++numSpecializedStates;
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
