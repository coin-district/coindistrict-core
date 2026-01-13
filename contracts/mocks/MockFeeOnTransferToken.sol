//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';

/// @dev Simple fee-on-transfer token for testing: recipient receives (amount - fee),
/// and the fee is sent to `feeCollector`.
contract MockFeeOnTransferToken is ERC20 {
    uint8 private immutable _decimals;
    uint16 public immutable feeBps; // e.g. 100 = 1%
    address public immutable feeCollector;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        uint16 feeBps_,
        address feeCollector_
    ) ERC20(name_, symbol_) {
        require(feeBps_ <= 10_000, 'FeeBpsTooHigh');
        require(feeCollector_ != address(0), 'FeeCollectorZero');
        _decimals = decimals_;
        feeBps = feeBps_;
        feeCollector = feeCollector_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        if (feeBps == 0 || from == feeCollector || to == feeCollector) {
            super._transfer(from, to, amount);
            return;
        }

        uint256 fee = (amount * feeBps) / 10_000;
        uint256 net = amount - fee;

        super._transfer(from, to, net);
        if (fee > 0) {
            super._transfer(from, feeCollector, fee);
        }
    }
}
