//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IToken} from "@erc3643org/erc-3643/contracts/token/IToken.sol";
import {IModularCompliance} from "@erc3643org/erc-3643/contracts/compliance/modular/IModularCompliance.sol";
import {IMaxSupplyModule} from "./compliance/modules/IMaxSupplyModule.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IGovernance} from "./governance/IGovernance.sol";
import {ISalesManager} from "./ISalesManager.sol";

/**
 * @title SalesManager
 * @author CoinDistrict
 * @dev Version: 1.0.0-rc2
 * @notice Manages primary sales of ERC-3643 shares against ERC20 payment tokens
 * See {ISalesManager} for usage and more details.
 */
contract SalesManager is ISalesManager, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    /// @dev Decimal precision used for sale USD prices and normalized oracle answers.
    uint8 private constant PRICE_USD_DECIMALS = 8;
    uint256 private constant MIN_ORACLE_DELAY = 60; // seconds
    uint256 private constant MAX_ORACLE_DELAY = 24 hours;

    IGovernance public governance;
    uint256 public saleCount;
    bool public emergencyPaused;

    mapping(address => bool) public allowedPaymentToken;
    mapping(address => address) public paymentTokenToUsdAggregator;
    mapping(address => uint256) public paymentTokenMaxDelay;
    mapping(address => uint256) public paymentTokenMaxPrice1e8;
    mapping(uint256 => Sale) internal _sales;
    mapping(uint256 => uint256) public saleIdToSold; // total sold in token smallest units
    mapping(bytes32 => bool) public fiatOrderReferenceFulfilled;
    uint256[50] private __gap;

    modifier onlyGov() {
        _onlyGov();
        _;
    }

    modifier whenNotPaused() {
        _whenNotPaused();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address governance_) external initializer {
        __ReentrancyGuard_init();
        if (governance_ == address(0)) revert InvalidGovernance();
        governance = IGovernance(governance_);
    }

    /**
     * @dev see {ISalesManager.createSale}
     */
    function createSale(
        address _share,
        address[] calldata _paymentTokensAllowed,
        address _fundsRecipient,
        uint256 _saleSupply,
        uint256 _priceUsdPerShare,
        uint64 _start,
        uint64 _deadline
    ) external onlyGov returns (uint256 saleId) {
        if (_share == address(0)) revert InvalidAddress();
        uint256 len = _paymentTokensAllowed.length;
        if (len == 0) revert NoPaymentTokens();
        if (_fundsRecipient == address(0)) revert InvalidRecipient();
        if (_saleSupply == 0) revert ZeroSupply();
        if (_priceUsdPerShare == 0) revert ZeroPrice();
        if (_start <= block.timestamp) revert InvalidStart();
        if (_deadline <= _start) revert InvalidDeadline();

        // Validate all payment tokens are allowlisted and have oracles configured.
        for (uint256 i; i < len;) {
            address paymentToken = _paymentTokensAllowed[i];
            if (paymentToken == address(0)) revert InvalidAddress();
            if (!allowedPaymentToken[paymentToken]) revert PaymentTokenNotAllowed();
            if (paymentTokenToUsdAggregator[paymentToken] == address(0)) revert OracleNotConfigured();
            unchecked {
                ++i;
            }
        }

        uint8 shareDecimals = IToken(_share).decimals();

        // If a MaxSupplyModule is bound with a finite cap, ensure saleSupply does not exceed remaining cap.
        (bool capFound, uint256 remainingCap) = _getRemainingCap(_share);
        if (capFound && _saleSupply > remainingCap) revert SupplyExceedsCap();

        saleId = saleCount;
        _sales[saleId] = Sale({
            share: _share,
            paymentTokensAllowed: _paymentTokensAllowed,
            fundsRecipient: _fundsRecipient,
            remainingSupply: _saleSupply,
            priceUsdPerShare: _priceUsdPerShare,
            start: _start,
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
            _start,
            _deadline,
            shareDecimals
        );
        unchecked {
            saleCount++;
        }
    }

    /**
     * @dev see {ISalesManager.buy}
     */
    function buy(uint256 _saleId, uint256 _amount, address _to, address _paymentToken, uint256 _maxPayment)
        external
        nonReentrant
        whenNotPaused
    {
        Sale storage s = _sales[_saleId];
        _validateBuyInputs(s, _amount, _to);

        address aggregator = _requireAllowedPaymentToken(s, _paymentToken);
        uint256 tokenAmount =
            _quotePaymentAmount(_amount, s.priceUsdPerShare, s.shareDecimals, aggregator, _paymentToken);
        if (tokenAmount > _maxPayment) revert MaxPaymentExceeded();

        // Cache storage fields needed after interactions before mutating state.
        address share = s.share;
        address fundsRecipient = s.fundsRecipient;

        // update accounting before any external interaction (CEI; defense-in-depth atop nonReentrant).
        s.remainingSupply -= _amount;
        unchecked {
            saleIdToSold[_saleId] += _amount;
        }

        _pullExactPayment(_paymentToken, tokenAmount);
        IToken(share).mint(_to, _amount);
        IERC20(_paymentToken).safeTransfer(fundsRecipient, tokenAmount);

        emit SharePurchase(_saleId, msg.sender, _to, _paymentToken, _amount, tokenAmount);
    }

    /**
     * @dev see {ISalesManager.fulfillFiatOrder}
     */
    function fulfillFiatOrder(uint256 _saleId, uint256 _amount, address _to, bytes32 _reference)
        external
        onlyGov
        nonReentrant
        whenNotPaused
    {
        Sale storage s = _sales[_saleId];
        if (!s.active) revert SaleNotActive();
        if (s.paused) revert SalePausedErr();
        if (s.share == address(0)) revert SaleDoesNotExist();
        if (_to == address(0)) revert InvalidRecipient();
        if (block.timestamp < s.start) revert SaleNotStarted();
        if (block.timestamp > s.deadline) revert SaleEnded();
        if (_amount == 0 || _amount > s.remainingSupply) revert AmountInvalid();
        if (_reference == bytes32(0)) revert InvalidFiatOrderReference();
        if (fiatOrderReferenceFulfilled[_reference]) revert FiatOrderReferenceAlreadyFulfilled();

        s.remainingSupply -= _amount;
        unchecked {
            saleIdToSold[_saleId] += _amount;
        }
        fiatOrderReferenceFulfilled[_reference] = true;

        IToken(s.share).mint(_to, _amount);
        emit FiatOrderFulfilled(_saleId, _to, _amount, _reference);
    }

    /**
     * @dev see {ISalesManager.cancelSale}
     */
    function cancelSale(uint256 _saleId) external onlyGov {
        Sale storage s = _sales[_saleId];
        if (!s.active || s.share == address(0)) revert SaleDoesNotExist();
        s.active = false;

        // Also set deadline to past for completeness.
        s.deadline = uint64(block.timestamp);
        emit SaleCancelled(_saleId);
    }

    /**
     * @dev see {ISalesManager.pauseSale}
     */
    function pauseSale(uint256 _saleId) external onlyGov {
        Sale storage s = _sales[_saleId];
        if (s.share == address(0)) revert SaleDoesNotExist();
        if (!s.active) revert SaleNotActive();
        if (s.paused) revert SaleAlreadyPaused();

        s.paused = true;
        emit SalePaused(_saleId);
    }

    /**
     * @dev see {ISalesManager.unpauseSale}
     */
    function unpauseSale(uint256 _saleId) external onlyGov {
        Sale storage s = _sales[_saleId];
        if (s.share == address(0)) revert SaleDoesNotExist();
        if (!s.active) revert SaleNotActive();
        if (!s.paused) revert SaleNotPaused();

        s.paused = false;
        emit SaleUnpaused(_saleId);
    }

    /**
     * @dev see {ISalesManager.updateSaleFundsRecipient}
     */
    function updateSaleFundsRecipient(uint256 _saleId, address _newRecipient) external onlyGov {
        if (_newRecipient == address(0)) revert InvalidRecipient();
        Sale storage s = _sales[_saleId];
        if (s.share == address(0)) revert SaleDoesNotExist();

        address old = s.fundsRecipient;
        s.fundsRecipient = _newRecipient;
        emit SaleFundsRecipientUpdated(_saleId, old, _newRecipient);
    }

    /**
     * @dev see {ISalesManager.updateSalePaymentTokensAllowed}
     */
    function updateSalePaymentTokensAllowed(uint256 _saleId, address[] calldata _newPaymentTokensAllowed)
        external
        onlyGov
    {
        uint256 len = _newPaymentTokensAllowed.length;
        if (len == 0) revert NoPaymentTokens();
        Sale storage s = _sales[_saleId];
        if (s.share == address(0)) revert SaleDoesNotExist();

        // Validate all payment tokens are allowlisted and have oracles configured.
        for (uint256 i; i < len;) {
            address paymentToken = _newPaymentTokensAllowed[i];
            if (paymentToken == address(0)) revert InvalidAddress();
            if (!allowedPaymentToken[paymentToken]) revert PaymentTokenNotAllowed();
            if (paymentTokenToUsdAggregator[paymentToken] == address(0)) revert OracleNotConfigured();
            unchecked {
                ++i;
            }
        }

        address[] memory oldPaymentTokensAllowed = s.paymentTokensAllowed;
        s.paymentTokensAllowed = _newPaymentTokensAllowed;
        emit SalePaymentTokensAllowedUpdated(_saleId, oldPaymentTokensAllowed, _newPaymentTokensAllowed);
    }

    /**
     * @dev see {ISalesManager.updateSalePriceUsdPerShare}
     */
    function updateSalePriceUsdPerShare(uint256 _saleId, uint256 _newPriceUsdPerShare) external onlyGov {
        if (_newPriceUsdPerShare == 0) revert ZeroPrice();

        Sale storage s = _sales[_saleId];
        if (s.share == address(0)) revert SaleDoesNotExist();

        uint256 oldPrice = s.priceUsdPerShare;
        s.priceUsdPerShare = _newPriceUsdPerShare;
        emit SalePriceUsdPerShareUpdated(_saleId, oldPrice, _newPriceUsdPerShare);
    }

    /**
     * @dev see {ISalesManager.updateSaleDeadline}
     */
    function updateSaleDeadline(uint256 _saleId, uint256 _newDeadline) external onlyGov {
        if (_newDeadline <= block.timestamp) revert InvalidDeadline();
        if (_newDeadline > type(uint64).max) revert InvalidDeadline();

        Sale storage s = _sales[_saleId];
        if (s.share == address(0)) revert SaleDoesNotExist();

        uint64 oldDeadline = s.deadline;

        // Safe: _newDeadline is checked > block.timestamp and <= type(uint64).max.
        // forge-lint: disable-next-line(unsafe-typecast)
        s.deadline = uint64(_newDeadline);
        emit SaleDeadlineUpdated(_saleId, oldDeadline, s.deadline);
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
    function setPaymentTokenOracle(address paymentToken, address aggregator, uint256 maxDelay, uint256 maxPrice1e8)
        external
        onlyGov
    {
        if (aggregator == address(0)) {
            paymentTokenToUsdAggregator[paymentToken] = address(0);
            paymentTokenMaxDelay[paymentToken] = 0;
            paymentTokenMaxPrice1e8[paymentToken] = 0;
            emit PaymentTokenOracleSet(paymentToken, address(0), 0, 0);
            return;
        }

        if (maxDelay < MIN_ORACLE_DELAY || maxDelay > MAX_ORACLE_DELAY) revert InvalidOracleDelay();
        if (maxPrice1e8 == 0) revert InvalidMaxPrice();

        // Probe the feed so a broken aggregator can't be configured.
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(aggregator).latestRoundData();
        if (answer <= 0 || updatedAt == 0) revert InvalidOracle();

        paymentTokenToUsdAggregator[paymentToken] = aggregator;
        paymentTokenMaxDelay[paymentToken] = maxDelay;
        paymentTokenMaxPrice1e8[paymentToken] = maxPrice1e8;
        emit PaymentTokenOracleSet(paymentToken, aggregator, maxDelay, maxPrice1e8);
    }

    /**
     * @dev see {ISalesManager.setEmergencyPause}
     */
    function setEmergencyPause() external onlyGov {
        if (emergencyPaused) revert EmergencyAlreadyPaused();
        emergencyPaused = true;
        emit EmergencyPauseSet(true);
    }

    /**
     * @dev see {ISalesManager.unsetEmergencyPause}
     */
    function unsetEmergencyPause() external onlyGov {
        if (!emergencyPaused) revert EmergencyNotPaused();
        emergencyPaused = false;
        emit EmergencyPauseSet(false);
    }

    /**
     * @dev see {ISalesManager.rescueTokens}
     */
    function rescueTokens(address _erc20, address _to, uint256 _amount) external onlyGov {
        if (_to == address(0)) revert InvalidRecipient();
        if (allowedPaymentToken[_erc20]) revert UseWithdrawFundsForPaymentTokens();

        IERC20(_erc20).safeTransfer(_to, _amount);
        emit TokensRescued(_erc20, _to, _amount);
    }

    /**
     * @dev see {ISalesManager.withdrawFunds}
     */
    function withdrawFunds(address[] calldata tokens, address to, uint256[] calldata amounts) external onlyGov {
        if (to == address(0)) revert InvalidRecipient();

        uint256 len = tokens.length;
        if (len != amounts.length) revert LengthMismatch();

        for (uint256 i; i < len;) {
            address token = tokens[i];
            uint256 amount = amounts[i];
            if (!allowedPaymentToken[token]) revert PaymentTokenNotAllowed();
            IERC20(token).safeTransfer(to, amount);
            emit FundsWithdrawn(token, to, amount);
            unchecked {
                ++i;
            }
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
        if (s.share == address(0)) revert SaleDoesNotExist();
        return s.remainingSupply + saleIdToSold[saleId];
    }

    /**
     * @dev see {ISalesManager.getSaleRemainingSupply}
     */
    function getSaleRemainingSupply(uint256 saleId) external view returns (uint256) {
        Sale storage s = _sales[saleId];
        if (s.share == address(0)) revert SaleDoesNotExist();
        return s.remainingSupply;
    }

    /**
     * @dev see {ISalesManager.getSale}
     */
    function getSale(uint256 saleId) external view returns (Sale memory) {
        Sale storage s = _sales[saleId];
        if (s.share == address(0)) revert SaleDoesNotExist();
        return s;
    }

    function _onlyGov() internal view {
        if (!governance.hasRole(msg.sender, address(this), msg.sig)) revert NotAuthorized();
    }

    function _whenNotPaused() internal view {
        if (emergencyPaused) revert EmergencyPausedErr();
    }

    function _authorizeUpgrade(
        address /*newImplementation*/
    )
        internal
        view
        override
    {
        if (!governance.hasRole(msg.sender, address(this), msg.sig)) revert NotAuthorized();
    }

    /**
     * @dev Validate sale state and buyer inputs shared by buy().
     */
    function _validateBuyInputs(Sale storage s, uint256 _amount, address _to) internal view {
        if (!s.active) revert SaleNotActive();
        if (s.paused) revert SalePausedErr();
        if (s.share == address(0)) revert SaleDoesNotExist();
        if (_to == address(0)) revert InvalidRecipient();
        if (block.timestamp < s.start) revert SaleNotStarted();
        if (block.timestamp > s.deadline) revert SaleEnded();
        if (_amount == 0 || _amount > s.remainingSupply) revert AmountInvalid();
    }

    /**
     * @dev Confirm `_paymentToken` is allowed for this sale and globally, then return its oracle.
     * @return aggregator Chainlink USD aggregator for the payment token.
     */
    function _requireAllowedPaymentToken(Sale storage s, address _paymentToken)
        internal
        view
        returns (address aggregator)
    {
        bool isAllowed = false;
        uint256 len = s.paymentTokensAllowed.length;
        for (uint256 i; i < len;) {
            if (s.paymentTokensAllowed[i] == _paymentToken) {
                isAllowed = true;
                break;
            }
            unchecked {
                ++i;
            }
        }

        if (!isAllowed) revert PaymentTokenNotAllowed();
        if (!allowedPaymentToken[_paymentToken]) revert PaymentTokenNotAllowed();

        aggregator = paymentTokenToUsdAggregator[_paymentToken];
        if (aggregator == address(0)) revert OracleNotConfigured();
    }

    /**
     * @dev Convert a share amount to the payment token amount required, with ceil rounding.
     */
    function _quotePaymentAmount(
        uint256 _amount,
        uint256 _priceUsdPerShare,
        uint8 _shareDecimals,
        address _aggregator,
        address _paymentToken
    ) internal view returns (uint256 tokenAmount) {
        uint256 usdCost = _calculateUsdCost(_amount, _priceUsdPerShare, _shareDecimals);
        if (usdCost == 0) revert ZeroCost();

        uint256 tokenUsdPrice1e8 = _getTokenUsdPrice1e8(
            _aggregator, paymentTokenMaxDelay[_paymentToken], paymentTokenMaxPrice1e8[_paymentToken]
        );
        uint8 tokenDecimals = IERC20Metadata(_paymentToken).decimals();
        tokenAmount = Math.mulDiv(usdCost, 10 ** uint256(tokenDecimals), tokenUsdPrice1e8, Math.Rounding.Up);
    }

    /**
     * IMPORTANT: Cap is derived from the first MaxSupplyModule found on the bound compliance.
     */
    function _getRemainingCap(address _share) internal view returns (bool found, uint256 remaining) {
        IModularCompliance compliance = IModularCompliance(IToken(_share).compliance());
        address[] memory modules = compliance.getModules();
        uint256 len = modules.length;

        for (uint256 i; i < len;) {
            address m = modules[i];
            // try/catch in case module is not MaxSupplyModule.
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
            unchecked {
                ++i;
            }
        }

        return (false, 0);
    }

    /**
     * @dev Get token/USD price from Chainlink aggregator, normalized to 1e8
     * @param aggregator Chainlink aggregator address
     * @param maxDelay Max accepted staleness (seconds) for this feed
     * @param maxPrice1e8 Max accepted normalized price (1e8) for this feed
     * @return price Token/USD price in 1e8 units
     */
    function _getTokenUsdPrice1e8(address aggregator, uint256 maxDelay, uint256 maxPrice1e8)
        internal
        view
        returns (uint256 price)
    {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(aggregator);
        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();

        // Validate price data.
        if (answer <= 0) revert InvalidPrice();
        if (updatedAt == 0) revert PriceNotUpdated();
        if (block.timestamp - updatedAt > maxDelay) revert StalePrice();

        uint8 aggregatorDecimals = priceFeed.decimals();

        // Safe: answer is checked > 0 and int256 max fits into uint256.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 priceRaw = uint256(answer);

        // Scale the feed answer to the protocol's USD price precision if needed.
        if (aggregatorDecimals == PRICE_USD_DECIMALS) {
            price = priceRaw;
        } else if (aggregatorDecimals > PRICE_USD_DECIMALS) {
            price = priceRaw / (10 ** uint256(aggregatorDecimals - PRICE_USD_DECIMALS));
        } else {
            price = priceRaw * (10 ** uint256(PRICE_USD_DECIMALS - aggregatorDecimals));
        }

        if (price == 0) revert InvalidPrice();
        if (price > maxPrice1e8) revert PriceAboveCeiling();
    }

    /**
     * @dev Pull `_tokenAmount` from `msg.sender`, reverting if the received amount differs (fee-on-transfer).
     */
    function _pullExactPayment(address _paymentToken, uint256 _tokenAmount) internal {
        uint256 balanceBefore = IERC20(_paymentToken).balanceOf(address(this));
        IERC20(_paymentToken).safeTransferFrom(msg.sender, address(this), _tokenAmount);
        uint256 balanceAfter = IERC20(_paymentToken).balanceOf(address(this));
        if (balanceAfter - balanceBefore != _tokenAmount) revert TransferAmountMismatch();
    }

    /**
     * @dev Calculate USD cost in 1e8 units
     * @param _amount Amount of shares (smallest units)
     * @param _priceUsdPerShare USD price per 1 full share (10^shareDecimals), 8 decimals (1e8)
     * @param _shareDecimals Decimals of the share token
     * @return USD cost in 1e8 units
     */
    function _calculateUsdCost(uint256 _amount, uint256 _priceUsdPerShare, uint8 _shareDecimals)
        internal
        pure
        returns (uint256)
    {
        uint256 scale = 10 ** uint256(_shareDecimals);
        // Use mulDiv to avoid overflow and maintain precision.
        return Math.mulDiv(_amount, _priceUsdPerShare, scale, Math.Rounding.Up);
    }
}
