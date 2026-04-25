//===- InlineCallArcs.cpp -------------------------------------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This pass inlines arc.call (combinational arc) logic into the arc
// definitions of consuming arc.state and arc.call operations, removing
// intermediate SSA values and folding combinational fan-in directly into
// the body of each consuming arc.
//
//===----------------------------------------------------------------------===//

#include "circt/Dialect/Arc/ArcOps.h"
#include "circt/Dialect/Arc/ArcPasses.h"
#include "circt/Dialect/HW/HWOps.h"
#include "circt/Dialect/Seq/SeqTypes.h"
#include "circt/Support/Namespace.h"
#include "mlir/IR/IRMapping.h"
#include "mlir/IR/ImplicitLocOpBuilder.h"
#include "mlir/Pass/Pass.h"
#include "llvm/Support/Debug.h"
#include <deque>

#define DEBUG_TYPE "arc-inline-call-arcs"

namespace circt {
namespace arc {
#define GEN_PASS_DEF_INLINECALLARCS
#include "circt/Dialect/Arc/ArcPasses.h.inc"
} // namespace arc
} // namespace circt

using namespace circt;
using namespace arc;

namespace {

struct InlineCallArcsPass
    : public arc::impl::InlineCallArcsBase<InlineCallArcsPass> {
  void runOnOperation() override;
};

} // namespace

/// Returns true when a value has the seq.clock type.
static bool isClockType(Value v) {
  return isa<seq::ClockType>(v.getType());
}

/// Returns true when every result of an operation has the seq.clock type.
static bool allResultsAreClock(Operation *op) {
  return llvm::all_of(op->getResults(),
                      [](Value v) { return isa<seq::ClockType>(v.getType()); });
}

/// Returns the symbolic arc name referenced by an arc.state or arc.call.
static StringAttr getCalledArcName(Operation *op) {
  if (auto stateOp = dyn_cast<arc::StateOp>(op))
    return stateOp.getArcAttr().getAttr();
  if (auto callOp = dyn_cast<arc::CallOp>(op))
    return callOp.getArcAttr().getAttr();
  return {};
}

/// Returns the "inputs" operands of an arc.state or arc.call (excludes the
/// optional clock/enable/reset operands of arc.state).
static OperandRange getArcInputs(Operation *op) {
  if (auto stateOp = dyn_cast<arc::StateOp>(op))
    return stateOp.getInputs();
  if (auto callOp = dyn_cast<arc::CallOp>(op))
    return callOp.getInputs();
  llvm_unreachable("expected arc.state or arc.call");
}

/// Build a new arc.define whose body inlines producerDef into consumerDef.
///
/// The new arc's argument list is:
///   [kept consumer args (those NOT coming from the producer)] ++
///   [all of producer's args]
///
/// Its body first executes producerDef's logic, then consumerDef's logic, with
/// the consumer arguments that previously received a producer result replaced
/// by the corresponding producer output value.
///
/// \p inputToProducerResult  Maps each input index of consumerDef to the
///   producer result index it comes from, or -1 if it is an independent input.
static DefineOp createInlinedArc(DefineOp producerDef, DefineOp consumerDef,
                                 ArrayRef<int64_t> inputToProducerResult,
                                 StringRef newName,
                                 ImplicitLocOpBuilder &ilob) {
  MLIRContext *ctx = ilob.getContext();
  Block &consumerBody = consumerDef.getBodyBlock();
  Block &producerBody = producerDef.getBodyBlock();

  // --- Build the new function type -------------------------------------------
  // Part 1: consumer arguments that are NOT coming from the producer.
  SmallVector<Type> newArgTypes;
  unsigned numKeptConsumerArgs = 0;
  for (unsigned i = 0; i < consumerBody.getNumArguments(); ++i) {
    if (inputToProducerResult[i] < 0) {
      newArgTypes.push_back(consumerBody.getArgument(i).getType());
      ++numKeptConsumerArgs;
    }
  }

  // Part 2: all of the producer's arguments appended.
  const unsigned producerArgsOffset = numKeptConsumerArgs;
  for (auto arg : producerBody.getArguments())
    newArgTypes.push_back(arg.getType());

  SmallVector<Type> resultTypes(consumerDef.getFunctionType().getResults());
  auto funcType = FunctionType::get(ctx, newArgTypes, resultTypes);

  // --- Build the body block independently ------------------------------------
  // Following the same pattern as SplitLoops: create the block separately,
  // populate it, then push it into the DefineOp.  This avoids any assumptions
  // about what DefineOp::create puts into its body region.
  Location loc = ilob.getLoc();
  auto newBlock = std::make_unique<Block>();

  // Add block arguments to match the new function type.
  for (auto type : newArgTypes)
    newBlock->addArgument(type, loc);

  OpBuilder blockBuilder(ilob.getContext());
  blockBuilder.setInsertionPointToStart(newBlock.get());

  // --- Populate the body -----------------------------------------------------
  IRMapping mapping;

  // Map producer's block arguments to the new block's tail arguments.
  for (auto [i, arg] : llvm::enumerate(producerBody.getArguments()))
    mapping.map(arg, newBlock->getArgument(producerArgsOffset + i));

  // Clone the producer body (excluding its arc.output terminator).
  for (auto &op : producerBody.without_terminator())
    blockBuilder.clone(op, mapping);

  // Resolve SSA values for the producer's return operands.
  SmallVector<Value> producerResultValues;
  for (auto retVal : producerBody.getTerminator()->getOperands())
    producerResultValues.push_back(mapping.lookupOrDefault(retVal));

  // Map consumer block arguments:
  //   - args coming from a producer result  → that result's SSA value above
  //   - args that are independent inputs     → the corresponding kept new arg
  unsigned keptIdx = 0;
  for (unsigned i = 0; i < consumerBody.getNumArguments(); ++i) {
    const int64_t prodIdx = inputToProducerResult[i];
    if (prodIdx >= 0)
      mapping.map(consumerBody.getArgument(i), producerResultValues[prodIdx]);
    else
      mapping.map(consumerBody.getArgument(i),
                  newBlock->getArgument(keptIdx++));
  }

  // Clone the consumer body (excluding its arc.output terminator).
  for (auto &op : consumerBody.without_terminator())
    blockBuilder.clone(op, mapping);

  // Emit the arc.output with the consumer's (now mapped) return values.
  SmallVector<Value> returnVals;
  for (auto retVal : consumerBody.getTerminator()->getOperands())
    returnVals.push_back(mapping.lookupOrDefault(retVal));
  OutputOp::create(blockBuilder, loc, returnVals);

  // --- Create the DefineOp and attach the populated block --------------------
  // DefineOp::build adds an empty region (no blocks, no implicit terminator
  // is inserted programmatically).  Push our fully-populated block in; it
  // becomes the one and only block in the region.
  auto newArc = DefineOp::create(ilob, newName, funcType);
  newArc.getBody().push_back(newBlock.release());

  return newArc;
}

/// Replace consumerOp (arc.state or arc.call) with a new op that:
///   - references newArcDef instead of the original callee,
///   - passes [kept inputs...] ++ [producerCall's inputs] as the new inputs,
///   - preserves clock / enable / reset / latency / initials for arc.state.
///
/// Returns the newly created operation.  For arc.state consumers this is an
/// arc.state; for arc.call consumers it is the new arc.call that replaced the
/// old one (the old one is erased and recorded in \p erasedCallOps).
static Operation *updateConsumerOp(Operation *consumerOp, DefineOp newArcDef,
                                   CallOp producerCall,
                                   ArrayRef<int64_t> inputToProducerResult,
                                   SmallPtrSetImpl<Operation *> &erasedCallOps) {
  auto newArcRef = SymbolRefAttr::get(newArcDef.getSymNameAttr());
  OperandRange oldInputs = getArcInputs(consumerOp);

  // Build the new input list.
  SmallVector<Value> newInputs;
  for (unsigned i = 0; i < oldInputs.size(); ++i)
    if (inputToProducerResult[i] < 0)
      newInputs.push_back(oldInputs[i]);
  for (auto inp : producerCall.getInputs())
    newInputs.push_back(inp);

  OpBuilder builder(consumerOp);
  Location loc = consumerOp->getLoc();

  if (auto stateOp = dyn_cast<arc::StateOp>(consumerOp)) {
    // Preserve all arc.state properties; only arc ref and inputs change.
    auto newState =
        StateOp::create(builder, loc, newArcRef, stateOp->getResultTypes(),
                        stateOp.getClock(), stateOp.getEnable(),
                        stateOp.getReset(), stateOp.getLatency(), newInputs,
                        stateOp.getInitials());
    // Forward any extra attributes (e.g. "names" tap attributes).
    for (auto namedAttr : stateOp->getAttrDictionary())
      if (!newState->hasAttr(namedAttr.getName()))
        newState->setAttr(namedAttr.getName(), namedAttr.getValue());
    stateOp->replaceAllUsesWith(newState->getResults());
    stateOp->erase();
    return newState;
  }

  if (auto callOp = dyn_cast<arc::CallOp>(consumerOp)) {
    auto newCall = CallOp::create(builder, loc, callOp->getResultTypes(),
                                  newArcRef, newInputs);
    callOp->replaceAllUsesWith(newCall->getResults());
    // Record the pointer before erasure so callers can detect stale handles.
    erasedCallOps.insert(consumerOp);
    callOp->erase();
    return newCall;
  }

  return nullptr;
}

void InlineCallArcsPass::runOnOperation() {
  ModuleOp module = getOperation();

  // Build a name → DefineOp lookup table.
  DenseMap<StringAttr, DefineOp> arcDefs;
  for (auto defOp : module.getOps<DefineOp>())
    arcDefs[defOp.getSymNameAttr()] = defOp;

  // Pre-populate a namespace with all existing arc names so generated names
  // remain unique.
  Namespace ns;
  for (auto defOp : module.getOps<DefineOp>())
    ns.newName(defOp.getSymName());

  // Track arc definitions that may have become unused after transformations.
  SmallVector<DefineOp> defsToCheckForRemoval;

  // Track arc.call ops that were consumed (erased) while acting as consumers
  // of another arc.call.  They may still appear in the worklist, so we need
  // to skip them when encountered as producers.
  SmallPtrSet<Operation *, 16> erasedCallOps;

  // Process each hw.module (the flat body after ConvertToArcs).
  for (auto hwModule : module.getOps<hw::HWModuleOp>()) {
    Block &body = *hwModule.getBodyBlock();

    // Fixed-point outer loop: re-seed the worklist as long as inlining keeps
    // making progress.  In practice this converges in 1–2 rounds; the inner
    // worklist collapses most arc.call→arc.call chains without restarting, but
    // ordering edge-cases (consumers finalized after the producer was already
    // popped from the worklist) are caught by the outer loop.
    bool anyInlinedThisRound = true;
    while (anyInlinedThisRound) {
      anyInlinedThisRound = false;

      // Seed the worklist with all non-clock arc.call ops still in the body.
      // Newly created arc.calls (from inlining into arc.call consumers) are
      // pushed to the back so chains are resolved without waiting for the next
      // outer iteration.
      std::deque<CallOp> worklist;
      for (auto &op : body)
        if (auto callOp = dyn_cast<arc::CallOp>(&op))
          if (!callOp.getResults().empty() && !allResultsAreClock(callOp))
            worklist.push_back(callOp);

      while (!worklist.empty()) {
        CallOp producerCall = worklist.front();
        worklist.pop_front();

        // Skip if this call was erased while acting as a consumer of another
        // producer in an earlier worklist iteration.
        if (erasedCallOps.count(producerCall.getOperation()))
          continue;

        const StringAttr producerName = producerCall.getArcAttr().getAttr();
        DefineOp producerDef = arcDefs.lookup(producerName);
        if (!producerDef)
          continue;

        // For each consumer op (arc.state or arc.call in the same block) that
        // uses producerCall's non-clock results as arc inputs, build a per-
        // consumer mapping: input-index → producer-result-index (or -1).
        DenseMap<Operation *, SmallVector<int64_t>> consumerMappings;

        for (auto [resultIdx, result] :
             llvm::enumerate(producerCall.getResults())) {
          if (isClockType(result))
            continue;

          for (auto &use : result.getUses()) {
            Operation *user = use.getOwner();

            // Only handle arc.state and arc.call in the same flat block.
            if (!isa<arc::StateOp, arc::CallOp>(user))
              continue;
            if (user->getBlock() != &body)
              continue;

            // Only track uses in the "inputs" portion (not clock/enable/reset).
            bool foundInInputs = false;
            for (auto inp : getArcInputs(user))
              if (inp == result) {
                foundInInputs = true;
                break;
              }
            if (!foundInInputs)
              continue;

            // Initialise this consumer's mapping vector on first encounter.
            auto &mapping = consumerMappings[user];
            if (mapping.empty())
              mapping.assign(getArcInputs(user).size(), -1LL);

            // Mark every input position that receives this particular result.
            OperandRange userInputs = getArcInputs(user);
            for (unsigned i = 0; i < userInputs.size(); ++i)
              if (userInputs[i] == result)
                mapping[i] = static_cast<int64_t>(resultIdx);
          }
        }

        if (consumerMappings.empty())
          continue;

        // For each consumer, create an inlined arc definition and update the
        // call site.
        for (auto &[consumerOp, inputMapping] : consumerMappings) {
          const StringAttr consumerArcName = getCalledArcName(consumerOp);
          if (!consumerArcName)
            continue;
          DefineOp consumerDef = arcDefs.lookup(consumerArcName);
          if (!consumerDef)
            continue;

          // Safety: verify that the mapping size matches the arc def's args.
          if (inputMapping.size() !=
              consumerDef.getBodyBlock().getNumArguments())
            continue;

          // Generate a unique name for the new inlined arc.
          std::string newName =
              ns.newName(consumerDef.getSymName() + "_inlined").str();

          // Insert the new arc definition immediately before the consumer def.
          ImplicitLocOpBuilder ilob(consumerDef.getLoc(), consumerDef);
          DefineOp newArcDef = createInlinedArc(producerDef, consumerDef,
                                                inputMapping, newName, ilob);
          arcDefs[newArcDef.getSymNameAttr()] = newArcDef;

          LLVM_DEBUG(llvm::dbgs()
                     << "[inline-call-arcs] inlined '"
                     << producerDef.getSymName() << "' into '"
                     << consumerDef.getSymName() << "' → '" << newName
                     << "'\n");

          // Replace the consumer call site; the returned op is the fresh
          // replacement (erased ops are also recorded in erasedCallOps).
          Operation *newConsumerOp = updateConsumerOp(
              consumerOp, newArcDef, producerCall, inputMapping, erasedCallOps);

          // If the new consumer is itself an arc.call, push it so chains of
          // arc.call→arc.call→arc.state are resolved within this outer round.
          if (auto newCallOp =
                  llvm::dyn_cast_if_present<arc::CallOp>(newConsumerOp))
            if (!allResultsAreClock(newCallOp))
              worklist.push_back(newCallOp);

          defsToCheckForRemoval.push_back(consumerDef);
          ++numCallsInlined;
          anyInlinedThisRound = true;
        }

        // Mark the producer definition for potential removal.
        defsToCheckForRemoval.push_back(producerDef);
      } // end inner worklist
    } // end outer fixed-point loop
  }

  // --- Cleanup ---------------------------------------------------------------

  // Remove arc.call ops in hw.module bodies that no longer have any uses.
  for (auto hwModule : module.getOps<hw::HWModuleOp>())
    for (auto &op : llvm::make_early_inc_range(*hwModule.getBodyBlock()))
      if (auto callOp = dyn_cast<arc::CallOp>(&op))
        if (callOp->use_empty())
          callOp.erase();

  // Recount uses for every arc definition (including newly created ones).
  DenseMap<StringAttr, unsigned> useCounts;
  for (auto &[name, _] : arcDefs)
    useCounts[name] = 0;
  module.walk([&](mlir::CallOpInterface callOp) {
    auto symRef = dyn_cast<SymbolRefAttr>(callOp.getCallableForCallee());
    if (!symRef)
      return;
    auto it = useCounts.find(symRef.getLeafReference());
    if (it != useCounts.end())
      ++it->second;
  });

  // Deduplicate the list of definitions to check.
  llvm::sort(defsToCheckForRemoval, [](DefineOp a, DefineOp b) {
    return a.getOperation() < b.getOperation();
  });
  defsToCheckForRemoval.erase(
      std::unique(defsToCheckForRemoval.begin(), defsToCheckForRemoval.end()),
      defsToCheckForRemoval.end());

  // Erase definitions that have no remaining callers.
  for (auto defOp : defsToCheckForRemoval)
    if (defOp && useCounts.lookup(defOp.getSymNameAttr()) == 0)
      defOp.erase();
}
