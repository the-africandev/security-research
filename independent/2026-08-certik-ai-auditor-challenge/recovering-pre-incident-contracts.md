# Recovering the Pre-Incident Contract

**Notes on reconstructing the exact code that was live when a protocol was exploited.**

Analysing a historical hack sounds like a reading exercise until you try it. The contract you can read today is almost never the contract that was exploited: protocols patch within hours, proxies get re-pointed, repositories are reverted, explorers shut down, and some chains never publish source at all. Everything below came out of reconstructing ~25 incidents across EVM, Solana and Move.

The single rule: **verify that what you are reading is what was running.** An analysis of the patched version proves nothing.

---

## 1. EVM — resolve the implementation *at the incident block*

For any proxy, read the implementation slot pinned to a block before the exploit. Reading `latest` gives you the fix.

```bash
# EIP-1967
cast storage <proxy> 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc \
  --block <incident_block - 1> --rpc-url <archive-rpc>

# Compound-style delegator / non-1967 proxies expose a getter instead
cast call <proxy> "implementation()(address)" --block <incident_block - 1> --rpc-url <archive-rpc>
```

Then compare against `latest`. If they differ, you have positive confirmation the contract was upgraded after the incident — and that the address you just resolved is the one to analyse.

**Free archive RPCs that answer historical calls:** `eth.merkle.io`, `eth.drpc.org`, `rpc.mevblocker.io`. Most "public" endpoints (publicnode, ankr-free, llamarpc) refuse archive reads or silently return `latest`, which is worse than refusing.

**Traps:**
- **Not every proxy is EIP-1967.** Compound forks use a `implementation()` getter; some projects use a bespoke slot (one used `keccak256("IMPLEMENTATION_ADDRESS")+1`). If the 1967 slot reads zero, the contract is either immutable or using a custom layout — check the bytecode for a `implementation()` selector before concluding.
- **The famous address is often the wrong one.** In one case the address every write-up cites had *no code at all* at the incident block; it was a later redeployment. Always confirm `eth_getCode` is non-empty at the block you care about.
- **Libraries are not in the proxy.** A `delegatecall`-linked library (Solidity `library` linking) lives at its own address and is resolved at deploy time, not through a proxy slot. Recover it from the deployment artifacts or the linked address in the bytecode.

## 2. EVM — getting the source once you have the address

In rough order of preference:

1. **Sourcify v2** — `GET https://sourcify.dev/server/v2/contract/<chainId>/<addr>?fields=sources`. Returns every source unit as JSON with a `creationMatch` / `runtimeMatch` field. An `exact_match` is proof the source compiles to the deployed bytecode.
2. **The block explorer's verified source**, when Sourcify has no record.
3. **A verified-source mirror**, when the explorer itself is gone. Fantom's ftmscan was decommissioned after the Sonic rebrand; `tintinweb/smart-contract-sanctuary-fantom` is a scrape of what was verified there and preserved contracts that are otherwise unreachable.
4. **The project's own repository at the parent of the fix commit** — see §3.
5. **Decompilation** — see §4.

## 3. Git — the parent of the fix commit

When a project is open-source but the deployed contract was patched, the pre-incident code is usually one commit away:

```bash
git log --oneline -- path/to/Vulnerable.sol       # find the fix
git checkout <fix_commit>^                        # its parent == deployed-at-incident
```

Confirm by grepping for the guard the fix introduced. If it is absent, you are holding the vulnerable version. This is the fastest recovery path that exists — and it is how most Solana/Anchor incidents are best reconstructed, since Anchor programs are rarely verified on-chain but frequently open-source.

Two cautions: a repository's default branch may have been *reverted* after the incident (so HEAD no longer contains the vulnerable function at all), and a repo created *after* the hack date is a rewrite, not the original.

## 4. Move (Aptos / Sui) — archival bytecode plus a decompiler

Aptos and Sui publish bytecode; publishing source is optional and frequently skipped. When it is skipped and there is no repository, decompilation is the only path — and it works.

```bash
# Aptos: the public fullnode is fully archival (oldest_ledger_version: 0)
# 1. Pin a ledger version inside the vulnerable window by binary-searching timestamps
curl "https://fullnode.mainnet.aptoslabs.com/v1/transactions/by_version/<v>" | jq .timestamp

# 2. Fetch the module at that version
curl "https://fullnode.mainnet.aptoslabs.com/v1/accounts/<addr>/module/<name>?ledger_version=<v>"

# 3. Decompile
revela -b module.mv        # Verichains Revela
```

Sui equivalents: packages are immutable and versioned, so a package ID pins a version permanently; modules are retrievable via `sui_getObject` (`showBcs`, `moduleMap`) and disassembled with `sui move disassemble`.

**Quality matters, and it varies.** Revela produced clean, typed Move with intact signatures and call graphs — good enough that a scanner found the bug unaided. `sui move disassemble` produces bytecode IR, which is far less useful for anything that needs to read like source. Judge the output before you rely on it.

**A useful accident:** if the *current* module is a newer bytecode version that your decompiler rejects while the historical one decompiles cleanly, that mismatch is itself evidence you are holding the pre-patch code.

## 5. Non-starters — know when to stop

Not every incident is recoverable, and recognising that early saves real effort:

- **The bug is not in a contract.** Several large "hacks" were root-caused to off-chain infrastructure: a Go precompile in a node client, a Rust validator's event parser, an oracle reporter bot. There is no on-chain artifact to analyse.
- **The source is genuinely private and the bytecode is not tractably decompilable.** Solana SBF is the main example; several well-known Solana incidents have no public repository and no verified build.
- **The root cause is a key compromise, a rug, or a frontend swap.** No amount of source recovery produces a code defect, because there isn't one.

---

## Checklist

Before analysing a single line, confirm:

- [ ] The exact incident block / ledger version / slot
- [ ] Whether the target is a proxy, and if so the implementation **at that block**
- [ ] That the implementation differs from `latest` (or that the contract is provably immutable)
- [ ] That the recovered source matches the deployed bytecode (`exact_match`, or a decompile of the historical bytecode)
- [ ] That the guard added by the fix is **absent** from what you are reading

The last item is the strongest single check available: if you can point at the line the patch introduced and show it is missing from your copy, you have proved you are looking at the vulnerable version.
