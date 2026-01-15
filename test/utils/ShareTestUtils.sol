// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import {Vm} from 'forge-std/Vm.sol';
import {Identity} from '@onchain-id/solidity/contracts/Identity.sol';
import {IIdentity} from '@onchain-id/solidity/contracts/interface/IIdentity.sol';
import {Token} from '@erc3643org/erc-3643/contracts/token/Token.sol';

import {Protocol} from '../fixtures/ProtocolFixture.sol';

library ShareTestUtils {
    function createShare(
        Protocol storage p,
        address multisig,
        address /* tokenAgent */,
        address identityRegistryAgent,
        string memory name,
        string memory symbol,
        uint256 maxSupply
    ) internal returns (Token token) {
        address[] memory tokenAgents = new address[](0);

        address[] memory irAgents = new address[](1);
        irAgents[0] = identityRegistryAgent;

        // deploy share through Factory
        p.factory.createShare(
            name,
            symbol,
            0,
            multisig,
            tokenAgents,
            irAgents,
            address(p.identityRegistryStorage),
            new uint256[](0),
            new address[](0),
            new uint256[][](0),
            maxSupply
        );

        address tokenAddr = p.factory.idToShare(p.factory.shareIdIndex());
        token = Token(tokenAddr);
    }

    function registerIdentity(Protocol storage p, Vm vm, address identityRegistryAgent, address wallet) internal {
        IIdentity id = IIdentity(address(new Identity(wallet, false)));
        vm.prank(identityRegistryAgent);
        p.identityRegistry.registerIdentity(wallet, id, 1);
    }
}
