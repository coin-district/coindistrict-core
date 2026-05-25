// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import {Test} from "forge-std/Test.sol";
import {ProtocolFixture, Protocol, Accounts} from "../fixtures/ProtocolFixture.sol";
import {ShareTestUtils} from "./ShareTestUtils.sol";

import {IIdentity} from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import {IClaimIssuer} from "@onchain-id/solidity/contracts/interface/IClaimIssuer.sol";

import {ClaimTopicsRegistry} from "@erc3643org/erc-3643/contracts/registry/implementation/ClaimTopicsRegistry.sol";
import {
    TrustedIssuersRegistry
} from "@erc3643org/erc-3643/contracts/registry/implementation/TrustedIssuersRegistry.sol";
import {IdentityRegistry} from "@erc3643org/erc-3643/contracts/registry/implementation/IdentityRegistry.sol";
import {Token} from "@erc3643org/erc-3643/contracts/token/Token.sol";

import {MockToken} from "contracts/mocks/MockToken.sol";
import {MockAggregatorV3} from "contracts/mocks/MockAggregatorV3.sol";

struct BasicSaleCtx {
    Token token;
    MockToken stable;
    MockAggregatorV3 oracle;
    uint256 saleId;
    uint64 start;
    uint64 deadline;
}

abstract contract SalesTestHelpers is Test, ProtocolFixture {
    using ShareTestUtils for Protocol;

    uint256 internal constant DEFAULT_MAX_SUPPLY = 1000;

    address internal multisig = vm.addr(2);
    address internal identityRegistryAgent = vm.addr(3);
    address internal identityRegistryAgent2 = vm.addr(4);
    address internal claimIssuer = vm.addr(5);
    address internal factoryShareDeployer = vm.addr(6);
    address internal salesManagerSalesConfig = vm.addr(7);
    address internal salesManagerSalesOperator = vm.addr(8);
    address internal salesManagerFundsAdmin = vm.addr(9);
    address internal fiatOrderSigner = vm.addr(10);
    address internal buyer = vm.addr(11);
    address internal tokenAgent = vm.addr(14);

    Accounts internal acc = defaultAccounts();
    Protocol internal p;

    function setUp() public virtual {
        p = deployProtocol(acc);
        defaultRoleSetup(p, acc);
        addGlobalIrAgents(p, acc);

        multisig = acc.multisig;
        identityRegistryAgent = acc.identityRegistryAgent;
        identityRegistryAgent2 = acc.identityRegistryAgent2;
        claimIssuer = acc.claimIssuer;
        factoryShareDeployer = acc.factoryShareDeployer;
        salesManagerSalesConfig = acc.salesManagerSalesConfig;
        salesManagerSalesOperator = acc.salesManagerSalesOperator;
        salesManagerFundsAdmin = acc.salesManagerFundsAdmin;
        fiatOrderSigner = acc.fiatOrderSigner;
        buyer = acc.buyer;
        tokenAgent = acc.tokenAgent;
    }

    function _setupBasicSale(string memory name, string memory symbol, uint256 supply, uint256 priceUsdPerShare)
        internal
        returns (BasicSaleCtx memory ctx)
    {
        return _setupBasicSale(name, symbol, supply, priceUsdPerShare, true);
    }

    function _setupBasicSale(
        string memory name,
        string memory symbol,
        uint256 supply,
        uint256 priceUsdPerShare,
        bool registerBuyer_
    ) internal returns (BasicSaleCtx memory ctx) {
        vm.startPrank(factoryShareDeployer);
        ctx.token = p.createShare(multisig, identityRegistryAgent, name, symbol, DEFAULT_MAX_SUPPLY);
        p.tokenController.setTokenCapsInitial(address(ctx.token), p.tokenController.PAUSABLE_BIT());
        vm.stopPrank();

        vm.prank(tokenAgent);
        p.tokenController.unpause(address(ctx.token));

        if (registerBuyer_) {
            p.registerIdentity(vm, identityRegistryAgent, buyer);
        }

        ctx.stable = new MockToken("USD", "USD", 6);
        ctx.stable.mint(buyer, 1_000_000_000);
        ctx.oracle = new MockAggregatorV3(8, 100_000_000);

        vm.startPrank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(ctx.stable), true);
        p.salesManager.setPaymentTokenOracle(address(ctx.stable), address(ctx.oracle), 24 hours, type(uint256).max);
        vm.stopPrank();

        ctx.start = uint64(block.timestamp + 100);
        ctx.deadline = uint64(block.timestamp + 3600);
        vm.prank(salesManagerSalesOperator);
        p.salesManager
            .createSale(
                address(ctx.token),
                _single(address(ctx.stable)),
                multisig,
                supply,
                priceUsdPerShare,
                ctx.start,
                ctx.deadline
            );
        ctx.saleId = p.salesManager.saleCount() - 1;
    }

    function _setupBasicSaleWithDecimals(
        string memory name,
        string memory symbol,
        uint8 shareDecimals,
        uint256 maxSupply,
        uint256 saleSupply,
        uint256 priceUsdPerShare
    ) internal returns (BasicSaleCtx memory ctx) {
        vm.startPrank(factoryShareDeployer);
        ctx.token = p.createShareWithDecimals(multisig, identityRegistryAgent, name, symbol, shareDecimals, maxSupply);
        p.tokenController.setTokenCapsInitial(address(ctx.token), p.tokenController.PAUSABLE_BIT());
        vm.stopPrank();

        vm.prank(tokenAgent);
        p.tokenController.unpause(address(ctx.token));

        p.registerIdentity(vm, identityRegistryAgent, buyer);

        ctx.stable = new MockToken("USD", "USD", 6);
        ctx.stable.mint(buyer, 1_000_000_000);
        ctx.oracle = new MockAggregatorV3(8, 100_000_000);

        vm.startPrank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(ctx.stable), true);
        p.salesManager.setPaymentTokenOracle(address(ctx.stable), address(ctx.oracle), 24 hours, type(uint256).max);
        vm.stopPrank();

        ctx.start = uint64(block.timestamp + 100);
        ctx.deadline = uint64(block.timestamp + 3600);
        vm.prank(salesManagerSalesOperator);
        p.salesManager
            .createSale(
                address(ctx.token),
                _single(address(ctx.stable)),
                multisig,
                saleSupply,
                priceUsdPerShare,
                ctx.start,
                ctx.deadline
            );
        ctx.saleId = p.salesManager.saleCount() - 1;
    }

    function _ceilPayment(uint256 usdCost1e8, uint8 tokenDecimals, uint256 tokenUsdPrice1e8)
        internal
        pure
        returns (uint256)
    {
        return (usdCost1e8 * (10 ** uint256(tokenDecimals)) + tokenUsdPrice1e8 - 1) / tokenUsdPrice1e8;
    }

    function _setupPermissionedSale(uint256 kycTopic) internal returns (Token token, uint256 saleId, MockToken stable) {
        vm.prank(factoryShareDeployer);
        token = p.createShare(multisig, identityRegistryAgent, "PKYC", "PKYC", 1000);

        IdentityRegistry ir = IdentityRegistry(address(token.identityRegistry()));
        ClaimTopicsRegistry ctr = ClaimTopicsRegistry(address(ir.topicsRegistry()));
        TrustedIssuersRegistry tir = TrustedIssuersRegistry(address(ir.issuersRegistry()));

        vm.startPrank(multisig);
        ctr.addClaimTopic(kycTopic);
        tir.addTrustedIssuer(IClaimIssuer(address(p.claimIssuer)), _singleUint(kycTopic));
        vm.stopPrank();

        _unpauseToken(token, p.tokenController.PAUSABLE_BIT());

        stable = new MockToken("USD", "USD", 6);
        stable.mint(buyer, 1_000_000_000);
        MockAggregatorV3 oracle = new MockAggregatorV3(8, 100_000_000);

        vm.startPrank(salesManagerSalesConfig);
        p.salesManager.setAllowedPaymentToken(address(stable), true);
        p.salesManager.setPaymentTokenOracle(address(stable), address(oracle), 24 hours, type(uint256).max);
        vm.stopPrank();

        uint64 start = uint64(block.timestamp + 100);
        uint64 deadline = uint64(block.timestamp + 3600);
        vm.prank(salesManagerSalesOperator);
        p.salesManager.createSale(address(token), _single(address(stable)), multisig, 50, 1e8, start, deadline);
        saleId = p.salesManager.saleCount() - 1;
        vm.warp(start + 1);
    }

    function _addValidKycClaim(Token token, address wallet, uint256 kycTopic) internal {
        p.registerIdentity(vm, identityRegistryAgent, wallet);
        IdentityRegistry ir = IdentityRegistry(address(token.identityRegistry()));
        IIdentity userIdentity = ir.identity(wallet);

        vm.prank(wallet);
        userIdentity.addKey(keccak256(abi.encode(wallet)), 3, 1);
        vm.prank(claimIssuer);

        IClaimIssuer(address(p.claimIssuer)).addKey(keccak256(abi.encode(claimIssuer)), 3, 1);

        bytes memory claimData = hex"0042";
        bytes32 dataHash = keccak256(abi.encode(address(userIdentity), kycTopic, claimData));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", dataHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(5, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(wallet);
        userIdentity.addClaim(kycTopic, 1, address(p.claimIssuer), signature, claimData, "");
    }

    function _singleUint(uint256 v) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = v;
    }

    function _unpauseToken(Token token, uint256 caps) internal {
        vm.prank(factoryShareDeployer);
        p.tokenController.setTokenCapsInitial(address(token), caps);

        vm.prank(tokenAgent);
        p.tokenController.unpause(address(token));
    }
}
