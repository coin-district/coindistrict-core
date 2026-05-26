// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import {Test} from "forge-std/Test.sol";
import {ProtocolFixture, Protocol, Accounts} from "./fixtures/ProtocolFixture.sol";
import {IIdentity} from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import {Identity} from "@onchain-id/solidity/contracts/Identity.sol";
import {IdentityRegistry} from "@erc3643org/erc-3643/contracts/registry/implementation/IdentityRegistry.sol";

contract IdentityRegistryTest is Test, ProtocolFixture {
    Accounts internal acc = defaultAccounts();
    Protocol internal p;
    address internal identityRegistryAgent;
    address internal buyer;

    function setUp() public {
        p = deployProtocol(acc);
        defaultRoleSetup(p, acc);
        addGlobalIrAgents(p, acc);

        identityRegistryAgent = acc.identityRegistryAgent;
        buyer = acc.buyer;
    }

    function test_GlobalIrAgentRegistersIdentity() public {
        IdentityRegistry ir = p.identityRegistry;
        IIdentity buyerIdentity = IIdentity(address(new Identity(buyer, false)));
        vm.prank(identityRegistryAgent);
        ir.registerIdentity(buyer, buyerIdentity, 1);

        assertEq(address(ir.identity(buyer)), address(buyerIdentity));
        assertEq(ir.investorCountry(buyer), 1);
    }

    function test_NonAgentCannotRegisterIdentity() public {
        IIdentity buyerIdentity = IIdentity(address(new Identity(buyer, false)));

        vm.prank(buyer);
        vm.expectRevert(bytes("AgentRole: caller does not have the Agent role"));
        p.identityRegistry.registerIdentity(buyer, buyerIdentity, 1);
    }
}
