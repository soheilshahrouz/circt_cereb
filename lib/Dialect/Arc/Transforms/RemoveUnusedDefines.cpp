//===- RemoveUnusedDefines.cpp -------------------------------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Delete arc.define operations that have no symbol users.
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/Arc/ArcOps.h"
#include "circt/Dialect/Arc/ArcPasses.h"
#include "mlir/IR/SymbolTable.h"
#include "mlir/Pass/Pass.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/SmallVector.h"

#define DEBUG_TYPE "arc-remove-unused-defines"

namespace circt {
namespace arc {
#define GEN_PASS_DEF_REMOVEUNUSEDDEFINES
#include "circt/Dialect/Arc/ArcPasses.h.inc"
} // namespace arc
} // namespace circt

using namespace circt;
using namespace arc;

namespace {

struct RemoveUnusedDefinesPass
    : public arc::impl::RemoveUnusedDefinesBase<RemoveUnusedDefinesPass> {
  void runOnOperation() override;
};

} // namespace

static DenseMap<DefineOp, unsigned> collectDefineUseCounts(ModuleOp module) {
  DenseMap<DefineOp, unsigned> useCounts;
  for (auto define : module.getOps<DefineOp>())
    useCounts[define] = 0;

  SymbolTableCollection symbolTables;
  SmallVector<Operation *> symbols;
  auto collectUses = [&](Operation *symbolTableOp, bool allUsesVisible) {
    (void)allUsesVisible;
    for (Operation &nestedOp : symbolTableOp->getRegion(0).getOps()) {
      auto symbolUses = SymbolTable::getSymbolUses(&nestedOp);
      assert(symbolUses && "expected uses to be valid");

      for (const SymbolTable::SymbolUse &use : *symbolUses) {
        symbols.clear();
        (void)symbolTables.lookupSymbolIn(symbolTableOp, use.getSymbolRef(),
                                          symbols);
        for (Operation *symbol : symbols)
          if (auto define = dyn_cast<DefineOp>(symbol))
            ++useCounts[define];
      }
    }
  };

  SymbolTable::walkSymbolTables(module, /*allSymUsesVisible=*/false,
                                collectUses);
  return useCounts;
}

void RemoveUnusedDefinesPass::runOnOperation() {
  ModuleOp module = getOperation();

  bool changed = true;
  while (changed) {
    changed = false;
    auto useCounts = collectDefineUseCounts(module);

    SmallVector<DefineOp> unusedDefines;
    for (auto [define, count] : useCounts)
      if (count == 0)
        unusedDefines.push_back(define);

    if (unusedDefines.empty())
      continue;

    changed = true;
    for (DefineOp define : unusedDefines) {
      define.erase();
      ++numDefinesRemoved;
    }
  }
}
