// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import {Test} from "forge-std/Test.sol";
import {ProtocolFixture, Protocol, Accounts} from "../fixtures/ProtocolFixture.sol";
import {ShareTestUtils} from "./ShareTestUtils.sol";
import {TokenController} from "contracts/TokenController.sol";
import {IClaimIssuer} from "@onchain-id/solidity/contracts/interface/IClaimIssuer.sol";
import {IIdentity} from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import {ClaimTopicsRegistry} from "@erc3643org/erc-3643/contracts/registry/implementation/ClaimTopicsRegistry.sol";
import {
    TrustedIssuersRegistry
} from "@erc3643org/erc-3643/contracts/registry/implementation/TrustedIssuersRegistry.sol";
import {IdentityRegistry} from "@erc3643org/erc-3643/contracts/registry/implementation/IdentityRegistry.sol";
import {Token} from "@erc3643org/erc-3643/contracts/token/Token.sol";

abstract contract SecondaryTestHelpers is Test, ProtocolFixture {
    using ShareTestUtils for Protocol;

    uint256 internal constant DEFAULT_MAX_SUPPLY = 1000;

    address internal multisig = vm.addr(2);
    address internal identityRegistryAgent = vm.addr(3);
    address internal claimIssuer = vm.addr(5);
    address internal factoryShareDeployer = vm.addr(6);
    address internal tokenAgent = vm.addr(14);
    address internal buyer = vm.addr(11);
    address internal user1 = vm.addr(12);
    address internal user2 = vm.addr(13);

    Accounts internal acc = defaultAccounts();
    Protocol internal p;

    function setUp() public virtual {
        p = deployProtocol(acc);
        defaultRoleSetup(p, acc);
        addGlobalIrAgents(p, acc);

        multisig = acc.multisig;
        identityRegistryAgent = acc.identityRegistryAgent;
        claimIssuer = acc.claimIssuer;
        factoryShareDeployer = acc.factoryShareDeployer;
        tokenAgent = acc.tokenAgent;
        buyer = acc.buyer;
        user1 = acc.user1;
        user2 = acc.user2;
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

    function _addClaimTopicAndTrustedIssuer(Token token, uint256 topic) internal {
        IdentityRegistry ir = IdentityRegistry(address(token.identityRegistry()));
        ClaimTopicsRegistry ctr = ClaimTopicsRegistry(address(ir.topicsRegistry()));
        TrustedIssuersRegistry tir = TrustedIssuersRegistry(address(ir.issuersRegistry()));
        vm.startPrank(multisig);
        ctr.addClaimTopic(topic);
        tir.addTrustedIssuer(IClaimIssuer(address(p.claimIssuer)), _singleUint(topic));
        vm.stopPrank();
    }

    function _addClaimTopicOnly(Token token, uint256 topic) internal {
        IdentityRegistry ir = IdentityRegistry(address(token.identityRegistry()));
        ClaimTopicsRegistry ctr = ClaimTopicsRegistry(address(ir.topicsRegistry()));
        vm.prank(multisig);
        ctr.addClaimTopic(topic);
    }

    function _grantKycClaim(Token token, address user, uint256 topic) internal {
        IdentityRegistry ir = IdentityRegistry(address(token.identityRegistry()));
        IIdentity userIdentity = ir.identity(user);

        vm.prank(user);
        userIdentity.addKey(keccak256(abi.encode(user)), 3, 1);

        bytes32 issuerKey = keccak256(abi.encode(claimIssuer));
        if (!IIdentity(address(p.claimIssuer)).keyHasPurpose(issuerKey, 3)) {
            vm.prank(claimIssuer);
            IClaimIssuer(address(p.claimIssuer)).addKey(issuerKey, 3, 1);
        }

        bytes memory claimData = hex"0042";
        bytes32 dataHash = keccak256(abi.encode(address(userIdentity), topic, claimData));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", dataHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(5, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(user);
        userIdentity.addClaim(topic, 1, address(p.claimIssuer), signature, claimData, "");
    }

    function _singleUint(uint256 v) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = v;
    }
}
