# [$25.5M] Thala Labs — `unstake` pays out an unvalidated amount

**Loss:** ~$25.5M &nbsp;·&nbsp; **Date:** 2024-11-15 &nbsp;·&nbsp; **Class:** Missing input validation (value-flow asymmetry)

| | |
|---|---|
| **Protocol** | Thala Labs — ThalaSwap v1 boosted farming |
| **Chain** | Aptos (Move), exploit 2024-11-15 |
| **Vulnerable module** | `farming::unstake`, entry via `scripts::unstake` |
| **Package** | `0x6b3720cd988adeaf721ed9d4730da4324d52364871a68eac62b46d21e4d2fa99` |
| **Introduced by** | A two-line patch to boosted farming on 2024-11-01 that skipped review |
| **Outcome** | Funds fully returned by the attacker for a $300K bounty |

---

## Summary

`unstake` computes two amounts that ought to be the same number. It clamps the requested amount to the caller's actual staked balance — but uses that clamped value **only for the internal reward bookkeeping**. The tokens actually paid out use the raw, caller-supplied amount, with no check that it is bounded by what the caller staked.

Because every user's LP sits in one shared resource account, asking to unstake far more than you deposited pays out of everyone else's balance.

---

## Root Cause

From the recovered pre-incident module (variable names are the decompiler's; the control flow and calls are exact):

```move
public fun unstake<T0>(arg0: &signer, arg1: u64, arg2: u64)
    : (Coin<T0>, Coin<THL>) acquires ... {
    // arg1 = pool id, arg2 = amount the caller asks to unstake
    ...
    let v6 = /* the caller's UserPoolInfo — their real staked position */;

    // (A) REWARD ACCOUNTING — correctly clamped to the real stake
    let v7 = 0x1::math64::min(get_boosted_amount(arg2, v4), v6.amount);
    unstake_internal(&mut pool, &mut v6, v7, ...);   // does user.amount -= v7, underflow-safe

    // (B) ACTUAL PAYOUT — the RAW, unvalidated arg2
    (0x1::coin::withdraw<T0>(&resource_signer, arg2), v10)
}
```

Line (A) computes `min(requested, staked)` and spends it on bookkeeping. Line (B) transfers `arg2`. There is **no `assert!(arg2 <= v6.amount)` anywhere on the path.**

Every other guard in the function is present and correct — the position is initialised, `arg2 > 0`, the staker exists, the pool index and coin type are valid. None of them bounds the withdrawn amount to the caller's stake.

### The attack

1. Stake a token to create a `UserPoolInfo`, then fully unstake so the recorded balance is ~0.
2. Call `unstake(pool_id, arg2)` with a large `arg2`. The clamp in (A) resolves to ~0 and does nothing harmful; the payout in (B) hands over `arg2` LP tokens from the shared resource account.
3. Repeat across the MOD/USDC, MOD/THL and THAPT/APT pools.

---

## Recovering the Pre-Incident Contract

This is the part that made the incident difficult to analyse, and it is worth spelling out.

- **Aptos publishes bytecode, not source.** Querying `0x1::code::PackageRegistry` for this package returns an empty `source` field — the source was stripped at publish time.
- **It is not on GitHub.** Thala's public repos contain math libraries and integration starters, not the farming contract. Every third-party analysis of this hack was written from decompiled bytecode, which is why they all use decompiler names like `arg2`.
- **The deployed bytecode is already patched**, so decompiling the current module yields the fixed version.

The recovery path:

```bash
# 1. Pin a ledger version inside the vulnerable window (after the Nov-1 patch, before the Nov-15 exploit)
#    Binary-search /v1/transactions/by_version/{v} timestamps → 1913527058 == 2024-11-11 23:59 UTC

# 2. Pull the module bytecode at that version — the public fullnode is fully archival
curl "https://fullnode.mainnet.aptoslabs.com/v1/accounts/0x6b3720cd.../module/farming?ledger_version=1913527058"

# 3. Decompile
revela -b thala_farming_nov11.mv        # Verichains Revela v1.0.0
```

The retrieved bytecode differs from today's deployed module, confirming it is genuinely the pre-patch code. A useful sanity check: the *current* patched module is a newer bytecode version that Revela v1.0.0 rejects outright — so a clean decompile is itself evidence you are holding the old one.

> **Address note for reproducers:** the vulnerable module is the **ThalaSwap v1 boosted-farming** package at `0x6b3720cd988adeaf721ed9d4730da4324d52364871a68eac62b46d21e4d2fa99`. A different Thala address (`0x6f986d…`, the MOD/CDP stablecoin protocol) also exposes a `farming` module, but it is an unrelated rewards helper with no `unstake` — an easy wrong turn.

---

## The Fix

One assertion on the payout path:

```move
assert!(arg2 <= v6.amount, E_INSUFFICIENT_STAKE);
```

Equivalently, use the already-computed clamped value for the withdrawal instead of the raw input — the two amounts should never have diverged.

---

## Generalizable Lesson

**When a function computes a safe value and then uses a different, unsafe value for the actual transfer, that divergence is the bug.** The `min()` on line (A) is what makes this so easy to miss in review: a reader scanning for "is the amount clamped?" finds a clamp, sees it applied, and moves on. The clamp is real — it is just wired to the wrong consumer.

Two habits catch this class:

1. Trace the value that *moves funds*, not the value that looks validated. In any withdraw/redeem/settle path, follow the argument passed to the transfer call back to its guard — and confirm it is the *same variable* that the guard constrained.
2. Treat "small, obviously-safe patch" as a risk marker. This bug shipped in a two-line change that bypassed review precisely because it looked trivial, and it was exploited fourteen days later.

Finally: **"source unavailable" is not "unanalysable."** On Aptos and Sui, published packages are immutable and versioned, and full archival nodes serve historical bytecode by ledger version. Bytecode at the right version plus a decompiler reconstructs the exact pre-incident contract even when the team stripped the source and never open-sourced it.
