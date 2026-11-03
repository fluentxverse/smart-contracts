# FluentXVerse Smart Contracts

Solidity source, tests, and deployment tooling for FluentXVerse.

## Projects

| Path | Status |
| --- | --- |
| [LessonDisputes](contracts/lesson-disputes/solidity/README.md) | Current dispute-decision registry |
| [Historical contracts](archive/2026-10-19/README.md) | Retired review, screening, and lesson-pass implementations; reference only |

The current contract records application-attested dispute decisions and refund
delivery commitments. It does not hold funds, transfer tokens, independently
verify attendance, or prove the truth of off-chain evidence. It is not independently
audited. See [deployment status and trust boundaries](docs/dispute-mainnet-production.md).

## Build And Test

Install Foundry v1.8.7, then run:

```sh
cd contracts/lesson-disputes/solidity
forge install foundry-rs/forge-std@f3dae6e6ee381f25eb6a246f7da9b85c91a68219 --no-git --shallow
forge install OpenZeppelin/openzeppelin-contracts@c64a1edb67b6e3f4a15cca8909c9482ad33a02b0 --no-git --shallow
forge fmt --check
forge build --sizes
forge test -vv
```

Solidity 0.8.28, Cancun, optimizer settings, fuzz counts, and invariant settings are
pinned in `foundry.toml`. Dependency commits are recorded in `dependencies.lock.json`.
Archived Solidity 0.8.30 contracts are deliberately outside this Foundry project.
The tutorial Counter contract is not included.

## Deployment Safety

The deployment script creates a paused contract with non-response automation disabled.
Publishing this repository does not deploy, activate, or change a live contract.
Production signing belongs in the approved Engine/Vault workflow, not this repository.
Never commit private keys, wallet exports, evidence, salts, runtime configuration,
transaction journals, or broadcast artifacts.

## Provenance

Extracted from the FluentXVerse workspace on November 3, 2026. Contract source and
dispute tests are preserved without behavioral changes. `VERIFICATION.md` retains
dated internal verification history; the deployment-status document supersedes its
older staging-only statements. Source files retain their SPDX license identifiers.
