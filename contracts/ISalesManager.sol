//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

/**
 * @title ISalesManager
 * @author CoinDistrict
 * @dev Version: 1.0.0
 * @notice Public ABI for primary sales of ERC-3643 shares against ERC20 payment tokens
 * @dev
 * - Amounts for shares are expressed in the share token's smallest units (10^decimals)
 * - `priceUsdPerShare` must be provided in USD scaled to 8 decimals (1e8) per 1 full share (10^shareDecimals)
 *   e.g. `$5` should be passed as `5 * 100_000_000`
 *   If you start from a payment token amount with `d` decimals (e.g. USDC has 6), convert with
 *   `priceUsdPerShare = tokenAmount * 10^(8 - d)` so the value matches Chainlink's 1e8 pricing
 * - Prices are converted to payment tokens using Chainlink oracles at purchase time
 * - For role values, see Governance.sol constants
 */
interface ISalesManager {
    error InvalidGovernance();
    error NotAuthorized();
    error EmergencyPausedErr();
    error EmergencyAlreadyPaused();
    error EmergencyNotPaused();
    error InvalidAddress();
    error NoPaymentTokens();
    error InvalidRecipient();
    error ZeroSupply();
    error ZeroPrice();
    error InvalidStart();
    error InvalidDeadline();
    error SaleNotStarted();
    error SaleEnded();
    error PaymentTokenNotAllowed();
    error OracleNotConfigured();
    error SupplyExceedsCap();
    error MaxPaymentExceeded();
    error SaleNotActive();
    error SalePausedErr();
    error SaleDoesNotExist();
    error AmountInvalid();
    error ZeroCost();
    error TransferAmountMismatch();
    error SaleAlreadyPaused();
    error SaleNotPaused();
    error InvalidFiatOrderReference();
    error FiatOrderReferenceAlreadyFulfilled();
    error UseWithdrawFundsForPaymentTokens();
    error LengthMismatch();
    error InvalidOracleDelay();
    error InvalidMaxPrice();
    error InvalidOracle();
    error InvalidPrice();
    error PriceNotUpdated();
    error StalePrice();
    error PriceAboveCeiling();

    /// @dev Sale configuration and accounting
    struct Sale {
        address share; // ERC-3643 share address
        address[] paymentTokensAllowed; // ERC20 payment tokens allowed for this sale
        address fundsRecipient; // address receiving proceeds
        uint256 remainingSupply; // remaining amount in share smallest units
        uint256 priceUsdPerShare; // USD price per 1 full share (10^shareDecimals), 8 decimals (1e8)
        uint64 start; // unix timestamp (seconds) when sale becomes active
        uint64 deadline; // unix timestamp (seconds) when sale ends
        uint8 shareDecimals; // cached decimals from the share token
        bool active; // whether the sale is active
        bool paused; // pausable flag (does not cancel the sale)
    }

    /// @notice Emitted when a share is purchased
    /// @param saleId The sale identifier
    /// @param buyer The msg.sender paying the payment token
    /// @param recipient The address receiving the minted shares
    /// @param paymentToken The payment token used for this purchase
    /// @param amount Amount of shares minted (smallest units)
    /// @param paidTokenAmount Payment token amount paid (smallest units)
    event SharePurchase(
        uint256 indexed saleId,
        address indexed buyer,
        address indexed recipient,
        address paymentToken,
        uint256 amount,
        uint256 paidTokenAmount
    );

    /// @notice Emitted when a new sale is created
    /// @param saleId The newly created sale identifier
    /// @param share The ERC-3643 token being sold
    /// @param paymentTokensAllowed The ERC20 payment tokens allowed for this sale
    /// @param fundsRecipient The treasury address receiving proceeds
    /// @param saleSupply Total initial sale supply (in share smallest units)
    /// @param priceUsdPerShare USD price per 1 full share (10^shareDecimals), 8 decimals (1e8)
    /// @param start Unix timestamp when the sale becomes active
    /// @param deadline Unix timestamp when the sale ends
    /// @param shareDecimals Cached decimals of the share token
    event SaleCreated(
        uint256 indexed saleId,
        address indexed share,
        address[] paymentTokensAllowed,
        address fundsRecipient,
        uint256 saleSupply,
        uint256 priceUsdPerShare,
        uint64 start,
        uint64 deadline,
        uint8 shareDecimals
    );

    /// @notice Emitted when a sale is cancelled (cannot be resumed)
    event SaleCancelled(uint256 indexed saleId);

    /// @notice Emitted when the funds recipient is changed for a sale
    /// @param saleId The sale identifier
    /// @param oldRecipient Previous recipient
    /// @param newRecipient New recipient
    event SaleFundsRecipientUpdated(uint256 indexed saleId, address oldRecipient, address newRecipient);

    /// @notice Emitted when the payment tokens allowed for a sale are updated
    /// @param saleId The sale identifier
    /// @param oldPaymentTokensAllowed Previous list of payment tokens
    /// @param newPaymentTokensAllowed New list of payment tokens
    event SalePaymentTokensAllowedUpdated(
        uint256 indexed saleId, address[] oldPaymentTokensAllowed, address[] newPaymentTokensAllowed
    );

    /// @notice Emitted when the USD price per share for a sale is updated
    /// @param saleId The sale identifier
    /// @param oldPriceUsdPerShare Previous USD price per share (1e8)
    /// @param newPriceUsdPerShare New USD price per share (1e8)
    event SalePriceUsdPerShareUpdated(uint256 indexed saleId, uint256 oldPriceUsdPerShare, uint256 newPriceUsdPerShare);

    /// @notice Emitted when the deadline for a sale is updated
    /// @param saleId The sale identifier
    /// @param oldDeadline Previous deadline timestamp
    /// @param newDeadline New deadline timestamp
    event SaleDeadlineUpdated(uint256 indexed saleId, uint64 oldDeadline, uint64 newDeadline);

    /// @notice Emitted when a sale is paused
    event SalePaused(uint256 indexed saleId);

    /// @notice Emitted when a sale is unpaused
    event SaleUnpaused(uint256 indexed saleId);

    /// @notice Emitted when an off-chain (fiat/OTC) order is fulfilled by the owner
    /// @param saleId The sale identifier
    /// @param recipient The address receiving the minted shares
    /// @param amount Amount of shares minted (smallest units)
    /// @param orderRef Off-chain reference identifier
    event FiatOrderFulfilled(
        uint256 indexed saleId, address indexed recipient, uint256 amount, bytes32 indexed orderRef
    );

    /// @notice Emitted when an address is added to or removed from the payment token allowlist
    /// @param paymentToken The ERC20 token address
    /// @param allowed Whether the token is allowed
    event PaymentTokenAllowed(address indexed paymentToken, bool allowed);

    /// @notice Emitted when a payment token oracle is set or updated
    /// @param paymentToken The ERC20 token address
    /// @param aggregator The Chainlink aggregator address (address(0) to remove)
    /// @param maxDelay Max accepted oracle staleness in seconds (0 when removed)
    /// @param maxPrice1e8 Max accepted normalized price in 1e8 (0 when removed)
    event PaymentTokenOracleSet(
        address indexed paymentToken, address aggregator, uint256 maxDelay, uint256 maxPrice1e8
    );

    /// @notice Emitted when funds are withdrawn to treasury or another recipient
    /// @param token The ERC20 token withdrawn
    /// @param to The recipient of the funds
    /// @param amount The amount transferred
    event FundsWithdrawn(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted when tokens are rescued via {rescueTokens}
    /// @param token The ERC20 token rescued
    /// @param to The recipient of the rescued tokens
    /// @param amount The amount transferred
    event TokensRescued(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted when the global emergency pause state is changed
    /// @param paused Whether the contract is now paused (true) or unpaused (false)
    event EmergencyPauseSet(bool paused);

    /// @notice Returns the total number of sales created so far
    function saleCount() external view returns (uint256);

    /// @notice Returns the sale configuration and current state
    /// @param saleId The sale identifier
    /// @return sale The sale configuration and current state
    function getSale(uint256 saleId) external view returns (Sale memory sale);

    /// @notice Total amount sold for a sale (smallest units)
    /// @param saleId The sale identifier
    /// @return sold Total minted amount via this sale so far
    function saleIdToSold(uint256 saleId) external view returns (uint256);

    /// @notice Get the total supply allocated for a sale (smallest units)
    /// @dev Calculated as remainingSupply + saleIdToSold
    /// @param saleId The sale identifier
    /// @return totalSupply Total supply allocated for this sale
    function getSaleTotalSupply(uint256 saleId) external view returns (uint256 totalSupply);

    /// @notice Get the remaining supply available for a sale (smallest units)
    /// @param saleId The sale identifier
    /// @return remainingSupply Remaining supply available for purchase
    function getSaleRemainingSupply(uint256 saleId) external view returns (uint256 remainingSupply);

    /// @notice Returns whether a payment token is allowlisted
    /// @param token The ERC20 payment token address
    function isPaymentTokenAllowed(address token) external view returns (bool);

    /// @notice Create a new sale for a given ERC-3643 token
    /// @dev Reverts if `_start <= block.timestamp`, `_deadline <= _start`, `_saleSupply == 0`, `_priceUsdPerShare == 0`, or `_paymentTokensAllowed` is empty
    /// @dev All payment tokens in `_paymentTokensAllowed` must be globally allowlisted and have oracles configured
    /// @param _share ERC-3643 share address (manager must be agent on this token)
    /// @param _paymentTokensAllowed ERC20 payment tokens allowed for this sale (must be non-empty and all allowlisted with oracles)
    /// @param _fundsRecipient Address receiving proceeds
    /// @param _saleSupply Total sale supply (smallest units)
    /// @param _priceUsdPerShare USD price per 1 full share (10^shareDecimals), 8 decimals (1e8)
    /// @param _start Unix timestamp when sale becomes active (must be in the future)
    /// @param _deadline Unix timestamp when sale ends (must be after _start)
    /// @return saleId The created sale identifier
    function createSale(
        address _share,
        address[] calldata _paymentTokensAllowed,
        address _fundsRecipient,
        uint256 _saleSupply,
        uint256 _priceUsdPerShare,
        uint64 _start,
        uint64 _deadline
    ) external returns (uint256 saleId);

    /// @notice Buy shares from an active sale
    /// @dev Requires ERC20 allowance for the calculated payment amount. Mints shares to `_to` on success.
    /// @dev Payment token must be allowlisted and have an oracle configured.
    /// @param _saleId The sale identifier
    /// @param _amount Amount to buy (smallest units)
    /// @param _to Recipient of minted shares
    /// @param _paymentToken The payment token to use for this purchase (must be allowlisted with oracle)
    /// @param _maxPayment Maximum payment token amount willing to pay (slippage protection)
    function buy(uint256 _saleId, uint256 _amount, address _to, address _paymentToken, uint256 _maxPayment) external;

    /**
     * @notice Cancel a sale permanently
     * @param _saleId The sale identifier
     */
    function cancelSale(uint256 _saleId) external;

    /**
     * @notice Pause a sale (can be resumed with `unpauseSale`)
     * @param _saleId The sale identifier
     */
    function pauseSale(uint256 _saleId) external;

    /**
     * @notice Unpause a previously paused sale
     * @param _saleId The sale identifier
     */
    function unpauseSale(uint256 _saleId) external;

    /**
     * @notice Update the funds recipient for a sale
     * @param _saleId The sale identifier
     * @param _newRecipient The new recipient address
     */
    function updateSaleFundsRecipient(uint256 _saleId, address _newRecipient) external;

    /**
     * @notice Replace the payment tokens allowed for a sale
     * @dev All tokens in `_newPaymentTokensAllowed` must be globally allowlisted and have oracles configured
     * @param _saleId The sale identifier
     * @param _newPaymentTokensAllowed The new list of payment tokens allowed for this sale
     */
    function updateSalePaymentTokensAllowed(uint256 _saleId, address[] calldata _newPaymentTokensAllowed) external;

    /**
     * @notice Update the USD price per share for a sale
     * @param _saleId The sale identifier
     * @param _newPriceUsdPerShare The new USD price per share (1e8) for a full share (10^shareDecimals)
     */
    function updateSalePriceUsdPerShare(uint256 _saleId, uint256 _newPriceUsdPerShare) external;

    /**
     * @notice Update the deadline for a sale
     * @param _saleId The sale identifier
     * @param _newDeadline The new deadline timestamp (must be in the future)
     */
    function updateSaleDeadline(uint256 _saleId, uint256 _newDeadline) external;

    /**
     * @notice Fulfill an off-chain (fiat/OTC) order without ERC20 transfer
     * @dev Mints and updates accounting; applicable compliance checks still apply via token
     * @param _saleId The sale identifier
     * @param _amount Amount to mint (smallest units)
     * @param _to Recipient of minted shares
     * @param _reference Off-chain order reference
     */
    function fulfillFiatOrder(uint256 _saleId, uint256 _amount, address _to, bytes32 _reference) external;

    /**
     * @notice Recover any ERC20 mistakenly sent to this contract
     * @param _erc20 The ERC20 token address
     * @param _to Recipient of recovered tokens
     * @param _amount Amount to transfer
     */
    function rescueTokens(address _erc20, address _to, uint256 _amount) external;

    /**
     * @notice Allow or disallow a payment token for use in new sales (allowlist is always enforced)
     * @param paymentToken The ERC20 token address
     * @param allowed True to allow, false to disallow
     */
    function setAllowedPaymentToken(address paymentToken, bool allowed) external;

    /**
     * @notice Withdraw funds for allowlisted tokens
     * @dev Only allowlisted tokens can be withdrawn
     * @param tokens The ERC20 token addresses (must be allowlisted)
     * @param to Recipient of withdrawn funds
     * @param amounts Amounts to withdraw per token; must match `tokens.length`
     */
    function withdrawFunds(address[] calldata tokens, address to, uint256[] calldata amounts) external;

    /**
     * @notice Set or update the Chainlink oracle aggregator and bounds for a payment token
     * @dev Set aggregator to address(0) to remove (clears bounds too)
     * @param paymentToken The ERC20 payment token address
     * @param aggregator The Chainlink AggregatorV3Interface address (address(0) to remove)
     * @param maxDelay Max accepted oracle staleness in seconds, in [60, 86400]
     * @param maxPrice1e8 Max accepted normalized price (1e8); must be > 0 when aggregator is set
     */
    function setPaymentTokenOracle(address paymentToken, address aggregator, uint256 maxDelay, uint256 maxPrice1e8)
        external;

    /**
     * @notice Pause all sales immediately
     * @dev When paused, all buy() and fulfillFiatOrder() operations are blocked
     */
    function setEmergencyPause() external;

    /**
     * @notice Unpause all sales
     */
    function unsetEmergencyPause() external;

    /// @notice Get the current global emergency pause state
    /// @return paused Whether the contract is globally paused
    function emergencyPaused() external view returns (bool paused);

    /// @notice Get the oracle aggregator address for a payment token
    /// @param paymentToken The ERC20 payment token address
    /// @return aggregator The Chainlink aggregator address, or address(0) if not set
    function paymentTokenToUsdAggregator(address paymentToken) external view returns (address aggregator);

    /// @notice Max accepted oracle staleness (seconds) for a payment token
    function paymentTokenMaxDelay(address paymentToken) external view returns (uint256);

    /// @notice Max accepted normalized price (1e8) for a payment token
    function paymentTokenMaxPrice1e8(address paymentToken) external view returns (uint256);
}
