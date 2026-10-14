# Deposit and claim tests

The existing unit tests and invariant handler remain intact. These additions exercise
ownership transitions and funding constraints alongside the existing token-failure
and reentrancy coverage.

## Additional coverage

`USDCDepositClaim.adversarial.t.sol` adds three properties, each with 1,000 fuzz runs:

- An arbitrary valid recipient exclusively receives its allocation and cannot claim twice.
- Two deposits can sum to `uint256.max`, for either one or two recipients; all credits
  can be claimed, and the emptied escrow can be reused without increasing token supply.
- An allowance shortfall on a top-up preserves existing credit, cash, and allowance
  despite a surplus donation. Correcting the allowance permits an exact payout.

Deterministic cases pin the arithmetic boundaries, verify that a new owner cannot
spend a former owner's funds or allowance, distinguish `msg.sender` from `tx.origin`
through a relay, and retry a deposit whose reentrant callback reverted. Both prior
credit and the token allowance must survive the failed callback.

`USDCDepositClaim.ownership.invariant.t.sol` adds a separate handler with four actors
who may each become owner, receive allocations, claim, and donate. Token supply is
minted once during setup. Four initial allocations ensure claims and failed payouts
have funded positions to exercise from the start.

The runner executes 256 sequences of 96 calls, mixing deposits, claims, donations,
ownership nominations/replacements/cancellations, acceptance, unauthorized calls,
and deliberately failed deposits and claims. Failures include missing allowance,
insufficient cash, zero amounts, false-returning/no-op/short token transfers,
pausing, and blocklisting. Expected failures use exact revert data; unexpected
handler reverts fail the suite. Only the nine action selectors are fuzz targets.

The independent model records allocations, payouts, funding spent, donations, and
accepted ownership changes from action inputs. After every call it checks:

| Property | Expected relation |
| --- | --- |
| Recipient entitlement | Each credit equals that wallet's allocations minus payouts |
| Wallet cash | Initial balance plus payouts minus funding spent and donations |
| Total liability | Sum of the four individual unpaid allocations |
| Escrow backing | Unpaid allocations plus unsolicited donations |
| Conservation | All four wallets plus escrow retain the fixed total supply |
| Authority | Current and pending owner agree with nominations and valid acceptances |

After each random sequence, all recipients claim their remaining allocations without
owner intervention or fresh funding. The escrow must retain only donations. Two
deterministic handler tests also exercise every fault mode, former/pending-owner
rejection, replacement/cancellation/self-acceptance, and owner balance exhaustion.

## Reproduce offline

```sh
forge build --offline --out test/scratch/out --cache-path test/scratch/cache
FOUNDRY_FUZZ_SEED=0xa2c071871c58881ad877c4b5d9ce9b819ce7812c161bf29addcf2c2ff51ff457 \
  forge test --offline --out test/scratch/out --cache-path test/scratch/cache
```

No additional dependencies, forks, network requests, environment-reading cheatcodes,
or `vm.setEnv` are used. Scratch contains only disposable build output. Run counts
for the added suites are set inline in their Solidity files.

The tests install the existing mock token at the specified USDC address. This tests
application behavior under controlled exact transfers and injected failures; it does
not validate live USDC state or future issuer changes. The maximum-supply cases are
arithmetic stress tests. Test wallets are local fixtures, not deployment settings.
No implementation defect was reproduced by these tests.
