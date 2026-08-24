# [Critical] Spot/predict trades have no solvency gate — short-sell, withdraw the counterparty's collateral, leave the exchange insolvent

| | |
|---|---|
| **Protocol** | TipRun — perpetuals clearing (off-chain matching, on-chain custody) |
| **Engagement** | HackenProof (audit contest) |
| **Date** | 2026-06 · resolved 2026-08-08 |
| **Severity** | **Critical** (Business Logic Errors) |
| **Status** | **Resolved — fixed by the team** · reported by 65 researchers · report `TIPRUNC-179` |
| **Commit / Scope** | `tiprun-contracts @ d5d4d2a` — `BasicBalanceCheck.sol`, `PositionManager.sol`, `LimitOrderLib.sol` |
| **Report link** | HackenProof submission (private per program rules) |

---

## Summary

In the `spot` and `predict` deployment profiles there is no `CAP_MARGIN_CHECK` provider, so every
position transition routes through `NullMarginCheck` — a documented no-op. The only remaining
value-out gate is `BasicBalanceCheck.validateWithdrawal`, which measures **bucket-0 collateral
only** and is blind to a negative synthetic balance.

A trade can therefore drive a seller's synthetic balance negative — a naked short — while crediting
them the buyer's collateral, with nothing verifying the short is backed. The seller withdraws that
collateral (the gate passes: their *collateral* balance is positive), abandons the short, and the
exchange is left holding an unbacked liability it cannot honour.

This contradicts the protocol's own documentation: README §1 states the contracts "verify signatures,
**enforce solvency**, and update balances atomically," and CONFIG §2 states shares are "**fully
collateralized by the trade itself**."

## Vulnerability Details

A `Trade` matches a buyer (`isBuyingSynthetic = true`) against a seller. For the seller,
`LimitOrderLib.execute` computes:

```solidity
// isBuyingSynthetic == false (seller)
collateralDelta = actualCollateral - feeInt;   // real collateral in
syntheticDelta  = -actualSynthetic;            // synthetic goes NEGATIVE — a naked short
```

`updatePosition` then calls `_marginCheck().checkValidTransition(...)`. With no `CAP_MARGIN_CHECK`
provider registered, `_marginCheck()` resolves to `nullMarginCheck`, whose `checkValidTransition`
body is empty — **the uncollateralised short is accepted**.

The seller now holds `+actualCollateral` in bucket 0: real tokens the buyer paid in. On withdrawal:

```solidity
// BasicBalanceCheck.validateWithdrawal
require(positionManager.getCollateralBalanceByAccountId(accountId) >= amount, "...");
// getCollateralBalanceByAccountId returns bucket-0 collateral — it ignores the −synthetic short
```

The check passes and `LoadingZone.processWithdraw` releases the tokens. The short liability is never
reconciled against anything.

The same flawed measure is reachable through `TYPE_TRANSFER` (txType 6), which gates on the raw
`getCollateralBalanceByAccountId` rather than net account value — a second trigger with the same
root cause.

## Impact

**Theft of funds and protocol insolvency.** An attacker controlling two accounts (or two cooperating
users) manufactures a short→long trade and extracts real collateral that other users deposited,
having committed nothing of substance.

In the PoC the attacker removes **900 tokens it never deposited**, draining `systemBalance` from
1000 → 100, while an honest counterparty still holds a 999 redeemable claim. The exchange cannot
honour both — aggregate account collateral now exceeds the system balance, so later withdrawers
cannot be paid.

This affects both primary non-perp profiles, including the `predict` deployment that the README
presents as the headline use case.

## Proof of Concept

[`PoC/LC1_spot_short_withdraw_insolvency.t.sol`](PoC/LC1_spot_short_withdraw_insolvency.t.sol)

```bash
forge test --match-contract LC1SpotInsolvency -vv
```

```
B collateral after trade: 900
B synthetic after trade (short liability): -100
system token balance before: 1000
system token balance after: 100
tokens extracted by attacker (never deposited): 900
A redeemable claim (collateral + synthetic value): 999
system tokens remaining: 100
```

The insolvent state is reached and asserted: account B holds zero net value (no collateral after
withdrawal, plus a −100 synthetic short) yet has removed 900 real tokens from the system.

## Recommended Mitigation

The spot/predict balance check must measure **net account value including open synthetic
liabilities**, not bucket-0 collateral alone. Either:

- Have `validateWithdrawal` (and the `TYPE_TRANSFER` path) value open synthetic positions at a
  conservative or settlement price and refuse the withdrawal when net value < amount; or
- Forbid negative synthetic balances in profiles with no `CAP_MARGIN_CHECK` provider — reject any
  trade leg that would take a party's synthetic balance below zero without sufficient collateral,
  enforcing the documented "fully collateralized by the trade itself" invariant on-chain.

## Generalizable Lesson

**A no-op default is a security control that silently isn't there.** `NullMarginCheck` is documented
and intentional; the danger is that it is wired in by *absence* of configuration. Nothing in the
trade path looks unguarded — `_marginCheck().checkValidTransition(...)` reads exactly like a solvency
check. The gap only appears when you ask which implementation that call resolves to under each
deployment profile.

Two habits this rewards:

1. **Audit per deployment profile, not per repository.** A contract set that is safe under one
   configuration can be trivially insolvent under another. Enumerate the profiles and re-ask which
   providers are registered in each.
2. **When documentation promises an invariant, test the invariant, not the code path.** The README
   promised enforced solvency; the fastest way to the bug was to try to violate solvency and see
   what stopped it — rather than reading the margin-check code and assuming it ran.
