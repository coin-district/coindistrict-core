// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import 'forge-std/Test.sol';
import {ProtocolFixture, Protocol, Accounts} from './fixtures/ProtocolFixture.sol';
import {ShareTestUtils} from './utils/ShareTestUtils.sol';

import {Identity} from '@onchain-id/solidity/contracts/Identity.sol';
import {IIdentity} from '@onchain-id/solidity/contracts/interface/IIdentity.sol';

import {ClaimTopicsRegistry} from '@erc3643org/erc-3643/contracts/registry/implementation/ClaimTopicsRegistry.sol';
import {TrustedIssuersRegistry} from '@erc3643org/erc-3643/contracts/registry/implementation/TrustedIssuersRegistry.sol';
import {IdentityRegistry} from '@erc3643org/erc-3643/contracts/registry/implementation/IdentityRegistry.sol';
import {Token} from '@erc3643org/erc-3643/contracts/token/Token.sol';
import {MaxSupplyModule} from 'contracts/compliance/modules/MaxSupplyModule.sol';
import {SalesManager} from 'contracts/SalesManager.sol';
import {TokenController} from 'contracts/TokenController.sol';
import {Factory} from 'contracts/Factory.sol';

contract TokenControllerTest is Test, ProtocolFixture {
    using ShareTestUtils for Protocol;
    TokenController private tc = TokenController(address(0));

    uint64 private ADMIN_ROLE;
    uint64 private UPGRADER_ROLE;
    uint64 private SHARE_DEPLOYER_ROLE;
    uint64 private PAUSER_ROLE;
    uint64 private MINTER_ROLE;
    uint64 private BURNER_ROLE;
    uint64 private FREEZER_ROLE;
    uint64 private FORCE_ROLE;
    uint64 private RECOVERY_ROLE;

    address internal multisig = vm.addr(2);
    address internal identityRegistryAgent = vm.addr(3);
    address internal factoryShareDeployer = vm.addr(6);
    address internal tokenAgent = vm.addr(14);
    address internal userA = vm.addr(15);
    address internal userB = vm.addr(16);

    Accounts internal acc = defaultAccounts();
    Protocol internal p;

    function setUp() public {
        p = deployProtocol(acc);
        defaultRoleSetup(p, acc);
        addGlobalIrAgents(p, acc);

        tc = TokenController(address(p.tokenController));
        ADMIN_ROLE = p.governance.ADMIN_ROLE();
        UPGRADER_ROLE = p.governance.UPGRADER_ROLE();
        SHARE_DEPLOYER_ROLE = p.governance.SHARE_DEPLOYER_ROLE();
        PAUSER_ROLE = p.governance.PAUSER_ROLE();
        MINTER_ROLE = p.governance.MINTER_ROLE();
        BURNER_ROLE = p.governance.BURNER_ROLE();
        FREEZER_ROLE = p.governance.FREEZER_ROLE();
        FORCE_ROLE = p.governance.FORCE_ROLE();
        RECOVERY_ROLE = p.governance.RECOVERY_ROLE();

        multisig = acc.multisig;
        identityRegistryAgent = acc.identityRegistryAgent;
        factoryShareDeployer = acc.factoryShareDeployer;
        tokenAgent = acc.tokenAgent;
    }

    function test_capability_helpers() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, tokenAgent, identityRegistryAgent, 'CAPS', 'CAP', 1000);
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
        Token token = p.createShare(multisig, tokenAgent, identityRegistryAgent, 'DUAL', 'DUAL', 1000);
        uint256 caps = tc.PAUSABLE_BIT() | tc.MINTABLE_BIT();
        p.tokenController.setTokenCapsInitial(address(token), caps);
        vm.stopPrank();

        vm.prank(tokenAgent);
        p.tokenController.unpause(address(token));

        // grant MINTER_ROLE to userA

        vm.prank(multisig);
        p.accessManager.grantRole(MINTER_ROLE, userA, 0);

        // missing identity -> register
        p.registerIdentity(vm, identityRegistryAgent, userA);

        // role + cap -> success

        vm.prank(userA);
        p.tokenController.mint(address(token), userA, 100);
        assertEq(token.balanceOf(userA), 100);

        // remove role -> revert

        vm.prank(multisig);
        p.accessManager.revokeRole(MINTER_ROLE, userA);

        vm.prank(userA);
        vm.expectRevert(bytes('TokenController_NotAuthorized'));
        p.tokenController.mint(address(token), userA, 1);
    }

    function test_pause_unpause() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, tokenAgent, identityRegistryAgent, 'PAU', 'PAU', 1000);
        p.tokenController.setTokenCapsInitial(address(token), tc.PAUSABLE_BIT());
        vm.stopPrank();

        vm.prank(multisig);
        p.accessManager.grantRole(PAUSER_ROLE, tokenAgent, 0);

        vm.startPrank(tokenAgent);
        p.tokenController.unpause(address(token));
        assertFalse(token.paused());
        p.tokenController.pause(address(token));
        assertTrue(token.paused());
        vm.stopPrank();
    }

    function test_mint_burn() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, tokenAgent, identityRegistryAgent, 'MB', 'MB', 1000);
        p.tokenController.setTokenCapsInitial(address(token), tc.MINTABLE_BIT() | tc.BURNABLE_BIT());
        vm.stopPrank();

        vm.startPrank(multisig);
        p.accessManager.grantRole(MINTER_ROLE, tokenAgent, 0);
        p.accessManager.grantRole(BURNER_ROLE, tokenAgent, 0);
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
        Token token = p.createShare(multisig, tokenAgent, identityRegistryAgent, 'FR', 'FR', 1000);
        p.tokenController.setTokenCapsInitial(
            address(token),
            tc.PAUSABLE_BIT() | tc.FREEZABLE_BIT() | tc.MINTABLE_BIT()
        );
        vm.stopPrank();

        vm.startPrank(multisig);
        p.accessManager.grantRole(PAUSER_ROLE, tokenAgent, 0);
        p.accessManager.grantRole(FREEZER_ROLE, tokenAgent, 0);
        p.accessManager.grantRole(MINTER_ROLE, tokenAgent, 0);
        vm.stopPrank();

        p.registerIdentity(vm, identityRegistryAgent, userA);

        vm.startPrank(tokenAgent);
        p.tokenController.unpause(address(token));
        p.tokenController.mint(address(token), userA, 100);

        p.tokenController.setFrozen(address(token), userA, true);
        vm.stopPrank();

        vm.prank(userA);
        vm.expectRevert(); // wallet is frozen
        token.transfer(userB, 10);

        vm.startPrank(tokenAgent);
        p.tokenController.setFrozen(address(token), userA, false);
        vm.stopPrank();

        p.registerIdentity(vm, identityRegistryAgent, userB);

        vm.prank(userA);
        token.transfer(userB, 10);
        assertEq(token.balanceOf(userB), 10);
    }

    function test_forceTransfer_paused_token() public {
        vm.startPrank(factoryShareDeployer);
        Token token = p.createShare(multisig, tokenAgent, identityRegistryAgent, 'FT', 'FT', 1000);
        p.tokenController.setTokenCapsInitial(
            address(token),
            tc.PAUSABLE_BIT() | tc.MINTABLE_BIT() | tc.FORCE_TRANSFERABLE_BIT()
        );
        vm.stopPrank();
        vm.startPrank(multisig);
        p.accessManager.grantRole(PAUSER_ROLE, tokenAgent, 0);
        p.accessManager.grantRole(MINTER_ROLE, tokenAgent, 0);
        p.accessManager.grantRole(FORCE_ROLE, tokenAgent, 0);
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
        Token token = p.createShare(multisig, tokenAgent, identityRegistryAgent, 'RCV', 'RCV', 1000);
        p.tokenController.setTokenCapsInitial(
            address(token),
            tc.PAUSABLE_BIT() | tc.MINTABLE_BIT() | tc.RECOVERABLE_BIT()
        );
        vm.stopPrank();

        vm.prank(tokenAgent);
        p.tokenController.unpause(address(token));

        vm.startPrank(multisig);
        p.accessManager.grantRole(MINTER_ROLE, userA, 0);
        p.accessManager.grantRole(RECOVERY_ROLE, userA, 0);
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
        Token token = p.createShare(multisig, tokenAgent, identityRegistryAgent, 'CAPINIT', 'CINI', 1000);
        p.tokenController.setTokenCapsInitial(address(token), 0);
        vm.stopPrank();

        uint256 initializedBit = tc.INITIALIZED_BIT();
        uint256 mintableBit = tc.MINTABLE_BIT();

        uint256 stored = p.tokenController.capabilitiesByToken(address(token));
        assertEq(stored & initializedBit, initializedBit);
        assertFalse(p.tokenController.isMintable(address(token)));

        vm.startPrank(factoryShareDeployer);
        vm.expectRevert(bytes('TokenController_CapsAlreadySet'));
        p.tokenController.setTokenCapsInitial(address(token), mintableBit);
        vm.stopPrank();

        // After revert, caps should remain unchanged from the first call (only INITIALIZED_BIT set)
        uint256 updated = p.tokenController.capabilitiesByToken(address(token));
        assertEq(updated & initializedBit, initializedBit);
        assertEq(updated & mintableBit, 0);
    }

    function test_setTokenCaps_requires_initialized() public {
        vm.prank(factoryShareDeployer);
        Token token = p.createShare(multisig, tokenAgent, identityRegistryAgent, 'CAPUP', 'CAPUP', 1000);

        vm.startPrank(multisig);
        uint256 initializedBit = tc.INITIALIZED_BIT();
        uint256 mintableBit = tc.MINTABLE_BIT();
        vm.expectRevert(bytes('TokenController_CapsNotInitialized'));
        p.tokenController.setTokenCaps(address(token), mintableBit);
        vm.stopPrank();

        // After revert, state should not have changed - token should still not be initialized
        uint256 caps = p.tokenController.capabilitiesByToken(address(token));
        assertEq(caps & initializedBit, 0);
        assertEq(caps & mintableBit, 0);
    }
}
