# Deployment Status

Recorded November 3, 2026. This is a dated deployment record, not a live health check
or an independent security audit.

| Network | Chain ID | LessonDisputes address |
| --- | --- | --- |
| Arbitrum One | 42161 | `0x90153ced2a37eeba68c68f945653c7959ba0f627` |
| Arbitrum Sepolia | 421614 | `0x90153ced2a37eeba68c68f945653c7959ba0f627` |

Identical addresses on different networks represent distinct deployments.

The November 3 application release activated the existing Arbitrum One deployment,
approved its policy, and enabled non-response handling. No contract was redeployed.
The earlier staging-only statements in historical verification notes are superseded
by this record. Confirm current roles, pause status, policy, and runtime bytecode
before any operational action.

The application is authoritative for report eligibility, inbox timestamps, staff
authorization, earnings, and exactly-once credit restoration. Engine mirrors new
enrolled dispute cases through a serialized outbox and waits for canonical finalized
receipts. Existing cases are not automatically migrated.

On-chain evidence consists of salted commitments and public metadata, not raw
complaints, messages, recordings, names, or evidence salts. Refund receipts attest
to backend delivery; this contract does not transfer funds or credits.

Administrator/operator permissions may share one wallet. The separate reconciliation
role is also operated by FluentXVerse, not an independent external auditor. Timeout
decisions depend on honest application records and reconciliation, not a ZK absence
proof. The registry does not independently prove attendance or correct staff judgment.

Operational signing, protected journals, private feed configuration, and secrets
remain outside this source repository. Do not use the deployment script to change
the existing deployment or bypass the approved operational process.
