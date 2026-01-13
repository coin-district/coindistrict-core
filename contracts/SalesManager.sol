//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import '@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/utils/math/Math.sol';
import '@erc3643org/erc-3643/contracts/token/IToken.sol';
import '@erc3643org/erc-3643/contracts/compliance/modular/IModularCompliance.sol';
import './compliance/modules/IMaxSupplyModule.sol';
import './interfaces/IAggregatorV3Interface.sol';
import './governance/IGovernance.sol';
import './ISalesManager.sol';

/**
 * @title SalesManager
 * @author CoinDistrict
 * @dev Version: 0.16.0
 * @notice Manages primary sales of ERC-3643 shares against ERC20 payment tokens
 * See {ISalesManager} for usage and more details.
 */
contract SalesManager is ISalesManager, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    /// Constants
    uint8 private constant PRICE_USD_DECIMALS = 8;

    // Governance interface
    IGovernance public governance;

    function initialize(address governance_) external initializer {
        __ReentrancyGuard_init();
        require(governance_ != address(0), 'SalesManager_InvalidGovernance');
        governance = IGovernance(governance_);
    }

    modifier onlyGov() {
        require(governance.hasRole(msg.sender, address(this), msg.sig), 'SalesManager_NotAuthorized');
        _;
    }

    function _authorizeUpgrade(address /*newImplementation*/) internal view override {
        bytes4 selector = bytes4(keccak256('upgradeTo(address)'));
        require(governance.hasRole(msg.sender, address(this), selector), 'SalesManager_NotAuthorized');
    }

    modifier whenNotPaused() {
        require(!emergencyPaused, 'SalesManager_EmergencyPaused');
        _;
    }

    // payment token allowlist (always enforced)
    mapping(address => bool) public allowedPaymentToken;

    // Chainlink oracle mapping: payment token => USD aggregator
    mapping(address => address) public paymentTokenToUsdAggregator;

    // Maximum allowed delay for oracle price updates (in seconds)
    uint256 public maxOracleDelaySeconds;

    // Global emergency pause flag (blocks all buy() and fulfillFiatOrder() operations)
    bool public emergencyPaused;

    uint256 public saleCount;
    mapping(uint256 => uint256) public saleIdToSold; // total sold in token smallest units
    mapping(bytes32 => bool) public fiatOrderReferenceFulfilled;
    mapping(uint256 => Sale) internal _sales;

    /**
     * @dev see {ISalesManager.createSale}
     */
    function createSale(
        address _share,
        address[] calldata _paymentTokensAllowed,
        address _fundsRecipient,
        uint256 _saleSupply,
        uint256 _priceUsdPerShare,
        uint64 _deadline
    ) external onlyGov returns (uint256 saleId) {
        require(_share != address(0), 'Sale_InvalidAddress');
        require(_paymentTokensAllowed.length > 0, 'Sale_NoPaymentTokens');
        require(_fundsRecipient != address(0), 'Sale_InvalidRecipient');
        require(_saleSupply > 0, 'Sale_ZeroSupply');
        require(_priceUsdPerShare > 0, 'Sale_ZeroPrice');
        require(_deadline > block.timestamp, 'Sale_InvalidDeadline');

        // Validate all payment tokens are allowlisted and have oracles configured
        for (uint256 i = 0; i < _paymentTokensAllowed.length; i++) {
            require(_paymentTokensAllowed[i] != address(0), 'Sale_InvalidAddress');
            require(allowedPaymentToken[_paymentTokensAllowed[i]], 'Sale_PaymentTokenNotAllowed');
            require(paymentTokenToUsdAggregator[_paymentTokensAllowed[i]] != address(0), 'Sale_OracleNotConfigured');
        }

        uint8 shareDecimals = IToken(_share).decimals();

        // If a MaxSupplyModule is bound with a finite cap, ensure saleSupply does not exceed remaining cap
        (bool capFound, uint256 remainingCap) = _getRemainingCap(_share);
        if (capFound) {
            require(_saleSupply <= remainingCap, 'Sale_SupplyExceedsCap');
        }

        saleId = saleCount;
        _sales[saleId] = Sale({
            share: _share,
            paymentTokensAllowed: _paymentTokensAllowed,
            fundsRecipient: _fundsRecipient,
            remainingSupply: _saleSupply,
            priceUsdPerShare: _priceUsdPerShare,
            deadline: _deadline,
            shareDecimals: shareDecimals,
            active: true,
            paused: false
        });

        emit SaleCreated(
            saleId,
            _share,
            _paymentTokensAllowed,
            _fundsRecipient,
            _saleSupply,
            _priceUsdPerShare,
            _deadline,
            shareDecimals
        );
        unchecked {
            saleCount++;
        }
    }

    /**
     * IMPORTANT: Cap is derived from the first MaxSupplyModule found on the bound compliance.
     */
    function _getRemainingCap(address _share) internal view returns (bool found, uint256 remaining) {
        IModularCompliance compliance = IModularCompliance(IToken(_share).compliance());
        address[] memory modules = compliance.getModules();
        for (uint256 i = 0; i < modules.length; i++) {
            address m = modules[i];
            // try/catch in case module is not MaxSupplyModule
            try IMaxSupplyModule(m).getMaxSupply(address(compliance)) returns (uint256 maxSupply) {
                if (maxSupply == 0) {
                    // uncapped
                    return (false, 0);
                }
                uint256 cur = IMaxSupplyModule(m).getCurrentSupply(address(compliance));
                if (maxSupply > cur) {
                    return (true, maxSupply - cur);
                }
                return (true, 0);
            } catch {
                // not the expected module, continue
            }
        }
        return (false, 0);
    }

    /**
     * @dev see {ISalesManager.buy}
     */
    function buy(
        uint256 _saleId,
        uint256 _amount,
        address _to,
        address _paymentToken,
        uint256 _maxPayment
    ) external nonReentrant whenNotPaused {
        Sale storage s = _sales[_saleId];
        require(s.active, 'Sale_NotActive');
        require(!s.paused, 'Sale_Paused');
        require(s.share != address(0), 'Sale_DoesNotExist');
        require(_to != address(0), 'Sale_InvalidRecipient');
        require(block.timestamp <= s.deadline, 'Sale_Ended');
        require(_amount > 0 && _amount <= s.remainingSupply, 'Sale_AmountInvalid');

        // Check if payment token is in the sale's allowed list
        bool isAllowed = false;
        for (uint256 i = 0; i < s.paymentTokensAllowed.length; i++) {
            if (s.paymentTokensAllowed[i] == _paymentToken) {
                isAllowed = true;
                break;
            }
        }
        require(isAllowed, 'Sale_PaymentTokenNotAllowed');

        // Get oracle aggregator (already validated at sale creation)
        address aggregator = paymentTokenToUsdAggregator[_paymentToken];

        // Calculate USD cost (in 1e8)
        uint256 usdCost = _calculateUsdCost(_amount, s.priceUsdPerShare, s.shareDecimals);

        // Get token/USD price from Chainlink (returns price in 1e8)
        uint256 tokenUsdPrice1e8 = _getTokenUsdPrice1e8(aggregator);

        // Get payment token decimals
        uint8 tokenDecimals = IERC20Metadata(_paymentToken).decimals();

        // Convert USD cost to payment token amount with ceil rounding
        // tokenAmount = ceil(usdCost * 10^tokenDecimals / tokenUsdPrice1e8)
        uint256 tokenAmount = Math.mulDiv(usdCost, 10 ** uint256(tokenDecimals), tokenUsdPrice1e8, Math.Rounding.Up);

        // Slippage protection
        require(tokenAmount <= _maxPayment, 'Sale_MaxPaymentExceeded');

        // Pull payment token from buyer to this contract first. If anything reverts later, the whole tx reverts.
        IERC20(_paymentToken).safeTransferFrom(msg.sender, address(this), tokenAmount);

        // Mint shares to recipient. Requires this contract to be an Agent on the share.
        IToken(s.share).mint(_to, _amount);

        // Forward funds to recipient treasury
        IERC20(_paymentToken).safeTransfer(s.fundsRecipient, tokenAmount);

        // Update accounting
        s.remainingSupply -= _amount;
        unchecked {
            saleIdToSold[_saleId] += _amount;
        }

        emit SharePurchase(_saleId, msg.sender, _to, _paymentToken, _amount, tokenAmount);
    }

    /**
     * @dev see {ISalesManager.cancelSale}
     */
    function cancelSale(uint256 _saleId) external onlyGov {
        Sale storage s = _sales[_saleId];
        require(s.active && s.share != address(0), 'Sale_DoesNotExist');
        s.active = false;
        // Also set deadline to past for completeness
        s.deadline = uint64(block.timestamp);
        emit SaleCancelled(_saleId);
    }

    /**
     * @dev see {ISalesManager.pauseSale}
     */
    function pauseSale(uint256 _saleId) external onlyGov {
        Sale storage s = _sales[_saleId];
        require(s.share != address(0), 'Sale_DoesNotExist');
        require(s.active, 'Sale_NotActive');
        require(!s.paused, 'Sale_AlreadyPaused');
        s.paused = true;
        emit SalePaused(_saleId);
    }

    /**
     * @dev see {ISalesManager.unpauseSale}
     */
    function unpauseSale(uint256 _saleId) external onlyGov {
        Sale storage s = _sales[_saleId];
        require(s.share != address(0), 'Sale_DoesNotExist');
        require(s.active, 'Sale_NotActive');
        require(s.paused, 'Sale_NotPaused');
        s.paused = false;
        emit SaleUnpaused(_saleId);
    }

    /**
     * @dev see {ISalesManager.updateSaleFundsRecipient}
     */
    function updateSaleFundsRecipient(uint256 _saleId, address _newRecipient) external onlyGov {
        require(_newRecipient != address(0), 'Sale_InvalidRecipient');
        Sale storage s = _sales[_saleId];
        require(s.share != address(0), 'Sale_DoesNotExist');
        address old = s.fundsRecipient;
        s.fundsRecipient = _newRecipient;
        emit SaleFundsRecipientUpdated(_saleId, old, _newRecipient);
    }

    /**
     * @dev see {ISalesManager.updateSalePaymentTokensAllowed}
     */
    function updateSalePaymentTokensAllowed(
        uint256 _saleId,
        address[] calldata _newPaymentTokensAllowed
    ) external onlyGov {
        require(_newPaymentTokensAllowed.length > 0, 'Sale_NoPaymentTokens');
        Sale storage s = _sales[_saleId];
        require(s.share != address(0), 'Sale_DoesNotExist');

        // Validate all payment tokens are allowlisted and have oracles configured
        for (uint256 i = 0; i < _newPaymentTokensAllowed.length; i++) {
            address paymentToken = _newPaymentTokensAllowed[i];
            require(paymentToken != address(0), 'Sale_InvalidAddress');
            require(allowedPaymentToken[paymentToken], 'Sale_PaymentTokenNotAllowed');
            require(paymentTokenToUsdAggregator[paymentToken] != address(0), 'Sale_OracleNotConfigured');
        }

        address[] memory oldPaymentTokensAllowed = s.paymentTokensAllowed;
        s.paymentTokensAllowed = _newPaymentTokensAllowed;
        emit SalePaymentTokensAllowedUpdated(_saleId, oldPaymentTokensAllowed, _newPaymentTokensAllowed);
    }

    /**
     * @dev see {ISalesManager.updateSalePriceUsdPerShare}
     */
    function updateSalePriceUsdPerShare(uint256 _saleId, uint256 _newPriceUsdPerShare) external onlyGov {
        require(_newPriceUsdPerShare > 0, 'Sale_ZeroPrice');
        Sale storage s = _sales[_saleId];
        require(s.share != address(0), 'Sale_DoesNotExist');
        uint256 oldPrice = s.priceUsdPerShare;
        s.priceUsdPerShare = _newPriceUsdPerShare;
        emit SalePriceUsdPerShareUpdated(_saleId, oldPrice, _newPriceUsdPerShare);
    }

    /**
     * @dev see {ISalesManager.updateSaleDeadline}
     */
    function updateSaleDeadline(uint256 _saleId, uint256 _newDeadline) external onlyGov {
        require(_newDeadline > block.timestamp, 'Sale_InvalidDeadline');
        Sale storage s = _sales[_saleId];
        require(s.share != address(0), 'Sale_DoesNotExist');
        uint64 oldDeadline = s.deadline;
        s.deadline = uint64(_newDeadline);
        emit SaleDeadlineUpdated(_saleId, oldDeadline, s.deadline);
    }

    /**
     * @dev see {ISalesManager.fulfillFiatOrder}
     */
    function fulfillFiatOrder(
        uint256 _saleId,
        uint256 _amount,
        address _to,
        bytes32 _reference
    ) external onlyGov nonReentrant whenNotPaused {
        Sale storage s = _sales[_saleId];
        require(s.active, 'Sale_NotActive');
        require(!s.paused, 'Sale_Paused');
        require(s.share != address(0), 'Sale_DoesNotExist');
        require(_to != address(0), 'Sale_InvalidRecipient');
        require(block.timestamp <= s.deadline, 'Sale_Ended');
        require(_amount > 0 && _amount <= s.remainingSupply, 'Sale_AmountInvalid');
        require(!fiatOrderReferenceFulfilled[_reference], 'Sale_FiatOrderReferenceAlreadyFulfilled');

        IToken(s.share).mint(_to, _amount);
        s.remainingSupply -= _amount;
        unchecked {
            saleIdToSold[_saleId] += _amount;
        }

        fiatOrderReferenceFulfilled[_reference] = true;
        emit FiatOrderFulfilled(_saleId, _to, _amount, _reference);
    }

    /**
     * @dev see {ISalesManager.rescueTokens}
     */
    function rescueTokens(address _erc20, address _to, uint256 _amount) external onlyGov {
        require(_to != address(0), 'Rescue_InvalidRecipient');
        require(!allowedPaymentToken[_erc20], 'Rescue_UseWithdrawFundsForPaymentTokens');

        IERC20(_erc20).safeTransfer(_to, _amount);
        emit TokensRescued(_erc20, _to, _amount);
    }

    /**
     * @dev see {ISalesManager.withdrawFunds}
     */
    function withdrawFunds(address[] calldata tokens, address to, uint256[] calldata amounts) external onlyGov {
        require(to != address(0), 'Rescue_InvalidRecipient');
        require(tokens.length == amounts.length, 'Sale_LengthMismatch');
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 amount = amounts[i];
            require(allowedPaymentToken[token], 'Sale_PaymentTokenNotAllowed');
            IERC20(token).safeTransfer(to, amount);
            emit FundsWithdrawn(token, to, amount);
        }
    }

    /**
     * @dev see {ISalesManager.setAllowedPaymentToken}
     */
    function setAllowedPaymentToken(address paymentToken, bool allowed) external onlyGov {
        allowedPaymentToken[paymentToken] = allowed;
        emit PaymentTokenAllowed(paymentToken, allowed);
    }

    /**
     * @dev see {ISalesManager.setPaymentTokenOracle}
     */
    function setPaymentTokenOracle(address paymentToken, address aggregator) external onlyGov {
        paymentTokenToUsdAggregator[paymentToken] = aggregator;
        emit PaymentTokenOracleSet(paymentToken, aggregator);
    }

    /**
     * @dev see {ISalesManager.setMaxOracleDelaySeconds}
     */
    function setMaxOracleDelaySeconds(uint256 seconds_) external onlyGov {
        uint256 oldDelay = maxOracleDelaySeconds;
        maxOracleDelaySeconds = seconds_;
        emit MaxOracleDelayUpdated(oldDelay, seconds_);
    }

    /**
     * @dev see {ISalesManager.setEmergencyPause}
     */
    function setEmergencyPause() external onlyGov {
        require(!emergencyPaused, 'SalesManager_AlreadyPaused');
        emergencyPaused = true;
        emit EmergencyPauseSet(true);
    }

    /**
     * @dev see {ISalesManager.unsetEmergencyPause}
     */
    function unsetEmergencyPause() external onlyGov {
        require(emergencyPaused, 'SalesManager_NotPaused');
        emergencyPaused = false;
        emit EmergencyPauseSet(false);
    }

    /**
     * @dev Calculate USD cost in 1e8 units
     * @param _amount Amount of shares (smallest units)
     * @param _priceUsdPerShare USD price per 1 full share (10^shareDecimals), 8 decimals (1e8)
     * @param _shareDecimals Decimals of the share token
     * @return USD cost in 1e8 units
     */
    function _calculateUsdCost(
        uint256 _amount,
        uint256 _priceUsdPerShare,
        uint8 _shareDecimals
    ) internal pure returns (uint256) {
        uint256 scale = 10 ** uint256(_shareDecimals);
        // Use mulDiv to avoid overflow and maintain precision
        return Math.mulDiv(_amount, _priceUsdPerShare, scale, Math.Rounding.Down);
    }

    /**
     * @dev Get token/USD price from Chainlink aggregator, normalized to 1e8
     * @param aggregator Chainlink aggregator address
     * @return price Token/USD price in 1e8 units
     */
    function _getTokenUsdPrice1e8(address aggregator) internal view returns (uint256 price) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(aggregator);
        (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();

        // Validate price data
        require(answer > 0, 'Sale_InvalidPrice');
        require(updatedAt > 0, 'Sale_PriceNotUpdated');
        require(answeredInRound >= roundId, 'Sale_StaleRound');
        require(block.timestamp - updatedAt <= maxOracleDelaySeconds, 'Sale_StalePrice');

        uint8 aggregatorDecimals = priceFeed.decimals();
        uint256 priceRaw = uint256(answer);

        // Scale to 1e8 if needed
        if (aggregatorDecimals == 8) {
            return priceRaw;
        } else if (aggregatorDecimals > 8) {
            // Scale down
            return priceRaw / (10 ** uint256(aggregatorDecimals - 8));
        } else {
            // Scale up
            return priceRaw * (10 ** uint256(8 - aggregatorDecimals));
        }
    }

    /**
     * @dev see {ISalesManager.isPaymentTokenAllowed}
     */
    function isPaymentTokenAllowed(address paymentToken) external view returns (bool) {
        return allowedPaymentToken[paymentToken];
    }

    /**
     * @dev see {ISalesManager.getSaleTotalSupply}
     */
    function getSaleTotalSupply(uint256 saleId) external view returns (uint256) {
        Sale storage s = _sales[saleId];
        require(s.share != address(0), 'Sale_DoesNotExist');
        return s.remainingSupply + saleIdToSold[saleId];
    }

    /**
     * @dev see {ISalesManager.getSaleRemainingSupply}
     */
    function getSaleRemainingSupply(uint256 saleId) external view returns (uint256) {
        Sale storage s = _sales[saleId];
        require(s.share != address(0), 'Sale_DoesNotExist');
        return s.remainingSupply;
    }

    /**
     * @dev see {ISalesManager.sales}
     */
    function sales(
        uint256 saleId
    )
        external
        view
        returns (
            address share,
            address[] memory paymentTokensAllowed,
            address fundsRecipient,
            uint256 remainingSupply,
            uint256 priceUsdPerShare,
            uint64 deadline,
            uint8 shareDecimals,
            bool active,
            bool paused
        )
    {
        Sale storage s = _sales[saleId];
        return (
            s.share,
            s.paymentTokensAllowed,
            s.fundsRecipient,
            s.remainingSupply,
            s.priceUsdPerShare,
            s.deadline,
            s.shareDecimals,
            s.active,
            s.paused
        );
    }

    uint256[50] private __gap;
}
