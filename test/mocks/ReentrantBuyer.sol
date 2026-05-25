// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import {ISalesManager} from "contracts/ISalesManager.sol";

/**
 * @dev ERC-20 mock that attempts reentrancy into SalesManager.buy() during transferFrom.
 * Used to verify the nonReentrant guard on SalesManager.buy() holds.
 */
contract MaliciousToken {
    string public name = "MaliciousToken";
    string public symbol = "MAL";
    uint8 public decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public salesManager;
    uint256 public saleId;
    address public attackRecipient;
    bool public attackEnabled;
    bool public reentrancyBlocked;
    string public revertReason;
    bool public unexpectedRevert;

    function setSalesManager(address _salesManager) external {
        salesManager = _salesManager;
    }

    function configureAttack(uint256 _saleId, address _recipient) external {
        saleId = _saleId;
        attackRecipient = _recipient;
        attackEnabled = true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function totalSupply() external pure returns (uint256) {
        return type(uint256).max;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        if (attackEnabled) {
            attackEnabled = false;
            // Re-enter buy() while the outer call is still on the stack.
            // maxPayment is an upper bound; real cost for 1 wei of share rounds to 1 unit.
            try ISalesManager(salesManager).buy(saleId, 1, attackRecipient, address(this), 1_000_000) {
            // reentrancy succeeded — guard did not fire (unexpected; both test asserts will fail)
            }
            catch Error(string memory reason) {
                revertReason = reason;
                // Only count it as blocked when the OZ v4 ReentrancyGuard string fired.
                reentrancyBlocked = keccak256(bytes(reason)) == keccak256(bytes("ReentrancyGuard: reentrant call"));
                unexpectedRevert = !reentrancyBlocked;
            } catch (bytes memory) {
                // Reverted with non-string data (custom error / Panic) — not the v4 guard.
                unexpectedRevert = true;
            }
        }

        return true;
    }
}
