// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {ProtocolFixture, Protocol, Accounts} from "./fixtures/ProtocolFixture.sol";
import {ShareTestUtils} from "./utils/ShareTestUtils.sol";
import {IIdentity} from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import {IModularCompliance} from "@erc3643org/erc-3643/contracts/compliance/modular/IModularCompliance.sol";
import {Token} from "@erc3643org/erc-3643/contracts/token/Token.sol";
import {Identity} from "@onchain-id/solidity/contracts/Identity.sol";
import {MaxSupplyModule} from "contracts/compliance/modules/MaxSupplyModule.sol";

contract MaxSupplyModuleTest is Test, ProtocolFixture {
    using ShareTestUtils for Protocol;

    Accounts internal acc = defaultAccounts();
    Protocol internal p;
    address internal multisig;
    address internal factoryShareDeployer;
    address internal tokenAgent;
    address internal identityRegistryAgent;

    function setUp() public {
        p = deployProtocol(acc);
        defaultRoleSetup(p, acc);
        addGlobalIrAgents(p, acc);

        multisig = acc.multisig;
        factoryShareDeployer = acc.factoryShareDeployer;
        tokenAgent = acc.tokenAgent;
        identityRegistryAgent = acc.identityRegistryAgent;
    }

    function _createShareWithMaxSupply(uint256 maxSupply)
        internal
        returns (Token token, address compliance, MaxSupplyModule module)
    {
        vm.prank(factoryShareDeployer);
        token = p.createShare(multisig, identityRegistryAgent, "MSM", "MSM", maxSupply);

        compliance = address(token.compliance());
        module = MaxSupplyModule(p.maxSupplyModule);
    }

    // ─── setMaxSupply ──────────────────────────────────────────────────────────

    function test_setMaxSupply_only_compliance() public {
        _createShareWithMaxSupply(1000);

        address attacker = address(0x999);
        vm.prank(attacker);
        vm.expectRevert(bytes("only bound compliance can call"));
        p.maxSupplyModule.setMaxSupply(500);
    }

    function test_setMaxSupply_rejects_below_current() public {
        (, address compliance, MaxSupplyModule module) = _createShareWithMaxSupply(1000);

        // Mint 100 via moduleMintAction
        vm.prank(compliance);
        module.moduleMintAction(address(0), 100);
        assertEq(module.getCurrentSupply(compliance), 100);

        // Try to set max supply below current
        vm.prank(compliance);
        vm.expectRevert(bytes("MaxSupplyModule: new max supply cannot be below current supply"));
        module.setMaxSupply(50);
    }

    function test_setMaxSupply_zero_means_uncapped() public {
        (, address compliance, MaxSupplyModule module) = _createShareWithMaxSupply(1000);

        vm.startPrank(compliance);
        module.setMaxSupply(0);

        // Mint past the original cap of 1000 to confirm zero means uncapped
        module.moduleMintAction(address(0), 1_500);
        vm.stopPrank();

        assertEq(module.getCurrentSupply(compliance), 1_500);
        assertTrue(module.moduleCheck(address(0), address(0), 10 ** 30, compliance));
    }

    function test_MaxSupplyModuleUpdateViaCompliance() public {
        (, address compliance, MaxSupplyModule module) = _createShareWithMaxSupply(1000);
        IModularCompliance mc = IModularCompliance(compliance);

        assertEq(module.getMaxSupply(compliance), 1000);

        vm.startPrank(multisig);

        bytes memory setCall = abi.encodeWithSignature("setMaxSupply(uint256)", 2000);
        mc.callModuleFunction(setCall, address(module));
        assertEq(module.getMaxSupply(compliance), 2000);

        bytes memory setZero = abi.encodeWithSignature("setMaxSupply(uint256)", 0);
        mc.callModuleFunction(setZero, address(module));
        assertEq(module.getMaxSupply(compliance), 0);

        vm.stopPrank();
    }

    function test_setMaxSupply_via_compliance_rejects_non_owner() public {
        (, address compliance, MaxSupplyModule module) = _createShareWithMaxSupply(1000);
        IModularCompliance mc = IModularCompliance(compliance);

        bytes memory setZero = abi.encodeWithSignature("setMaxSupply(uint256)", 0);
        vm.prank(address(0x999));
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        mc.callModuleFunction(setZero, address(module));

        assertEq(module.getMaxSupply(compliance), 1000);
    }

    function test_MaxSupplySetBelowCurrentReverts() public {
        (Token token, address compliance, MaxSupplyModule module) = _createShareWithMaxSupply(1000);
        IModularCompliance mc = IModularCompliance(compliance);

        uint256 caps =
            p.tokenController.PAUSABLE_BIT() | p.tokenController.MINTABLE_BIT() | p.tokenController.BURNABLE_BIT();
        vm.prank(factoryShareDeployer);
        p.tokenController.setTokenCapsInitial(address(token), caps);
        vm.prank(tokenAgent);
        p.tokenController.unpause(address(token));

        IIdentity buyerIdentity = IIdentity(address(new Identity(acc.buyer, false)));
        vm.prank(identityRegistryAgent);
        p.identityRegistry.registerIdentity(acc.buyer, buyerIdentity, 1);

        vm.startPrank(tokenAgent);
        p.tokenController.mint(address(token), acc.buyer, 600);
        assertEq(module.getCurrentSupply(compliance), 600);
        assertEq(module.getMaxSupply(compliance), 1000);

        p.tokenController.burn(address(token), acc.buyer, 250);
        assertEq(module.getCurrentSupply(compliance), 350);
        vm.stopPrank();

        bytes memory setTooLow = abi.encodeWithSignature("setMaxSupply(uint256)", 200);
        vm.prank(multisig);
        vm.expectRevert(bytes("MaxSupplyModule: new max supply cannot be below current supply"));
        mc.callModuleFunction(setTooLow, address(module));
    }

    // ─── moduleCheck ───────────────────────────────────────────────────────────

    function test_moduleCheck_returns_false_when_mint_exceeds_cap() public {
        (, address compliance, MaxSupplyModule module) = _createShareWithMaxSupply(100);

        vm.prank(compliance);
        module.moduleMintAction(address(0), 90);
        assertEq(module.getCurrentSupply(compliance), 90);

        // Check with value 20 where remaining cap is 10 → should return false
        // moduleCheck(from, to, value, compliance) — only blocks minting (from == address(0))
        assertFalse(module.moduleCheck(address(0), address(0), 20, compliance));
    }

    function test_moduleCheck_returns_true_for_non_mint() public {
        (, address compliance, MaxSupplyModule module) = _createShareWithMaxSupply(100);

        vm.prank(compliance);
        module.moduleMintAction(address(0), 90);

        // moduleCheck with from != address(0) means it's a transfer, not mint → always true
        assertTrue(module.moduleCheck(address(0x1), address(0x2), 1_000_000, compliance));
    }

    // ─── moduleMintAction / moduleBurnAction ───────────────────────────────────

    function test_moduleMintAction_increments_supply() public {
        (, address compliance, MaxSupplyModule module) = _createShareWithMaxSupply(1000);

        vm.prank(compliance);
        module.moduleMintAction(address(0), 50);

        assertEq(module.getCurrentSupply(compliance), 50);
    }

    function test_moduleBurnAction_decrements_supply() public {
        (, address compliance, MaxSupplyModule module) = _createShareWithMaxSupply(1000);

        vm.prank(compliance);
        module.moduleMintAction(address(0), 100);

        vm.prank(compliance);
        module.moduleBurnAction(address(0), 30);

        assertEq(module.getCurrentSupply(compliance), 70);
    }

    function test_moduleBurnAction_underflow_reverts() public {
        (, address compliance, MaxSupplyModule module) = _createShareWithMaxSupply(1000);

        vm.prank(compliance);
        module.moduleMintAction(address(0), 10);

        vm.prank(compliance);
        vm.expectRevert(stdError.arithmeticError);
        module.moduleBurnAction(address(0), 20);
        assertEq(module.getCurrentSupply(compliance), 10);
    }

    function test_moduleCheck_returns_false_after_accounted_supply_reaches_cap() public {
        (, address compliance, MaxSupplyModule module) = _createShareWithMaxSupply(100);
        vm.startPrank(compliance);
        module.moduleMintAction(address(0), 100);
        vm.stopPrank();
        assertFalse(module.moduleCheck(address(0), address(0), 1, compliance));
        assertEq(module.getCurrentSupply(compliance), 100);
    }

    function test_module_actions_restore_supply_after_burn_and_remint() public {
        (, address compliance, MaxSupplyModule module) = _createShareWithMaxSupply(100);
        vm.startPrank(compliance);
        module.moduleMintAction(address(0), 100);
        module.moduleBurnAction(address(0), 40);
        module.moduleMintAction(address(0), 40);
        vm.stopPrank();
        assertEq(module.getCurrentSupply(compliance), 100);
    }

    function test_transfer_does_not_change_current_supply() public {
        (, address compliance, MaxSupplyModule module) = _createShareWithMaxSupply(1000);
        vm.prank(compliance);
        module.moduleMintAction(address(0), 100);
        assertTrue(module.moduleCheck(address(0x1), address(0x2), 50, compliance));
        assertEq(module.getCurrentSupply(compliance), 100);
    }

    function test_forceTransfer_does_not_change_current_supply() public {
        (, address compliance, MaxSupplyModule module) = _createShareWithMaxSupply(1000);
        vm.startPrank(compliance);
        module.moduleMintAction(address(0), 100);
        module.moduleTransferAction(address(0x1), address(0x2), 50);
        vm.stopPrank();
        assertEq(module.getCurrentSupply(compliance), 100);
    }

    // ─── static metadata ───────────────────────────────────────────────────────

    function test_static_metadata() public view {
        assertEq(p.maxSupplyModule.name(), "MaxSupplyModule");
        assertTrue(p.maxSupplyModule.isPlugAndPlay());
        assertTrue(p.maxSupplyModule.canComplianceBind(address(0)));
    }
}
