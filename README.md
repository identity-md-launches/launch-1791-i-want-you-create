# USDC deposit and claim

`USDCDepositClaim` lets an owner fund USDC balances for recipients. Repeated deposits add to a recipient's balance. Each recipient calls `claim()` to receive their full balance in their own wallet; a successful claim resets that balance to zero. A failed transaction leaves both the token balances and the claim accounting unchanged.

## Deployment

Deploy the single application in `src/USDCDepositClaim.sol` on **Ethereum mainnet, chain ID 1**.

| Parameter | Value |
| --- | --- |
| Solidity contract | `USDCDepositClaim` |
| Constructor | `constructor(address initialOwner)` (nonpayable) |
| `initialOwner` | `0xca182aa19dde767ab809e0a4cc9fc1860be03d36`, the launch's supplied owner (`$owner` in the subsequent manifest) |
| USDC | Fixed at `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| Native ETH at deployment | None |
| Compiler | Solidity `0.8.26` |
| Build | Cancun EVM, optimizer enabled with 200 runs, `bytecode_hash = "none"` |

The token address is supplied in the task and listed by [Circle for Ethereum USDC](https://help.circle.com/support/en/usdc-supported-blockchains-minting-redemption-faqs?id=kb_article_view&sysparm_article=KB0010590). It is not a configurable constructor parameter. This application is not intended for testnets, bridged USDC, or other chains.

The constructor sets the explicitly supplied owner, independent of the factory's `msg.sender` or transaction origin. It makes no external calls and does not require USDC code to exist at deployment. Funding and funded claims check that token code exists when used. There is no initializer, proxy, linked external library, or additional application contract. Test helpers are not deployment targets.

The launch service performs deployment and source verification. Its later manifest step supplies the constructor argument; this project does not supply a `launch.json` or a broadcast script.

## After launch

There are no unresolved settings or initialization calls. Before funding, the owner must confirm the deployment is on chain ID 1, `owner()` matches the intended wallet, and `USDC()` matches the address above. The owner must control that wallet and hold the required USDC and transaction gas.

To allocate **25 USDC** to a recipient:

1. From the current owner wallet, call USDC's `approve(applicationAddress, 25_000_000)`.
2. From the same owner wallet, call the application's `deposit(recipientAddress, 25_000_000)`.
3. The recipient can read `claimable(recipientAddress)` and call `claim()` from that address whenever they want the full amount.

`applicationAddress` and `recipientAddress` in this example mean the confirmed deployment address and the owner's intended recipient. They are not embedded placeholder addresses. The recipient does not approve USDC to claim. A contract wallet must be able to execute `claim()` as that wallet. An intermediary calling on behalf of an EOA cannot claim the EOA's balance.

All amounts use USDC's **six-decimal base units**: `1_000_000` means 1 USDC and `1` means 0.000001 USDC. No conversion from dollars or 18-decimal units occurs. There are no fees, interest, lockup, expiry, or partial claims. The positive amount requirement is the only minimum.

**Always fund through `deposit`.** A direct token transfer to the application creates no recipient credit and cannot be recovered. It is treated as surplus; a later deposit still requires a new transfer from the owner. There is no surplus withdrawal or token rescue function. Do not send other tokens or native ETH to the application.

Use an allowance sized for the intended deposits. After a handover, the new owner must fund and approve from their own wallet; the former owner's allowance gives them no deposit authority. Revoke unused allowances when no longer needed.

## Interface

| Function | Caller and effect |
| --- | --- |
| `deposit(address recipient, uint256 amount)` | Owner only. Transfers USDC from the owner and adds exactly `amount` to the recipient's balance. |
| `claim()` | Any funded recipient. Pays only `msg.sender` their full credited balance and resets it to zero. Reverts when there is nothing to claim. |
| `claimable(address recipient)` | Public read of that address's unclaimed base units. |
| `totalClaimable()` | Public read of all outstanding credits; excludes unsolicited donations. |
| `USDC()` | Public read of the fixed token address. |
| `owner()`, `pendingOwner()` | Public reads of ownership state. |
| `transferOwnership(address newOwner)` | Current owner nominates or replaces a pending owner. Passing the zero address cancels a pending nomination; it does not remove the current owner. |
| `acceptOwnership()` | Only the pending owner can complete the handover. Existing recipient credits are unaffected. |
| `renounceOwnership()` | Disabled; reverts to prevent accidentally disabling future funding. |

Successful funding emits `Deposited(funder, recipient, amount)`. Successful claims emit `Claimed(recipient, amount)`. Ownership changes emit the inherited OpenZeppelin ownership events. Recipients are stored in a mapping; use deposit events to discover addresses rather than expecting an on-chain recipient list.

Deposits reject zero amounts and the zero address, the application itself, or the USDC contract as recipient. The owner is responsible for all other recipient choices, including ensuring a contract recipient can call `claim()`. Existing credits cannot be corrected, revoked, reassigned, or claimed by the owner unless the owner is themselves that credited recipient.

## Accounting and assumptions

Every deposit measures the application's token balance before and after transfer and requires an exact increase. Every claim clears the caller's credit before transferring and requires both an exact application balance decrease and an exact recipient balance increase. OpenZeppelin `SafeERC20` checks transfer success, and a shared `ReentrancyGuard` protects both entry points. Any failure reverts the whole operation, including accounting, token movement, and allowance consumption.

Under ordinary USDC behavior:

```text
totalClaimable = sum of all claimable balances
USDC balance of application = totalClaimable + unsolicited surplus
total successful deposits = total successful claims + totalClaimable
```

The contract assumes the fixed token reports honest balances and retains normal, non-rebasing, exact-transfer USDC behavior. Its balance checks reject fee-on-transfer and no-op transfers; they cannot make an arbitrarily malicious token implementation safe.

The owner chooses allocations and supplies funds, but has no power to withdraw credited funds, pause claims, change the token, set fees, upgrade this application, or redirect a recipient's payment. Two-step ownership transfer uses [OpenZeppelin's acceptance mechanism](https://docs.openzeppelin.com/contracts/5.x/api/access#Ownable2Step).

USDC's issuer controls its own token. A pause or blocklist can prevent deposits or claims, and a token upgrade or issuer intervention can affect custody. Failed claims preserve their recorded balances and may be retried if the token restriction is removed. A blocked recipient does not block another recipient's claim when USDC otherwise permits it. If the application itself is blocked or USDC is globally paused, all affected transfers fail. The application offers no alternate payout address or administrative bypass.

Loss of a recipient's wallet access can make its funds permanently inaccessible. Loss of the owner's wallet access prevents new deposits or ownership handover, while existing claims remain available subject to USDC behavior. Directly transferred tokens, other assets, and forcibly delivered ETH have no recovery path. The owner must validate recipients and quantities before each deposit.

## Build and verification

The repository contains all Solidity dependencies as ordinary source files. No network, RPC, fork, keys, environment variables, FFI, filesystem cheatcodes, submodules, or dependency download are needed by the tests. Foundry and the pinned Solidity compiler must be available to the build runner.

```sh
forge build
forge test --fuzz-seed 0xa2c071871c58881ad877c4b5d9ce9b819ce7812c161bf29addcf2c2ff51ff457
forge fmt --check
```

The suite includes success and failure tests for funding, accumulated balances, isolated recipients, repeated claims, re-funding, approvals, ownership, missing token code, token failures, blocklisting, pausing, exact-transfer validation, and reentrancy in both directions. It also checks one-base-unit and `uint256` maximum amounts, deployment through a factory on an empty chain, runtime size, and forbidden runtime opcodes.

Two parameterized fuzz tests each run 1,000 cases. The stateful invariant suite runs 256 sequences of 64 operations against an independent accounting model. It mixes successful deposits and claims with donations, unauthorized deposits, blocked claims, and failed token transfers. After each sequence it claims every remaining credit and checks that only donations remain.

Tests install a mock at the fixed USDC address using `vm.etch`; they do not contact Ethereum or prove the behavior of a future USDC implementation. Deterministic test actors are fixtures, not deployment addresses. The supplied protected owner harness references a separate file that is not present in this assignment; the independent launch verifier runs that harness with its deployment inputs. Local tests separately exercise explicit factory ownership and the runtime requirements.

See `SECURITY.md` for the implementation review and release responsibilities. Independent adversarial review remains a release requirement for a contract holding other people's funds.

## Vendored dependencies

| Dependency | Pinned version | Included files |
| --- | --- | --- |
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.4.0) | `v5.4.0` | Required access control, guard, token utility, and interface source closure, plus MIT license |
| [forge-std](https://github.com/foundry-rs/forge-std/tree/v1.9.7) | `v1.9.7` | Test library source, MIT and Apache-2.0 licenses |

`lib/dependencies.json` records source archive URLs, archive SHA-256 hashes, and each vendored file's SHA-256 hash. Vendored source is unchanged. No build dependency points outside the repository.
