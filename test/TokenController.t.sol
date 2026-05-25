// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import {Test} from "forge-std/Test.sol";
import {ProtocolFixture, Protocol, Accounts, RoleIds} from "./fixtures/ProtocolFixture.sol";
import {ShareTestUtils} from "./utils/ShareTestUtils.sol";
import {Identity} from "@onchain-id/solidity/contracts/Identity.sol";
import {Token} from "@erc3643org/erc-3643/contracts/token/Token.sol";
import {TokenController} from "contracts/TokenController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract TokenControllerTest is Test, ProtocolFixture {
    using ShareTestUtils for Protocol;
    TokenController private tc = TokenController(address(0));

    // Local event mirror (Solidity 0.8.17 does not support emit Interface.Event() syntax)
    event TokenCapabilitiesSet(address indexed token, uint256 caps);

    uint64 private adminRole;
    uint64 private upgraderRole;
    uint64 private shareDeployerRole;
    uint64 private pauserRole;
    uint64 private minterRole;
    uint64 private burnerRole;
    uint64 private freezerRole;
    uint64 private forceRole;
    uint64 private recoveryRole;

    address internal multisig;
    address internal identityRegistryAgent;
    address internal factoryShareDeployer;
    address internal tokenAgent;
    address internal userA = vm.addr(15);
    address internal userB = vm.addr(16);

    Accounts internal acc = defaultAccounts();
    Protocol internal p;

    function setUp() public {
        p = deployProtocol(acc);
        defaultRoleSetup(p, acc);
        addGlobalIrAgents(p, acc);

        tc = TokenController(address(p.tokenController));
        RoleIds memory roles = _loadRoleIds();
        adminRole = roles.admin;
        upgraderRole = roles.upgrader;
        shareDeployerRole = roles.shareDeployer;
        pauserRole = roles.pauser;
        minterRole = roles.minter;
        burnerRole = roles.burner;
        freezerRole = roles.freezer;
        forceRole = roles.force;
        recoveryRole = roles.recovery;

        multisig = acc.multisig;
        identityRegistryAgent = acc.identityRegistryAgent;
        factoryShareDeployer = acc.factoryShareDeployer;
        tokenAgent = acc.tokenAgent;
    }

    function test_capability_helpers() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "CAPS", "CAP", 1000);
        uint256 caps = tc.MINTABLE_BIT() | tc.BURNABLE_BIT();
        p.tokenController.setTokenCapsInitial(address(token), caps);
        vm.stopPrank();

        assertTrue(p.tokenController.isMintable(address(token)));
        assertTrue(p.tokenController.isBurnable(address(token)));
        assertFalse(p.tokenController.isPausable(address(token)));
        assertFalse(p.tokenController.isFreezable(address(token)));
        assertFalse(p.tokenController.isForceTransferable(address(token)));
        assertFalse(p.tokenController.isRecoverable(address(token)));
    }

    function test_requires_role_and_capability() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "DUAL", "DUAL", 1000);
        uint256 caps = tc.PAUSABLE_BIT() | tc.MINTABLE_BIT();
        p.tokenController.setTokenCapsInitial(address(token), caps);
        vm.stopPrank();

        vm.prank(tokenAgent);
        p.tokenController.unpause(address(token));

        // grant MINTER_ROLE to userA

        vm.prank(multisig);
        p.accessManager.grantRole(minterRole, userA, 0);

        // missing identity -> register
        p.registerIdentity(vm, identityRegistryAgent, userA);

        // role + cap -> success

        vm.prank(userA);
        p.tokenController.mint(address(token), userA, 100);
        assertEq(token.balanceOf(userA), 100);

        // remove role -> revert

        vm.prank(multisig);
        p.accessManager.revokeRole(minterRole, userA);

        vm.prank(userA);
        vm.expectRevert(bytes("TokenController_NotAuthorized"));
        p.tokenController.mint(address(token), userA, 1);
    }

    function test_tokenAgent_cannot_configure_capabilities() public {
        vm.prank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "CFG", "CFG", 1000);
        uint256 pausableBit = tc.PAUSABLE_BIT();
        uint256 mintableBit = tc.MINTABLE_BIT();

        vm.prank(tokenAgent);
        vm.expectRevert(bytes("TokenController_NotAuthorized"));
        p.tokenController.setTokenCapsInitial(address(token), pausableBit);

        vm.prank(factoryShareDeployer);
        p.tokenController.setTokenCapsInitial(address(token), pausableBit);

        vm.prank(tokenAgent);
        vm.expectRevert(bytes("TokenController_NotAuthorized"));
        p.tokenController.setTokenCaps(address(token), mintableBit);
    }

    function test_shareDeployer_cannot_use_enabled_operational_capabilities() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "OPS", "OPS", 1000);
        uint256 caps = tc.PAUSABLE_BIT() | tc.BURNABLE_BIT() | tc.FORCE_TRANSFERABLE_BIT() | tc.RECOVERABLE_BIT();
        p.tokenController.setTokenCapsInitial(address(token), caps);

        vm.expectRevert(bytes("TokenController_NotAuthorized"));
        p.tokenController.pause(address(token));
        vm.expectRevert(bytes("TokenController_NotAuthorized"));
        p.tokenController.unpause(address(token));
        vm.expectRevert(bytes("TokenController_NotAuthorized"));
        p.tokenController.burn(address(token), userA, 1);
        vm.expectRevert(bytes("TokenController_NotAuthorized"));
        p.tokenController.forceTransfer(address(token), userA, userB, 1);
        vm.expectRevert(bytes("TokenController_NotAuthorized"));
        p.tokenController.recover(address(token), userA, userB, address(0));
        vm.stopPrank();
    }

    function test_pause_unpause() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "PAU", "PAU", 1000);
        p.tokenController.setTokenCapsInitial(address(token), tc.PAUSABLE_BIT());
        vm.stopPrank();

        vm.prank(multisig);
        p.accessManager.grantRole(pauserRole, tokenAgent, 0);

        vm.startPrank(tokenAgent);
        p.tokenController.unpause(address(token));
        assertFalse(token.paused());
        p.tokenController.pause(address(token));
        assertTrue(token.paused());
        vm.stopPrank();
    }

    function test_mint_burn() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "MB", "MB", 1000);
        p.tokenController.setTokenCapsInitial(address(token), tc.MINTABLE_BIT() | tc.BURNABLE_BIT());
        vm.stopPrank();

        vm.startPrank(multisig);
        p.accessManager.grantRole(minterRole, tokenAgent, 0);
        p.accessManager.grantRole(burnerRole, tokenAgent, 0);
        vm.stopPrank();

        p.registerIdentity(vm, identityRegistryAgent, userA);

        vm.startPrank(tokenAgent);
        p.tokenController.mint(address(token), userA, 200);
        assertEq(token.balanceOf(userA), 200);

        p.tokenController.burn(address(token), userA, 50);
        assertEq(token.balanceOf(userA), 150);
        vm.stopPrank();
    }

    function test_freeze_unfreeze() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "FR", "FR", 1000);
        p.tokenController
            .setTokenCapsInitial(address(token), tc.PAUSABLE_BIT() | tc.FREEZABLE_BIT() | tc.MINTABLE_BIT());
        vm.stopPrank();

        vm.startPrank(multisig);
        p.accessManager.grantRole(pauserRole, tokenAgent, 0);
        p.accessManager.grantRole(freezerRole, tokenAgent, 0);
        p.accessManager.grantRole(minterRole, tokenAgent, 0);
        vm.stopPrank();

        p.registerIdentity(vm, identityRegistryAgent, userA);

        vm.startPrank(tokenAgent);
        p.tokenController.unpause(address(token));
        p.tokenController.mint(address(token), userA, 100);

        p.tokenController.setFrozen(address(token), userA, true);
        vm.stopPrank();

        vm.prank(userA);
        vm.expectRevert(bytes("wallet is frozen"));
        token.transfer(userB, 10);

        vm.startPrank(tokenAgent);
        p.tokenController.setFrozen(address(token), userA, false);
        vm.stopPrank();

        p.registerIdentity(vm, identityRegistryAgent, userB);

        vm.prank(userA);
        require(token.transfer(userB, 10), "Transfer failed");
        assertEq(token.balanceOf(userB), 10);
    }

    function test_forceTransfer_paused_token() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "FT", "FT", 1000);
        p.tokenController
            .setTokenCapsInitial(address(token), tc.PAUSABLE_BIT() | tc.MINTABLE_BIT() | tc.FORCE_TRANSFERABLE_BIT());
        vm.stopPrank();
        vm.startPrank(multisig);
        p.accessManager.grantRole(pauserRole, tokenAgent, 0);
        p.accessManager.grantRole(minterRole, tokenAgent, 0);
        p.accessManager.grantRole(forceRole, tokenAgent, 0);
        vm.stopPrank();

        p.registerIdentity(vm, identityRegistryAgent, userA);
        p.registerIdentity(vm, identityRegistryAgent, userB);

        vm.startPrank(tokenAgent);
        p.tokenController.unpause(address(token));
        p.tokenController.mint(address(token), userA, 100);
        p.tokenController.pause(address(token));

        p.tokenController.forceTransfer(address(token), userA, userB, 40);
        assertEq(token.balanceOf(userB), 40);
        vm.stopPrank();
    }

    function test_recover_moves_balance() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "RCV", "RCV", 1000);
        p.tokenController
            .setTokenCapsInitial(address(token), tc.PAUSABLE_BIT() | tc.MINTABLE_BIT() | tc.RECOVERABLE_BIT());
        vm.stopPrank();

        vm.prank(tokenAgent);
        p.tokenController.unpause(address(token));

        vm.startPrank(multisig);
        p.accessManager.grantRole(minterRole, userA, 0);
        p.accessManager.grantRole(recoveryRole, userA, 0);
        vm.stopPrank();

        p.registerIdentity(vm, identityRegistryAgent, userB); // lost wallet
        // Don't register userA yet - it will be registered during recovery

        vm.startPrank(userA);
        p.tokenController.mint(address(token), userB, 77); // mint to lost wallet

        Identity newIdentity = new Identity(userA, false);
        p.tokenController.recover(address(token), userB, userA, address(newIdentity));
        vm.stopPrank();

        assertEq(token.balanceOf(userB), 0);
        assertEq(token.balanceOf(userA), 77);
    }

    function test_setTokenCapsInitial_only_once_and_sets_initialized_bit() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "CAPINIT", "CINI", 1000);
        p.tokenController.setTokenCapsInitial(address(token), 0);
        vm.stopPrank();

        uint256 initializedBit = tc.INITIALIZED_BIT();
        uint256 mintableBit = tc.MINTABLE_BIT();

        uint256 stored = p.tokenController.capabilitiesByToken(address(token));
        assertEq(stored & initializedBit, initializedBit);
        assertFalse(p.tokenController.isMintable(address(token)));

        vm.startPrank(factoryShareDeployer);
        vm.expectRevert(bytes("TokenController_CapsAlreadySet"));
        p.tokenController.setTokenCapsInitial(address(token), mintableBit);
        vm.stopPrank();

        // After revert, caps should remain unchanged from the first call (only INITIALIZED_BIT set)
        uint256 updated = p.tokenController.capabilitiesByToken(address(token));
        assertEq(updated & initializedBit, initializedBit);
        assertEq(updated & mintableBit, 0);
    }

    function test_setTokenCaps_requires_initialized() public {
        vm.prank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "CAPUP", "CAPUP", 1000);

        vm.startPrank(multisig);
        uint256 initializedBit = tc.INITIALIZED_BIT();
        uint256 mintableBit = tc.MINTABLE_BIT();
        vm.expectRevert(bytes("TokenController_CapsNotInitialized"));
        p.tokenController.setTokenCaps(address(token), mintableBit);
        vm.stopPrank();

        // After revert, state should not have changed - token should still not be initialized
        uint256 caps = p.tokenController.capabilitiesByToken(address(token));
        assertEq(caps & initializedBit, 0);
        assertEq(caps & mintableBit, 0);
    }

    // ─── setTokenCaps happy path ──────────────────────────────────────────────

    function test_setTokenCaps_updates_capabilities() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "CapUpd", "SCU", 1000);
        p.tokenController.setTokenCapsInitial(address(token), tc.MINTABLE_BIT());
        vm.stopPrank();

        assertTrue(p.tokenController.isMintable(address(token)));
        assertFalse(p.tokenController.isBurnable(address(token)));

        uint256 burnableBit = tc.BURNABLE_BIT();
        uint256 expectedCaps = burnableBit | tc.INITIALIZED_BIT();
        vm.expectEmit(true, false, false, true);
        emit TokenCapabilitiesSet(address(token), expectedCaps);
        vm.prank(multisig);
        p.tokenController.setTokenCaps(address(token), burnableBit);

        assertFalse(p.tokenController.isMintable(address(token)));
        assertTrue(p.tokenController.isBurnable(address(token)));
        assertTrue((p.tokenController.capabilitiesByToken(address(token)) & tc.INITIALIZED_BIT()) != 0);
    }

    function test_event_TokenCapabilitiesSet_emitted() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "TCapEvt", "TCS", 1000);

        uint256 expectedCaps = tc.MINTABLE_BIT() | tc.INITIALIZED_BIT();
        vm.expectEmit(true, false, false, true);
        emit TokenCapabilitiesSet(address(token), expectedCaps);
        p.tokenController.setTokenCapsInitial(address(token), tc.MINTABLE_BIT());
        vm.stopPrank();
    }

    // ─── disabled-capability reverts ──────────────────────────────────────────

    function test_pause_disabled_capability_reverts() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "PauseDisabled", "PD", 1000);
        p.tokenController.setTokenCapsInitial(address(token), 0);
        vm.stopPrank();

        vm.prank(tokenAgent);
        vm.expectRevert(bytes("pause capability disabled"));
        p.tokenController.pause(address(token));
    }

    function test_unpause_disabled_capability_reverts() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "UnpauseDisabled", "UD", 1000);
        p.tokenController.setTokenCapsInitial(address(token), 0);
        vm.stopPrank();

        vm.prank(tokenAgent);
        vm.expectRevert(bytes("pause capability disabled"));
        p.tokenController.unpause(address(token));
    }

    function test_mint_disabled_capability_reverts() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "MintDisabled", "MD", 1000);
        p.tokenController.setTokenCapsInitial(address(token), 0);
        vm.stopPrank();

        vm.prank(tokenAgent);
        vm.expectRevert(bytes("mint capability disabled"));
        p.tokenController.mint(address(token), userA, 1);
    }

    function test_burn_disabled_capability_reverts() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "BurnDisabled", "BD", 1000);
        p.tokenController.setTokenCapsInitial(address(token), 0);
        vm.stopPrank();

        vm.prank(tokenAgent);
        vm.expectRevert(bytes("burn capability disabled"));
        p.tokenController.burn(address(token), userA, 1);
    }

    function test_forceTransfer_disabled_capability_reverts() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "ForceTransferDisabled", "FTD", 1000);
        p.tokenController.setTokenCapsInitial(address(token), 0);
        vm.stopPrank();

        vm.prank(tokenAgent);
        vm.expectRevert(bytes("force transfer capability disabled"));
        p.tokenController.forceTransfer(address(token), userA, userB, 1);
    }

    function test_setFrozen_disabled_capability_reverts() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "FreezeDisabled", "SFD", 1000);
        p.tokenController.setTokenCapsInitial(address(token), 0);
        vm.stopPrank();

        vm.prank(tokenAgent);
        vm.expectRevert(bytes("freeze capability disabled"));
        p.tokenController.setFrozen(address(token), userA, true);
    }

    function test_recover_disabled_capability_reverts() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "RecoverDisabled", "RD", 1000);
        p.tokenController.setTokenCapsInitial(address(token), 0);
        vm.stopPrank();

        vm.prank(tokenAgent);
        vm.expectRevert(bytes("recover capability disabled"));
        p.tokenController.recover(address(token), userA, userB, address(0));
    }

    // ─── G3: Upgrade authorization ──────────────────────────────────────────────

    function test_TokenController_UpgradeRequiresRole() public {
        address attacker = vm.addr(77);
        TokenController newImpl = new TokenController();
        vm.prank(attacker);
        vm.expectRevert(bytes("TokenController_NotAuthorized"));
        p.tokenController.upgradeTo(address(newImpl));
    }

    function test_TokenController_UpgradeWithRolePreservesState() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "TCUpgr", "TCU", 1000);
        uint256 mintableBit = tc.MINTABLE_BIT();
        p.tokenController.setTokenCapsInitial(address(token), mintableBit);
        vm.stopPrank();

        uint256 before = p.tokenController.capabilitiesByToken(address(token));

        TokenController newImpl = new TokenController();
        vm.prank(multisig);
        p.tokenController.upgradeTo(address(newImpl));

        uint256 capsAfter = p.tokenController.capabilitiesByToken(address(token));
        assertEq(before, capsAfter);
    }

    function test_TokenController_implementation_disables_initializers() public {
        TokenController impl = new TokenController();
        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        impl.initialize(address(0x123));
    }

    // ─── G4: Initialize hardening ──────────────────────────────────────────────

    function test_TokenController_initialize_rejects_zero_governance() public {
        TokenController impl = new TokenController();
        TokenController proxy = TokenController(address(new ERC1967Proxy(address(impl), "")));
        vm.expectRevert(bytes("TokenController_InvalidGovernance"));
        proxy.initialize(address(0));
    }

    function test_TokenController_initialize_reverts_on_double_init() public {
        TokenController impl = new TokenController();
        TokenController proxy = TokenController(address(new ERC1967Proxy(address(impl), "")));
        proxy.initialize(address(0x123));
        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        proxy.initialize(address(0x456));
    }

    // ─── G6: TokenController edge cases ────────────────────────────────────────

    // G6.1 setTokenCaps with caps = 0

    function test_setTokenCaps_zero_clears_caps_preserves_initialized() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "CapZero", "CPZ", 1000);
        uint256 allCaps = tc.MINTABLE_BIT() | tc.BURNABLE_BIT() | tc.PAUSABLE_BIT();
        p.tokenController.setTokenCapsInitial(address(token), allCaps);
        vm.stopPrank();

        assertTrue(p.tokenController.isMintable(address(token)));
        assertTrue(p.tokenController.isPausable(address(token)));

        vm.prank(multisig);
        p.tokenController.setTokenCaps(address(token), 0);

        uint256 stored = p.tokenController.capabilitiesByToken(address(token));
        assertEq(stored & tc.INITIALIZED_BIT(), tc.INITIALIZED_BIT());
        assertFalse(p.tokenController.isMintable(address(token)));
        assertFalse(p.tokenController.isBurnable(address(token)));
        assertFalse(p.tokenController.isPausable(address(token)));
    }

    // G6.2 Unregistered token

    function test_pause_with_default_zero_caps_reverts() public {
        address fakeToken = address(0xDEAD);
        vm.prank(tokenAgent);
        vm.expectRevert(bytes("pause capability disabled"));
        p.tokenController.pause(fakeToken);
    }
}
