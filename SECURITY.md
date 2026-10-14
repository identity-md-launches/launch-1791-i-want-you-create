# Implementation review

The application is a single immutable escrow for the USDC address specified by the requester. The review focused on authorized funding, exclusive recipient claims, solvency accounting, and atomic failure behavior. It is an implementation review by the author, not an independent audit.

## Privileges and custody

- `deposit` checks the current owner and always sources funds from that caller. Arbitrary users cannot turn their token approvals or unsolicited donations into credits.
- `claim` has no beneficiary or destination argument. Its only lookup and payout address is `msg.sender`. The owner cannot withdraw another wallet's balance.
- Ownership is initialized from the explicit constructor argument and transferred only after acceptance by the nominated wallet. Renunciation is disabled. No upgrade, pause, sweep, arbitrary-call, or recovery surface is exposed by the application.
- Each deposit requires exact new backing. Each claim clears the caller's balance and reduces total liability before transfer. Both paths share a reentrancy lock, including the deposit path where accounting follows the verified incoming transfer.
- SafeERC20 failures, token reverts, and unexpected balance changes roll back the entire call. Claims remain retryable. No loop over recipients is required for normal operation.
- Accounting uses checked `uint256` arithmetic and raw token units with no multiplication, division, rounding, or narrowing conversions.

## Adversarial cases exercised

`test/USDCDepositClaim.t.sol` covers unauthorized funding and claiming, over-claim attempts, accumulation, owner handover, approval and balance shortfalls, malformed/false/empty token return values, no-op and inexact transfers, direct donations, missing code, and USDC-style pause/blocklist failures. Contract-wallet callbacks attempt claim-to-claim, claim-to-deposit, deposit-to-claim, and deposit-to-deposit reentrancy. A bubbled callback failure is retried successfully after disabling the callback, checking that neither credit nor the guard is left stuck.

`test/USDCDepositClaim.invariant.t.sol` independently tracks each recipient's expected credits and payouts. It checks total liabilities, backing including donations, conservation of deposits, recipient-only payouts, and redemption of every remaining credit after randomized sequences. Expected failing transactions are part of the sequences, not silently discarded handler reverts.

Factory deployment tests use the supplied launch owner and remove token code before construction. Runtime checks follow the provided forbidden-opcode scan and EIP-170 bound. All dependency libraries used by application code are internal and require no deployment links.

## Remaining release responsibilities

The independent contributor review and launch service must review the final source, compiler settings, deployed bytecode, and the later manifest's owner argument before release. Verify the source and confirm the deployed owner and fixed USDC address before accepting funds.

The operator must validate intended recipients, use USDC base units, approve the intended funding amount, monitor failed transactions, and preserve ownership access. Recipient wallets must be capable of calling the application and retaining their own keys. The application cannot correct an allocation or recover assets sent outside the deposit flow.

The local suite uses a mock, not a mainnet fork. It covers representative token failure and callback behavior but cannot establish ongoing USDC availability, issuer policy, future upgrades, or honest balance reporting by a malicious token. A token balance reduction outside the escrow's calls can make it undercollateralized; there is no alternate asset, recapitalization allocation mechanism, or issuer bypass. Direct USDC donations can add backing without creating credit, but are not recoverable surplus.

Foundry build, unit/fuzz tests, stateful invariants, and formatting are the local verification tools. Slither, Mythril, live-chain simulation, and an independent audit are not part of the reported local results. Passing tests does not replace the separate release review.
