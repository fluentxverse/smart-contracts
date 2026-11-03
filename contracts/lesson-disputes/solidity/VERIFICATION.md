# Internal Verification

## Standalone Repository Check

November 3, 2026: a fresh dependency installation in this repository passed
`forge fmt --check`, `forge build --sizes`, and `forge test -vv` with Foundry 1.8.7
and Solidity 0.8.28. All 84 dispute tests passed, including both invariants with
128 runs and 8,192 calls each. The two Counter tutorial tests are intentionally
not included. Runtime size remains 13,678 bytes; initcode is 14,118 bytes.
Existing linter warnings remain; this extraction makes no contract logic changes.
This check did not deploy a contract or send any blockchain transaction.

The notes below are historical. See the current dated
[deployment record](../../../docs/dispute-mainnet-production.md) for the November 3
mainnet activation; older staging-only restrictions describe the earlier release.

## Historical Verification

Date: November 1, 2026 (Asia/Manila).

This is internal engineering verification, not an independent security audit.
No public-chain transaction, wallet signing, paid proof submission, live refund,
application deployment or production database change was performed.

## Checks

- Solidity 0.8.28 / Cancun / optimizer 200 compilation succeeded.
- Foundry formatting checks passed.
- 33 original/extended tutorial tests passed. The duplicate-case test was repaired
  to actually attempt a second creation; one redundant paused test was removed.
- 40 additional lifecycle/security tests passed, including authorization fuzzing,
  staff-first complaints, deadlines, historical synchronization, timeout attestations,
  extensions, staff overrides, reconsideration history, role rotation and refunds.
- One stateful invariant passed: 128 runs, 64 calls per run (8,192 randomized
  handler calls), zero unexpected reverts. This is not exhaustive exploration.
- Fuzz functions ran 512 cases each; fixed seeds 0x01 and 0x02 were exercised
  during development. The final suite includes 76 checks total (74 dispute checks
  and two unchanged Counter example tests).
- The deployment script simulated successfully with dummy addresses and no RPC
  or broadcast. It asserted paused/non-response-disabled deployment defaults.
- Compiled runtime: 13,805 bytes (24,576-byte EIP-170 limit); initcode: 14,295
  bytes. Remeasure the artifact with `forge build --sizes` before any release.

Coverage commands executed successfully, but Foundry 1.8.7 emitted source-map
anchor warnings (including under `--ir-minimum`). The resulting percentages are
diagnostic only and are not a release gate or a claim of complete coverage.
The sandbox also denied writes to Foundry's optional global signature cache;
this warning did not prevent compilation, simulation or test execution.
Compiler/linter timestamp warnings concern deliberate deadline logic; the chain
clock and operator-attested durable receipt clock remain explicit trust assumptions.
Foundry also reports pending-role event and constructor zero-check warnings despite
explicit proposal/acceptance events and `_validateRoles` checks; these were reviewed,
not globally suppressed. Tests cover zero roles and role changes.

## Shared-Role Update

On November 2, 2026, administrator/operator overlap was permitted while retaining
reconciler separation, two-step role transfers, disabled timeout defaults, and the
ability to separate those roles later. The updated suite passes 86 checks total
(84 dispute checks and two unchanged Counter tests), with 512 fuzz cases per
fuzz function. Split-role and shared-role invariants each pass 128 runs x 64 calls
(16,384 total randomized handler calls), with zero unexpected reverts, seed 0x03.
The refreshed solc 0.8.28 artifact has 13,678 runtime bytes and 14,118 initcode bytes.
Engine's local Anvil deployment test covers both constructor configurations.
These checks are internal, not an independent audit or approval of live automation.

## Remaining Integration Gates

The separate [integration implementation](../../../docs/lesson-disputes-chain-integration.md)
now includes the Engine/Vault adapter, authenticated application outbox, private
evidence commitments, durable transaction journal, refund deduplication, local
recovery tests, and a synthetic Sepolia pilot. It is staged, not production enforcement.

1. Review and promote the application and adapter together rather than enabling
   the paused mainnet contract in isolation.
2. Review independent operational reconciliation before enabling non-response automation.
3. Approve evidence serialization, salt custody and private retention/access policy.
4. Complete live worker/finality operational review and define migration of any
   backend-only legacy/no-report attendance paths intended for on-chain coverage.
5. Verify controlled human inbox/reply flows and earnings/proof holds; historical
   synthetic deadline tests are not a substitute for that operational check.
6. Review the contract, role custody and exact dependency revisions independently
   before money movement or public production use.

The contract enforces a trusted-operator workflow. It does not prove absence of
off-chain replies, actual lesson attendance, truthful staff judgment, correct
external refunds, or confidential settlement. zkVerify integration is unchanged.
