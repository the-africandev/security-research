# [High] Any user can self-mint `ALLOW_ADMIN` and rewrite permissions on any account — full account takeover

| | |
|---|---|
| **Protocol** | TipRun — perpetuals clearing (off-chain matching, on-chain custody) |
| **Engagement** | HackenProof (audit contest) |
| **Date** | 2026-06 · triaged 2026-08-07 |
| **Severity** | Accepted Critical, then **re-scored High** — see *Triage note* below |
| **Status** | **Resolved — fixed by the team** · reported by 61 researchers |
| **Commit / Scope** | `tiprun-contracts @ d5d4d2a` — `PermissionsTransLib.sol`, `SignerManager.sol`, `RegisterAccountTransLib.sol` |
| **Report link** | HackenProof submission (private per program rules) |

---

## Summary

`processAdminSetSignerPermissions` authorises an admin operation by checking that the recovered
signer holds `ALLOW_ADMIN` **on whatever `adminAccountId` the caller placed in the signed struct**.
It never checks that this account is the protocol's genuine, designated admin.

Because a user can attach `ALLOW_ADMIN` to a session key on their own freshly-registered account,
an unprivileged attacker can nominate *themselves* as the admin account, pass the check, and then
set arbitrary permissions on **any** account — granting themselves withdrawal rights over a
victim, or writing `ALLOW_ADMIN` onto the real admin account to join the global admin set
permanently.

## Vulnerability Details

Two defects chain into full takeover.

### Defect 1 — `ALLOW_ADMIN` is self-mintable at registration

`SignerManager.addSignerWithPermissions` forces a safe mask **only when the signer is the account
owner** (a non-admin account's owner receives `FULL_PERMISSIONS` minus `ALLOW_ADMIN`). For a
*non-owner* session signer it stores the caller-supplied mask verbatim — the code comment states
that "ALLOW_ADMIN is grantable like any other bit (the original `_restrictAdminBit` rule was
removed)."

So a user registering their own account (`TYPE_REGISTER_ACCOUNT`) can attach an initial session
signer whose mask includes `ALLOW_ADMIN`, on an account that is not the admin account.

### Defect 2 — the admin operation trusts a caller-supplied admin account

`src/core/signer/transactions/PermissionsTransLib.sol`

```solidity
function processAdminSetSignerPermissions(AdminSetSignerPermissionsTx memory txData, ...) public {
    ...
    bytes32 messageHash = getAdminSetSignerPermissionsHash(txData, block.chainid, verifyingContract);
    address recovered   = SignaturesLib.recoverSigner(messageHash, txData.signature);

    // Checks ALLOW_ADMIN on the *caller-supplied* adminAccountId —
    // never that adminAccountId == signerManager.adminAccountId().
    require(
        signerManager.checkSignerPermissionsAndNonce(
            txData.adminAccountId, recovered, txData.nonce, SignerPermissions.ALLOW_ADMIN
        ), ...
    );

    signerManager.setSignerPermissions(txData.targetAccountId, txData.signer, txData.mask);
}
```

`txData.adminAccountId` comes straight from the signed struct. The only guard is
`require(adminAccountId != 0)`. `checkSignerPermissionsAndNonce` verifies only
`signerPermissions[accountId][signer] & ALLOW_ADMIN` — not that the account *is* the designated
admin — and the processor-only `setSignerPermissions` then writes any mask to any target with no
admin-bit guard (also explicitly removed).

Binding `adminAccountId` into the EIP-712 hash proves nothing here: the attacker signs the message
themselves, so the field is bound to *their own* message, not to any authority.

### Why the chain works

The `SignerManager` design (docstring, `SignerManager.sol:28-34`) assumes `ALLOW_ADMIN` exists only
on the designated admin account, and that admin power flows outward from there. Defect 1 falsifies
that assumption; defect 2 fails to enforce it. Either alone is survivable — together they are a
complete break of the permission model.

## Impact

Reachable by any unprivileged user in every deployment profile — the `AccountPlugin` that dispatches
this transaction type is always registered.

- **Theft of any user's at-rest funds** — grant an attacker key `ALLOW_WITHDRAW` on a victim account
  and withdraw their full collateral.
- **Permanent protocol-wide admin takeover** — set `targetAccountId = adminAccountId`,
  `mask = ALLOW_ADMIN`, joining the real admin set.
- **Arbitrary order, transfer and margin control** over every account.

The attacker commits none of their own capital; a victim need only have deposited.

## Proof of Concept

[`PoC/AC1_admin_escalation.t.sol`](PoC/AC1_admin_escalation.t.sol)

```bash
forge test --match-contract AC1AdminEscalation -vv
```

Registers a victim (deposits 1000), then an attacker whose initial session key carries `ALLOW_ADMIN`.
The attacker sends an `AdminSetSignerPermissions` with `adminAccountId` set to their own account
(uid 3, where the genuine admin is uid 1), granting themselves `ALLOW_WITHDRAW` on the victim, and
withdraws everything.

Result: `[PASS]` — the attacker EOA receives the victim's entire 1000-token deposit; the victim
account is drained to zero.

## Recommended Mitigation

Bind the check to the genuine designated admin account:

```solidity
require(txData.adminAccountId == signerManager.adminAccountId(), "not the admin account");
```

Better still, drop the caller-supplied field entirely and read `signerManager.adminAccountId()`
directly — a value the caller cannot influence. Pair this with rejecting self-minted `ALLOW_ADMIN`
at registration, so the privilege cannot be created in the first place.

## Triage note — why this landed High, not Critical

Triage accepted this as Critical on 2026-07-03, then re-scored it to High on 2026-07-13 with a
reason that is not visible in the contract source:

> "the account-registration path is guarded by an off-chain validation layer that rejects any
> attempt by a non-admin to assign the admin permission before it reaches the on-chain flow.
> Because of that gate, the takeover is not reachable by an ordinary external or registered user."

The contract-level flaw was confirmed and fixed; the deployed system had a compensating control in
front of it. Recording this because it is the more useful lesson: a source-only review correctly
identifies the defect but cannot see the operational gate, and severity depends on both.

## Generalizable Lesson

**An identifier that the caller supplies cannot authenticate the caller.** Signing a field into an
EIP-712 struct binds it to the *message*, not to any authority — and it is a common source of false
confidence, because the field *looks* validated. The check here reads as an authorisation check and
performs like one; it simply asks the wrong account whether the caller is an admin.

The general form: whenever a permission check takes an account/role identifier as a parameter, ask
where that parameter comes from. If it is attacker-controlled, the check is decorative.
