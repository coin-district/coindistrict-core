// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import {Test} from "forge-std/Test.sol";
import {ProtocolFixture, Protocol, Accounts} from "./fixtures/ProtocolFixture.sol";
import {ShareTestUtils} from "./utils/ShareTestUtils.sol";
import {TokenController} from "contracts/TokenController.sol";
import {IClaimIssuer} from "@onchain-id/solidity/contracts/interface/IClaimIssuer.sol";
import {IIdentity} from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import {ClaimTopicsRegistry} from "@erc3643org/erc-3643/contracts/registry/implementation/ClaimTopicsRegistry.sol";
import {
    TrustedIssuersRegistry
} from "@erc3643org/erc-3643/contracts/registry/implementation/TrustedIssuersRegistry.sol";
import {IdentityRegistry} from "@erc3643org/erc-3643/contracts/registry/implementation/IdentityRegistry.sol";
import {Token} from "@erc3643org/erc-3643/contracts/token/Token.sol";
import {TokenController} from "contracts/TokenController.sol";

contract SecondaryTest is Test, ProtocolFixture {
    using ShareTestUtils for Protocol;
    uint256 constant DEFAULT_MAX_SUPPLY = 1000;

    // accounts
    address internal multisig = vm.addr(2);
    address internal identityRegistryAgent = vm.addr(3);
    address internal identityRegistryAgent2 = vm.addr(4);
    address internal claimIssuer = vm.addr(5);
    address internal factoryShareDeployer = vm.addr(6);
    address internal tokenAgent = vm.addr(14);
    address internal buyer = vm.addr(11);
    address internal user1 = vm.addr(12);
    address internal user2 = vm.addr(13);

    Accounts internal acc = defaultAccounts();
    Protocol internal p;

    function setUp() public {
        p = deployProtocol(acc);
        defaultRoleSetup(p, acc);
        addGlobalIrAgents(p, acc);

        multisig = acc.multisig;
        identityRegistryAgent = acc.identityRegistryAgent;
        identityRegistryAgent2 = acc.identityRegistryAgent2;
        claimIssuer = acc.claimIssuer;
        factoryShareDeployer = acc.factoryShareDeployer;
        tokenAgent = acc.tokenAgent;
        buyer = acc.buyer;
        user1 = acc.user1;
        user2 = acc.user2;
    }

    function test_open_token_transfer_and_transferFrom() public {
        vm.prank(factoryShareDeployer);
        Token token = p.createShare(multisig, tokenAgent, identityRegistryAgent, "OPEN", "OPN", DEFAULT_MAX_SUPPLY);
        _unpauseAndMint(token, buyer, 50);

        p.registerIdentity(vm, identityRegistryAgent, user1);

        vm.startPrank(buyer);
        require(token.transfer(user1, 20), "Transfer failed");
        assertEq(token.balanceOf(buyer), 30);
        assertEq(token.balanceOf(user1), 20);

        token.approve(user1, 10);
        vm.stopPrank();

        vm.prank(user1);
        require(token.transferFrom(buyer, user1, 10), "TransferFrom failed");
        assertEq(token.balanceOf(buyer), 20);
        assertEq(token.balanceOf(user1), 30);
    }

    function test_permissioned_token_requires_KYC_for_recipient() public {
        uint256 kycTopic = 7;
        vm.prank(factoryShareDeployer);
        Token token = p.createShare(multisig, tokenAgent, identityRegistryAgent, "PERM", "PRM", DEFAULT_MAX_SUPPLY);
        // Mint first before adding KYC requirements
        _unpauseAndMint(token, buyer, 40);

        // Now add claim topic and trusted issuer to token-specific IR registries (owned by multisig)
        IdentityRegistry ir = IdentityRegistry(address(token.identityRegistry()));
        ClaimTopicsRegistry ctr = ClaimTopicsRegistry(address(ir.topicsRegistry()));
        TrustedIssuersRegistry tir = TrustedIssuersRegistry(address(ir.issuersRegistry()));
        vm.startPrank(multisig);
        ctr.addClaimTopic(kycTopic);
        tir.addTrustedIssuer(IClaimIssuer(address(p.claimIssuer)), _singleUint(kycTopic));
        vm.stopPrank();

        // user1 without KYC should fail
        p.registerIdentity(vm, identityRegistryAgent, user1);
        vm.prank(buyer);
        try token.transfer(user1, 5) returns (bool ok) {
            assertFalse(ok);
            fail("Expected transfer to revert");
        } catch Error(string memory reason) {
            assertEq(reason, "Transfer not possible");
        } catch {
            fail("Unexpected revert");
        }

        // add claim to user1 identity using a ClaimIssuer signature
        IdentityRegistry irRegistry = IdentityRegistry(address(token.identityRegistry()));
        IIdentity userIdentity = irRegistry.identity(user1);

        // grant claim signer key to user1 (so they can add their claim)
        vm.prank(user1);
        userIdentity.addKey(keccak256(abi.encode(user1)), 3, 1);

        // ensure claim issuer has a claim signing key
        vm.prank(claimIssuer);
        IClaimIssuer(address(p.claimIssuer)).addKey(keccak256(abi.encode(claimIssuer)), 3, 1);

        bytes memory claimData = hex"0042";
        bytes32 dataHash = keccak256(abi.encode(address(userIdentity), kycTopic, claimData));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", dataHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(5, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(user1);
        userIdentity.addClaim(kycTopic, 1, address(p.claimIssuer), signature, claimData, "");

        vm.prank(buyer);
        require(token.transfer(user1, 5), "Transfer failed");
        assertEq(token.balanceOf(user1), 5);
    }

    function test_freeze_blocks_transfers() public {
        vm.prank(factoryShareDeployer);
        Token token = p.createShare(multisig, tokenAgent, identityRegistryAgent, "FRZ", "FRZ", DEFAULT_MAX_SUPPLY);
        _unpauseAndMint(token, user1, 100);

        vm.prank(tokenAgent);
        p.tokenController.setFrozen(address(token), user1, true);

        vm.prank(user1);
        try token.transfer(user2, 10) returns (bool ok) {
            assertFalse(ok);
            fail("Expected transfer to revert");
        } catch Error(string memory reason) {
            assertEq(reason, "wallet is frozen");
        } catch {
            fail("Unexpected revert");
        }

        p.registerIdentity(vm, identityRegistryAgent, user2);

        vm.prank(user1);
        try token.transfer(user2, 1) returns (bool ok) {
            assertFalse(ok);
            fail("Expected transfer to revert");
        } catch Error(string memory reason) {
            assertEq(reason, "wallet is frozen");
        } catch {
            fail("Unexpected revert");
        }

        vm.prank(tokenAgent);
        p.tokenController.setFrozen(address(token), user1, false);

        vm.prank(user1);
        require(token.transfer(user2, 10), "Transfer failed");
        assertEq(token.balanceOf(user2), 10);
    }

    function _unpauseAndMint(Token token, address to, uint256 amount) internal {
        TokenController tc = TokenController(address(p.tokenController));
        uint256 caps = tc.PAUSABLE_BIT() | tc.MINTABLE_BIT() | tc.FREEZABLE_BIT();
        vm.prank(factoryShareDeployer);
        p.tokenController.setTokenCapsInitial(address(token), caps);

        vm.prank(tokenAgent);
        p.tokenController.unpause(address(token));

        p.registerIdentity(vm, identityRegistryAgent, to);

        vm.prank(tokenAgent);
        p.tokenController.mint(address(token), to, amount);
    }

    function _addClaim(
        Token token,
        address,
        /*wallet*/
        uint256 topic
    )
        internal
    {
        // In real system, use ClaimIssuer and signature; here we simulate by bypassing to token-specific registries (owned by multisig)
        IdentityRegistry ir = IdentityRegistry(address(token.identityRegistry()));
        ClaimTopicsRegistry ctr = ClaimTopicsRegistry(address(ir.topicsRegistry()));
        TrustedIssuersRegistry tir = TrustedIssuersRegistry(address(ir.issuersRegistry()));
        vm.startPrank(multisig);
        ctr.addClaimTopic(topic);
        tir.addTrustedIssuer(IClaimIssuer(address(p.claimIssuer)), _singleUint(topic));
        vm.stopPrank();
        // no-op identity claim attach in this minimal port (Token's IR checks issuer + topic through ClaimIssuer)
    }

    function _singleUint(uint256 v) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = v;
    }
}
