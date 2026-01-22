//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Simple fee-on-transfer token for testing: recipient receives (amount - fee),
/// and the fee is sent to `feeCollector`.
contract MockFeeOnTransferToken is ERC20 {
    uint8 private immutable _DECIMALS;
    uint16 public immutable FEE_BPS; // e.g. 100 = 1%
    address public immutable FEE_COLLECTOR;

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint16 feeBps_, address feeCollector_)
        ERC20(name_, symbol_)
    {
        require(feeBps_ <= 10_000, "FeeBpsTooHigh");
        require(feeCollector_ != address(0), "FeeCollectorZero");
        _DECIMALS = decimals_;
        FEE_BPS = feeBps_;
        FEE_COLLECTOR = feeCollector_;
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        if (FEE_BPS == 0 || from == FEE_COLLECTOR || to == FEE_COLLECTOR) {
            super._transfer(from, to, amount);
            return;
        }

        uint256 fee = (amount * FEE_BPS) / 10_000;
        uint256 net = amount - fee;

        super._transfer(from, to, net);
        if (fee > 0) {
            super._transfer(from, FEE_COLLECTOR, fee);
        }
    }
}
