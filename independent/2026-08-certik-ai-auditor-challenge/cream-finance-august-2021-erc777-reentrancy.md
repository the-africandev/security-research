# [$18.8M] Cream Finance — cross-market reentrancy via an ERC-777 transfer hook

**Loss:** ~$18.8M &nbsp;·&nbsp; **Date:** 2021-08-30 &nbsp;·&nbsp; **Class:** Reentrancy (CEI violation)

| | |
|---|---|
| **Protocol** | Cream Finance — a Compound-v2 fork money market |
| **Chain** | Ethereum (block `13124942`) |
| **Exploit tx** | `0xd7ec3046ec75efbd04b3eea8752a8a6373a92c0dd813d08b655661054d3239c5` |
| **Vulnerable contract** | `CToken.borrowFresh` — crAMP implementation `0x3C710B981F5Ef28DA1807ce7ED3F2a28580E0754` |
| **Market proxy** | crAMP `0x2Db6c82CE72C8d7D770ba1b5F5Ed0b6E075066d6` (CErc20Delegator) |
| **Assets taken** | 462,079,976 AMP + 2,804.96 ETH |

---

## Summary

This is the **August 2021** Cream incident — a reentrancy bug — and it is a *separate event* from the far better-known **October 2021** Cream hack (~$130M, an oracle manipulation). Same protocol, different date, different root cause, different contract path.

Cream's cToken pays out borrowed tokens **before** it records the borrow. That ordering is normally survivable, because a plain ERC-20 transfer returns control immediately. AMP is not a plain ERC-20 — it is an **ERC-777**, and ERC-777 calls a `tokensReceived` hook on the recipient during the transfer.

So the borrower gets control of execution at the exact moment when the tokens have moved but the debt has not yet been booked. The attacker used that window to borrow *again* from a different market against collateral the protocol still believed was unencumbered.

---

## Root Cause

`CToken.borrowFresh` performs the external transfer at line 512, and only then writes the borrow accounting at lines 515–517:

```solidity
// CToken.sol — borrowFresh
doTransferOut(borrower, borrowAmount, isNative);          // L512  <-- external call, hands control to the borrower

accountBorrows[borrower].principal = vars.accountBorrowsNew;  // L515  <-- state written AFTER
accountBorrows[borrower].interestIndex = borrowIndex;
totalBorrows = vars.totalBorrowsNew;                          // L517
```

`doTransferOut` on the crAMP market transfers AMP. Because AMP implements ERC-777, that transfer invokes the attacker's `tokensReceived` hook while `accountBorrows` still reflects the *pre-borrow* state.

The reentrant call goes to a **different market** — crETH — so the usual per-market `nonReentrant` guard does not fire. The Comptroller's liquidity check for that second borrow reads collateral that has not yet been debited by the first.

### The full call chain

```
attacker → crAMP.borrow(AMP)
            └─ borrowFresh
                 ├─ doTransferOut(AMP)                     // L512
                 │    └─ AMP (ERC-777) → tokensReceived()  // attacker regains control
                 │         └─ crETH.borrow(ETH)            // liquidity check sees stale, un-debited collateral
                 └─ accountBorrows[...] = ...              // L515-517, too late
```

---

## Recovering the Pre-Incident Contract

crAMP is a `CErc20Delegator` proxy, and the implementation **was replaced after the incident** — reading the contract today returns patched code in which the effects precede `doTransferOut`. The vulnerable logic therefore had to be recovered by pinning the proxy to a pre-incident block:

```bash
cast call 0x2Db6c82CE72C8d7D770ba1b5F5Ed0b6E075066d6 \
  "implementation()(address)" \
  --block 13124941 \
  --rpc-url <archive-rpc>
# → 0x3C710B981F5Ef28DA1807ce7ED3F2a28580E0754
```

| | |
|---|---|
| Implementation at the incident | `0x3C710B981F5Ef28DA1807ce7ED3F2a28580E0754` |
| Implementation today (patched) | `0x96Cc0F947b6C8F4675159Ea03144f8c17d5A2fC8` |

The pre-incident implementation is verified on Sourcify (`exact_match`), which confirms the recovered source compiles to the bytecode that was actually live at block 13124942. Scanning the current implementation — or the project's GitHub HEAD — shows only the fixed ordering and proves nothing.

---

## Impact

The attacker borrowed against collateral that the protocol had already, in effect, lent out. Because the second borrow drew on a different market, the loss landed in crETH while the stale accounting sat in crAMP. Roughly $18.8M left the protocol across AMP and ETH.

---

## The Fix

Move the effects ahead of the interaction — the standard checks-effects-interactions ordering. Cream's current implementation writes `accountBorrows` and `totalBorrows` before calling `doTransferOut`.

A protocol-level mitigation is equally important: a Compound fork inherits an ERC-20 assumption that silently breaks the moment a market is opened for a token with transfer callbacks (ERC-777, ERC-677, or a bridged token that adds hooks).

---

## Generalizable Lesson

**A CEI violation is only latent until someone lists a token that gives the recipient control.** Compound-v2's ordering had been "safe" for years because every listed asset was a plain ERC-20; listing AMP converted a dormant ordering bug into a live cross-market reentrancy.

Two things follow for reviewers of any Compound/Aave fork:

1. Audit the *token-listing* surface as part of the reentrancy surface. "Which assets can be listed?" is a reentrancy question, not just a risk-parameter question.
2. Per-market `nonReentrant` guards do not stop **cross-market** reentrancy. The guard must span the shared state — the Comptroller's account liquidity — not just the individual market.

And for anyone reconstructing a historical incident: a protocol with a famous hack may well have a *second, quieter* one. Cream's October 2021 oracle hack is the one everyone remembers; this August reentrancy is a distinct incident that is routinely conflated with it.
