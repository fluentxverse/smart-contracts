# FluentXVerse Lesson Disputes

Standalone Solidity dispute-decision registry. Non-upgradeable,
no escrow, no token transfers, no external calls in case transitions.
Not independently audited. Deployed on Arbitrum One and Arbitrum Sepolia. The
November 3, 2026 Arbitrum One activation supersedes earlier staging-only notes.
See [deployment status](../../../docs/dispute-mainnet-production.md) and
[integration boundary](../../../docs/lesson-disputes-chain-integration.md).

## Responsibilities

- Engine authenticates reports, enforces one report per booking and the two-minute
  ongoing / 48-hour post-lesson reporting windows, validates lesson schedules,
  creates durable inbox requests after lesson end, and commits private evidence.
- The contract enforces caller permissions, one case per opaque lesson key,
  one immutable tutor-response commitment, deadline boundaries and terminal states.
- An administrator (prefer a multisig) manages policies, approves behavior-case
  explanation requests, decides cases, extends outage deadlines, and reconsiders
  decisions. Independent staff accounts remain an application authorization concern.
- A separate reconciler address asserts that authoritative reply records and the
  transaction outbox have been checked through the deadline. Engine then finalizes
  a non-response case. These are two permissions, not proof of independent operators.
- Refund approval is an instruction. Engine/Memgraph must restore the consumed
  entitlement exactly once; the contract records only the delivery receipt commitment.
- Student/staff inbox conversations, recordings, image attachments, notifications,
  support tickets, SYS-501 compensation and delivery retries stay off-chain.

## State And Rules

| Operation | Effect |
| --- | --- |
| `openCase` | Standard case, initially awaiting routing/staff |
| `openStaffReviewCase` | Staff-first behavior/misconduct case |
| `authorizeExplanation` | Audited staff authorization, required for staff-first cases |
| `requestExplanation` | One request after asserted lesson end; deadline = durable inbox creation + 24 hours |
| `recordResponse` | One timely accepted reply; pending TA-301 or staff review |
| `finalizeAcknowledgedTA301` | Eligible duration-based TA-301 at/after deadline, never on submission |
| `attestNoResponse` + `finalizeNonResponse` | Two-role, revision-bound non-response TA-301 |
| `resolveByStaff` | TA-301, No Penalty or Past for a staff-review case |
| `overrideActiveCase` | Explicit, revision-checked staff intervention on an unresolved case |
| `extendDeadline` | Explicit audited extension, never a reset on retry |
| `reconsider` | New decision appended to history, not replacement of old evidence |
| `resolveNoShow` | Trusted full-lesson no-entry evidence; closes any response obligation |
| `recordRefundDelivery` | At most one external-delivery receipt per lesson |

Exactly ten minutes belongs to the <=10-minute category. Engine must set the
automatic-routing flag only for that category plus one of the six qualifying
reasons (connection, audio, device, power, urgent personal matter, emergency).
Other, incomplete structured answers, and >10-minute replies go to staff.
The contract does not inspect private response content. Staff-first cases reject
automatic duration routing regardless of the flag supplied by Engine.

Any successfully sent nonempty reply, including image-only or short text, stops
non-response enforcement; Engine must not require a minimum substantive narrative.
The response timestamp is the authoritative durable acceptance time, not an upload
start, browser timestamp, or transaction inclusion time. Acceptance must be strictly
before the deadline. Blockchain submissions may arrive later. Old inbox requests
can be synchronized with their original (possibly expired) deadline; no automatic
penalty follows merely from recording that request.

TA-301 always approves a refund. No Penalty makes the tutor eligible for earnings
even when the student is refunded. Past does not earn. `isTutorPayable` describes
only this dispute's decision: it does not establish attendance, teaching, the
48-hour completion window, payment amount, or satisfaction of other payout holds.
Unresolved disputes never return payable. Five-minute no-entry statistics are not
full-lesson no-show evidence. No-show adjudication does not prove misconduct.

Reconsideration retains prior decisions, evidence, timestamps and the historical
non-response flag. Excusing that breach is explicit and sticky; it does not itself
change the financial outcome. Staff can subsequently impose a TA-301 for a different
reason without silently reactivating an excused non-response incident.
Once approved, a refund cannot be withdrawn or reissued by changing the decision.
No penalty amounts, extra non-response penalties or compensation amounts are
invented by this contract.

## Synchronization Is A Release Gate

An empty on-chain response is NOT evidence that the tutor did not reply.
Before signing a timeout attestation, the reconciler must:

1. Lock/read the authoritative Memgraph case at the expired deadline and verify
   no timely committed tutor reply exists. File uploads alone do not count.
2. Reconcile all earlier reply/request/extension/decision outbox work and confirm
   it against the canonical chain, not just a submitted transaction hash.
3. Check staff overrides and outage extensions, then bind the checkpoint evidence
   to the opaque case, contract, chain, policy, case revision and deadline.
4. Submit `attestNoResponse` under the reconciler key and confirm it.
5. Have Engine recheck the same authoritative records/outbox before finalization.
   If the state changed, submit the reply/extension first; these invalidate the
   on-chain attestation. Never finalize first just because a deadline worker ran.

The checkpoint must cover the deadline and cannot be from the future. Replies,
extensions and decisions invalidate prior attestations. Pause changes, role changes
and non-response enable/disable changes also invalidate configuration epochs.
Role acceptance disables non-response automation until explicitly reauthorized.
An operator that falsely attests, omits an accepted reply, misclassifies a report,
or submits finalization before a pending reply can still cause a wrong decision.
There is no implemented independent oracle or ZK absence proof here.

Non-response starts DISABLED, with no reconciler configured. Do not enable it in a
live environment until the Engine/Memgraph serialized outbox implementation and
outage/reorg recovery have been built and tested end to end. The contract tests
exercise the guard, not the honesty or correctness of those future services.

## Privacy And Commitments

All chain storage, arguments and events are public, including `private` variables.
Case timing, routing kind, outcome, refund approval and role addresses are visible.
Use a random 32-byte lesson key whose lookup is private, not a plain booking ID,
email digest or wallet address. This registry is not a shielded settlement system.

Keep raw complaints, tutor responses, image URLs, names, emails, recordings, rates,
salts and commitment preimages off-chain. Generate a fresh cryptographically random
32-byte salt for every evidence record. A suggested versioned commitment is:

```text
keccak256(abi.encode(
  keccak256("FXV_DISPUTE_EVIDENCE_V1"), chainId, contractAddress,
  lessonKey, policyHash, evidenceTypeHash, sha256(exactPrivateArtifactBytes), salt
))
```

Specify exact artifact bytes and evidence-type identifiers in the Engine adapter;
do not depend on ambiguous concatenation or arbitrary JSON key order. Store the
private artifact and salt under controlled access so authorized staff can reproduce
the digest. Compute locally in Engine, not through a public RPC with secret inputs.
Commitments provide integrity binding, not truthful evidence, confidentiality of
public metadata, or evidence availability.

No zkVerify verifier or receipt bridge is called by this contract. Existing
screening/payout proof pipelines remain separate and unchanged. Proof-gated dispute
decisions would require a separately specified statement and adapter.

## Refund Delivery

`refundInstructionId` is stable across all revisions of one case and is bound to
chain and contract. Use it as an outbox idempotency key. Also enforce one restoration
of the original consumed entitlement per booking in Memgraph across legacy,
cancellation and other contract/deployment paths; different contracts produce
different instruction IDs. A receipt commitment is Engine's assertion of delivery,
not an independently verified transfer or a proof of actual student credit.

Index canonical events with confirmations and reorg rollback. Commit decision,
slot status and durable refund intent together in Memgraph; retries must not issue
new value. Keep approved/failed/delivered work recoverable. Preserve original ticket
type/trial semantics. Do not mark a refund delivered merely because approval exists.

## Pause And Keys

Pause stops case opening, requests, authorizations, penalties and staff decisions.
Replies and refund delivery remain available; outage extensions remain available
to the administrator. Pausing does not stop the wall clock or extend deadlines:
staff must explicitly extend affected requests. There is no per-case timer process.

OpenZeppelin Ownable2Step controls administration. Ownership renunciation is disabled.
Engine and reconciler rotation also require candidate acceptance. Administrator
and Engine roles may share one wallet for closed testing, but the reconciler must
remain distinct from current and pending administrator/operator roles. Sharing a
wallet combines both sets of permissions and increases the impact of key compromise.
Either role can be separated later using two-step acceptance; acceptance disables
non-response automation and invalidates configuration-bound attestations.
Use Vault-backed signers and consider a separate multisig owner for stronger
operational separation; never put private keys in this repository.

## Build And Verify

Foundry 1.8.7 was used. Solidity 0.8.28 and Cancun EVM are pinned in `foundry.toml`.
From this directory, install dependencies on a fresh checkout:

```bash
forge install foundry-rs/forge-std@f3dae6e6ee381f25eb6a246f7da9b85c91a68219 --no-git --shallow
forge install OpenZeppelin/openzeppelin-contracts@c64a1edb67b6e3f4a15cca8909c9482ad33a02b0 --no-git --shallow
forge fmt --check
forge build --sizes
forge test -vv
forge coverage --report summary
```

Dependencies: forge-std v1.17.0; OpenZeppelin Contracts v5.4.0. Dependencies and
generated outputs are excluded from Git. Counter tutorial files are not included
in this repository.

`script/DeployLessonDisputes.s.sol` reads `DISPUTE_ADMINISTRATOR` and
`DISPUTE_ENGINE` addresses. It deploys paused, with no approved policies and
non-response disabled. It contains no wallet key or automatic unpause.
Only simulate locally until authorized. Actual testnet broadcasting belongs in
GMR Engine/Vault; no application backend should manage deployment keys.

Tests cover original lessons, expiry boundaries, delayed synchronization, staff-first
behavior routing, policy approval/revocation, extensions, timeout attestations,
stale revisions, role rotation, no-shows, refund receipts and reconsideration.
Fuzz tests use 512 runs; stateful invariants use 128 runs of 64 calls across eight
opaque lessons. Coverage and internal testing are not an independent audit.

## Before Any Public Rollout

- Review and promote the staged Engine/Memgraph adapter, permissions and serialized outbox.
- Define canonical evidence serialization and private retention/access policies.
- Extend the synthetic Sepolia pilot to a controlled human workflow with real
  inbox timestamps and no real payout funds; the automated pilot uses historical
  synthetic inbox times for deadline tests.
- Test canonical indexing, retries, reorgs, outages and actual entitlement restoration.
- Review threat model, role custody, pinned dependencies, and contract independently.
- Do not label this system trustless, confidential on-chain finance, or ZK-verified
  dispute adjudication. Staff arbitrate; Engine/reconciler attest to off-chain facts.

References: [OpenZeppelin access control](https://docs.openzeppelin.com/contracts/5.x/access-control),
[Ownable2Step](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.4.0/contracts/access/Ownable2Step.sol),
[Foundry invariant testing](https://getfoundry.sh/forge/invariant-testing/).
