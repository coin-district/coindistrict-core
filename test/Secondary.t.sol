// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import {SecondaryTestHelpers} from "./utils/SecondaryTestHelpers.sol";
import {ShareTestUtils} from "./utils/ShareTestUtils.sol";
import {Protocol} from "./fixtures/ProtocolFixture.sol";
import {TokenController} from "contracts/TokenController.sol";
import {IClaimIssuer} from "@onchain-id/solidity/contracts/interface/IClaimIssuer.sol";
import {IIdentity} from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import {ClaimTopicsRegistry} from "@erc3643org/erc-3643/contracts/registry/implementation/ClaimTopicsRegistry.sol";
import {
    TrustedIssuersRegistry
} from "@erc3643org/erc-3643/contracts/registry/implementation/TrustedIssuersRegistry.sol";
import {IdentityRegistry} from "@erc3643org/erc-3643/contracts/registry/implementation/IdentityRegistry.sol";
import {Token} from "@erc3643org/erc-3643/contracts/token/Token.sol";

contract SecondaryTest is SecondaryTestHelpers {
    using ShareTestUtils for Protocol;

    // Transfers and recipient verification

    function test_open_token_transfer_and_transferFrom() public {
        vm.prank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "OPEN", "OPN", DEFAULT_MAX_SUPPLY);
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
        Token token = p.createShare(multisig, identityRegistryAgent, "PERM", "PRM", DEFAULT_MAX_SUPPLY);
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
        vm.expectRevert(bytes("Transfer not possible"));
        token.transfer(user1, 5);

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

    function test_compliance_blocks_transfer_to_non_KYC() public {
        vm.prank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "CTK", "CTK", DEFAULT_MAX_SUPPLY);
        _unpauseAndMint(token, user1, 50);
        // user2 is NOT registered in IR

        vm.prank(user1);
        vm.expectRevert(bytes("Transfer not possible"));
        token.transfer(user2, 10);
        assertEq(token.balanceOf(user2), 0);
    }

    // ERC-3643 transfer() checks isVerified(_to) only — sender KYC is not required

    function test_sender_without_KYC_can_send() public {
        uint256 kycTopic = 7;
        vm.prank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "SND", "SND", DEFAULT_MAX_SUPPLY);
        _unpauseAndMint(token, buyer, 40);
        _addClaimTopicAndTrustedIssuer(token, kycTopic);

        p.registerIdentity(vm, identityRegistryAgent, user1);
        _grantKycClaim(token, user1, kycTopic);

        // buyer (sender) has no KYC claim; transfer succeeds because only recipient is checked
        vm.prank(buyer);
        require(token.transfer(user1, 5), "Transfer failed");
        assertEq(token.balanceOf(user1), 5);
        assertEq(token.balanceOf(buyer), 35);
    }

    function test_permissioned_transferFrom_requires_recipient_KYC() public {
        uint256 kycTopic = 7;
        vm.prank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "TFP", "TFP", DEFAULT_MAX_SUPPLY);
        _unpauseAndMint(token, buyer, 40);
        _addClaimTopicAndTrustedIssuer(token, kycTopic);
        _grantKycClaim(token, buyer, kycTopic);

        vm.prank(buyer);
        token.approve(user1, 10);

        p.registerIdentity(vm, identityRegistryAgent, user2);

        vm.prank(user1);
        vm.expectRevert(bytes("Transfer not possible"));
        token.transferFrom(buyer, user2, 10);

        _grantKycClaim(token, user2, kycTopic);

        vm.prank(user1);
        require(token.transferFrom(buyer, user2, 10), "TransferFrom failed");
        assertEq(token.balanceOf(buyer), 30);
        assertEq(token.balanceOf(user2), 10);
    }

    function test_claim_removal_reblocks_transfer() public {
        uint256 kycTopic = 7;
        vm.prank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "REV", "REV", DEFAULT_MAX_SUPPLY);
        _unpauseAndMint(token, buyer, 40);
        _addClaimTopicAndTrustedIssuer(token, kycTopic);
        _grantKycClaim(token, buyer, kycTopic);

        p.registerIdentity(vm, identityRegistryAgent, user1);
        _grantKycClaim(token, user1, kycTopic);

        vm.prank(buyer);
        require(token.transfer(user1, 5), "Transfer failed");
        assertEq(token.balanceOf(user1), 5);

        IdentityRegistry irRegistry = IdentityRegistry(address(token.identityRegistry()));
        IIdentity userIdentity = irRegistry.identity(user1);
        bytes32 claimId = keccak256(abi.encode(address(p.claimIssuer), kycTopic));
        vm.prank(user1);
        userIdentity.removeClaim(claimId);

        vm.prank(buyer);
        vm.expectRevert(bytes("Transfer not possible"));
        token.transfer(user1, 5);
    }

    // claim present but issuer absent from token's TrustedIssuersRegistry → isVerified returns false

    function test_claim_from_untrusted_issuer_rejected() public {
        uint256 kycTopic = 7;
        vm.prank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "UTI", "UTI", DEFAULT_MAX_SUPPLY);
        _unpauseAndMint(token, buyer, 40);
        _addClaimTopicOnly(token, kycTopic);

        p.registerIdentity(vm, identityRegistryAgent, user1);
        _grantKycClaim(token, user1, kycTopic); // claim present, but issuer is NOT trusted for this token

        vm.prank(buyer);
        vm.expectRevert(bytes("Transfer not possible"));
        token.transfer(user1, 10);
    }

    function test_paused_token_blocks_transfer() public {
        vm.prank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "PAU", "PAU", DEFAULT_MAX_SUPPLY);
        _unpauseAndMint(token, user1, 50);
        p.registerIdentity(vm, identityRegistryAgent, user2);

        vm.prank(tokenAgent);
        p.tokenController.pause(address(token));

        vm.prank(user1);
        vm.expectRevert(bytes("Pausable: paused"));
        token.transfer(user2, 10);

        vm.prank(tokenAgent);
        p.tokenController.unpause(address(token));

        vm.prank(user1);
        require(token.transfer(user2, 10), "Transfer failed");
        assertEq(token.balanceOf(user2), 10);
        assertEq(token.balanceOf(user1), 40);
    }

    // Forced transfers

    function test_forceTransfer_between_non_KYC_parties_succeeds() public {
        vm.prank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "FTF", "FTF", DEFAULT_MAX_SUPPLY);

        TokenController tc = TokenController(address(p.tokenController));
        uint256 caps = tc.PAUSABLE_BIT() | tc.MINTABLE_BIT() | tc.FREEZABLE_BIT() | tc.FORCE_TRANSFERABLE_BIT();
        vm.prank(factoryShareDeployer);
        p.tokenController.setTokenCapsInitial(address(token), caps);

        vm.prank(tokenAgent);
        p.tokenController.unpause(address(token));

        p.registerIdentity(vm, identityRegistryAgent, user1);
        p.registerIdentity(vm, identityRegistryAgent, user2);

        vm.prank(tokenAgent);
        p.tokenController.mint(address(token), user1, 50);

        // freeze user1 so normal transfers are blocked
        vm.prank(tokenAgent);
        p.tokenController.setFrozen(address(token), user1, true);

        vm.prank(user1);
        vm.expectRevert(bytes("wallet is frozen"));
        token.transfer(user2, 10);

        // force transfer bypasses wallet freeze
        vm.prank(tokenAgent);
        p.tokenController.forceTransfer(address(token), user1, user2, 20);

        assertEq(token.balanceOf(user1), 30);
        assertEq(token.balanceOf(user2), 20);
    }

    // forcedTransfer checks isVerified(_to); unregistered recipient -> "Transfer not possible"
    function test_forceTransfer_to_unregistered_recipient() public {
        vm.prank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "FTU", "FTU", DEFAULT_MAX_SUPPLY);

        TokenController tc = TokenController(address(p.tokenController));
        uint256 caps = tc.PAUSABLE_BIT() | tc.MINTABLE_BIT() | tc.FREEZABLE_BIT() | tc.FORCE_TRANSFERABLE_BIT();
        vm.prank(factoryShareDeployer);
        p.tokenController.setTokenCapsInitial(address(token), caps);

        vm.prank(tokenAgent);
        p.tokenController.unpause(address(token));

        p.registerIdentity(vm, identityRegistryAgent, user1);

        vm.prank(tokenAgent);
        p.tokenController.mint(address(token), user1, 50);

        // user2 not registered in IR → forcedTransfer checks isVerified(_to) → reverts
        vm.prank(tokenAgent);
        vm.expectRevert(bytes("Transfer not possible"));
        p.tokenController.forceTransfer(address(token), user1, user2, 20);
    }

    // Mint

    function test_mint_to_unverified_on_gated_token_reverts() public {
        uint256 kycTopic = 7;
        vm.prank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "MGT", "MGT", DEFAULT_MAX_SUPPLY);

        TokenController tc = TokenController(address(p.tokenController));
        uint256 caps = tc.PAUSABLE_BIT() | tc.MINTABLE_BIT() | tc.FREEZABLE_BIT();
        vm.prank(factoryShareDeployer);
        p.tokenController.setTokenCapsInitial(address(token), caps);

        vm.prank(tokenAgent);
        p.tokenController.unpause(address(token));

        _addClaimTopicAndTrustedIssuer(token, kycTopic);

        p.registerIdentity(vm, identityRegistryAgent, user1);

        vm.prank(tokenAgent);
        vm.expectRevert(bytes("Identity is not verified."));
        p.tokenController.mint(address(token), user1, 10);
    }

    // Freeze / partial freeze

    function test_freeze_blocks_transfers() public {
        vm.prank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "FRZ", "FRZ", DEFAULT_MAX_SUPPLY);
        _unpauseAndMint(token, user1, 100);

        vm.prank(tokenAgent);
        p.tokenController.setFrozen(address(token), user1, true);

        vm.prank(user1);
        vm.expectRevert(bytes("wallet is frozen"));
        token.transfer(user2, 10);

        p.registerIdentity(vm, identityRegistryAgent, user2);

        vm.prank(user1);
        vm.expectRevert(bytes("wallet is frozen"));
        token.transfer(user2, 1);

        vm.prank(tokenAgent);
        p.tokenController.setFrozen(address(token), user1, false);

        vm.prank(user1);
        require(token.transfer(user2, 10), "Transfer failed");
        assertEq(token.balanceOf(user2), 10);
    }

    function test_partial_freeze_blocks_amount_above_frozen() public {
        vm.prank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "PFZ", "PFZ", DEFAULT_MAX_SUPPLY);
        _unpauseAndMint(token, user1, 100);
        p.registerIdentity(vm, identityRegistryAgent, user2);

        // add tokenAgent as a direct token agent so it can call freezePartialTokens
        vm.prank(multisig);
        token.addAgent(tokenAgent);

        vm.prank(tokenAgent);
        token.freezePartialTokens(user1, 50);

        // transfer above frozen amount fails
        vm.prank(user1);
        vm.expectRevert(bytes("Insufficient Balance"));
        token.transfer(user2, 60);

        // transfer at exactly frozen boundary succeeds
        vm.prank(user1);
        require(token.transfer(user2, 50), "Transfer failed");
        assertEq(token.balanceOf(user2), 50);
        assertEq(token.balanceOf(user1), 50);
    }

    function test_unfreeze_partial_restores_spendable() public {
        vm.prank(factoryShareDeployer);
        Token token = p.createShare(multisig, identityRegistryAgent, "UPF", "UPF", DEFAULT_MAX_SUPPLY);
        _unpauseAndMint(token, user1, 100);
        p.registerIdentity(vm, identityRegistryAgent, user2);

        vm.prank(multisig);
        token.addAgent(tokenAgent);

        vm.prank(tokenAgent);
        token.freezePartialTokens(user1, 50);

        vm.prank(user1);
        vm.expectRevert(bytes("Insufficient Balance"));
        token.transfer(user2, 60);

        vm.prank(tokenAgent);
        token.unfreezePartialTokens(user1, 50);

        vm.prank(user1);
        require(token.transfer(user2, 60), "Transfer failed");
        assertEq(token.balanceOf(user2), 60);
        assertEq(token.balanceOf(user1), 40);
    }
}
