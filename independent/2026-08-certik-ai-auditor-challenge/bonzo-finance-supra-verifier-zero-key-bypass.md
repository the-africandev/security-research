# [$9.05M] Bonzo Finance / Supra — oracle verifier accepts a zeroed BLS signature

**Loss:** ~$9.05M &nbsp;·&nbsp; **Date:** 2026-07-11 &nbsp;·&nbsp; **Class:** Missing input validation (signature verification bypass)

| | |
|---|---|
| **Protocol** | Bonzo Lend (Hedera's flagship lending market) — via its oracle provider, Supra |
| **Chain** | Hedera (chain id `295`), exploit block `97504674` |
| **Vulnerable contract** | `SupraSValueFeedVerifier.requireHashVerified_V2` |
| **Implementation** | `0x63e0A27bc77cA817c89f5231d568C4E58100FBf0` (pre-incident) |
| **Verifier proxy** | `0x2fa6dbfe4291136cf272e1a3294362b6651e8517` (Hedera `0.0.4323006`) |
| **Impact** | Attacker wrote an arbitrary price on-chain and borrowed ~$9.05M against ~$3 of collateral |

---

## Summary

Bonzo Lend's own code was correct. It read a SAUCE price from its oracle and computed collateral exactly as designed. The defect sat **one layer up**, inside the Supra verifier contract that authenticates price updates before they are written.

That verifier checks a BLS signature against a committee public key looked up by `committee_id`. It never checks that the looked-up key — or the signature itself — is non-zero. For an out-of-range or uninitialized `committee_id`, the lookup returns an all-zero key, and the BLS pairing check degenerates into a trivially true comparison.

An attacker submitted a price update carrying a **zeroed signature and a zeroed public key**, the verifier accepted it as genuine, a manipulated SAUCE/wHBAR price landed on-chain, and seconds later ~250 SAUCE (about $3) was posted as collateral to borrow roughly $9.05M.

---

## Root Cause

`requireHashVerified_V2` passes the committee key straight into `BLS.verifySingle` with no validation of either input:

```solidity
function requireHashVerified_V2(bytes32 _message, uint256[2] calldata _signature, uint256 committee_id)
    public
    view
{
    bool callSuccess;
    bool checkSuccess;
    (checkSuccess, callSuccess) = BLS.verifySingle(
        _signature,                                  // <-- never checked non-zero
        committee_public_key[committee_id],          // <-- never checked non-zero / in-range
        BLS.hashToPoint(domain, abi.encode(_message)),
        blsPrecompileGasCost
    );
    if (!callSuccess) { revert BLSInvalidPublicKeyorSignaturePoints(); }
    if (!checkSuccess) { revert BLSIncorrectInputMessaage(); }
}
```

`committee_public_key` is a `mapping(uint256 => uint256[4])`. Solidity returns the zero value for any unset key, so an out-of-range `committee_id` yields `[0,0,0,0]` rather than reverting. With a zero public key and a zero signature, the pairing product on both sides is the identity element — the check passes.

The contract even carries a comment acknowledging the gap in a neighbouring function:

```solidity
/// @dev WARN: The validity of the public key is not verified
function updatePublicKey(uint256 committee_id, uint256[4] memory _publicKey, bool new_committee) public onlyOwner {
```

---

## The Attack

1. Submit a price update for the SAUCE/wHBAR pair with `signature = [0, 0]` and a `committee_id` outside the initialised range.
2. The verifier resolves an all-zero committee key, `BLS.verifySingle` returns success, and the manipulated price is written on-chain.
3. Deposit ~250 SAUCE (≈$3) into Bonzo Lend.
4. Borrow against it at the inflated valuation — ~$9.05M drawn within seconds of the price write.

A second wallet drew roughly $1M more while the bad price persisted, later self-identifying as a white hat and returning funds.

---

## Recovering the Pre-Incident Contract

The verifier is behind a proxy and was hotfixed roughly six hours after the exploit, so the currently-deployed implementation contains the guards that were missing. The vulnerable implementation was recovered by reading the proxy's implementation slot at the exploit block:

```
proxy 0x2fa6dbfe4291136cf272e1a3294362b6651e8517  @ block 97504674
  → implementation 0x63e0A27bc77cA817c89f5231d568C4E58100FBf0   (Sourcify-verified, chain 295)
```

Confirming it is the pre-incident version is straightforward: grep the recovered source for any non-zero guard on the signature points or the committee key. There are none. The hotfix implementation adds exactly those two checks — which is the cleanest possible evidence of what the root cause was.

---

## The Fix

Reject the identity element on both inputs before verifying:

```solidity
require(_signature[0] != 0 || _signature[1] != 0, "zero signature");
uint256[4] memory pk = committee_public_key[committee_id];
require(pk[0] != 0 || pk[1] != 0 || pk[2] != 0 || pk[3] != 0, "unset committee key");
```

More robustly, treat an unregistered `committee_id` as a hard revert rather than relying on a mapping's zero value to be caught downstream.

---

## Generalizable Lesson

**In pairing-based cryptography, the identity element satisfies almost every equation you care about.** A BLS verifier that does not explicitly reject zero points is not verifying anything when handed zeros — `e(0, H(m)) == e(0, g)` holds trivially. The same trap appears in ECDSA (`ecrecover` returning `address(0)` on malformed input) and in Merkle proofs (an empty root matching an unproven leaf).

Two auditing rules fall out of this:

1. **A Solidity mapping's zero value is attacker-reachable input.** Any `mapping(uint => Key)` lookup keyed on caller-supplied data must validate the *result*, not just the index; there is no "not found" branch to catch.
2. **A verifier's trust boundary is a consumer's blind spot.** Bonzo had no bug — it faithfully consumed a price its oracle certified as valid. When reviewing a protocol that depends on an external verifier, the verifier's input validation is part of your attack surface even though it is not part of your codebase.
