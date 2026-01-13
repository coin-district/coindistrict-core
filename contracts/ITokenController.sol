//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

/**
 * @title ITokenController
 * @author CoinDistrict
 * @dev Version: 0.16.0
 * @notice Interface for the TokenController contract
 * @dev Provides granular, role- and capability-gated wrappers around ERC-3643 Token agent actions
 * @dev For role values, see Governance.sol constants
 */
interface ITokenController {
    /**
     * @notice Emitted when a token's capability bitmask is updated
     * @param token The ERC-3643 token address
     * @param caps The new capability bitmask
     */
    event TokenCapabilitiesSet(address indexed token, uint256 caps);

    /**
     * @notice Returns the capability bitmask configured for a token
     * @param token The ERC-3643 token address
     * @return caps The capability bitmask
     */
    function capabilitiesByToken(address token) external view returns (uint256 caps);

    /**
     * @notice Returns whether the pause capability is enabled for a token
     */
    function isPausable(address token) external view returns (bool);

    /**
     * @notice Returns whether the mint capability is enabled for a token
     */
    function isMintable(address token) external view returns (bool);

    /**
     * @notice Returns whether the burn capability is enabled for a token
     */
    function isBurnable(address token) external view returns (bool);

    /**
     * @notice Returns whether the freeze capability is enabled for a token
     */
    function isFreezable(address token) external view returns (bool);

    /**
     * @notice Returns whether the forceTransfer capability is enabled for a token
     */
    function isForceTransferable(address token) external view returns (bool);

    /**
     * @notice Returns whether the recovery capability is enabled for a token
     */
    function isRecoverable(address token) external view returns (bool);

    /**
     * @notice Set initial capability bitmask for a token
     * @dev Can only be called when capabilities are not yet initialized. INITIALIZED_BIT is automatically set.
     * @dev Caps can be 0 (no capabilities enabled), but INITIALIZED_BIT will still be set.
     * @param token The ERC-3643 token address
     * @param caps The capability bitmask to set (INITIALIZED_BIT will be automatically added)
     */
    function setTokenCapsInitial(address token, uint256 caps) external;

    /**
     * @notice Update capability bitmask for a token
     * @dev Can only be called when capabilities are already initialized (INITIALIZED_BIT is set).
     * @dev INITIALIZED_BIT is automatically preserved during updates.
     * @param token The ERC-3643 token address
     * @param caps The new capability bitmask (INITIALIZED_BIT will be automatically preserved)
     */
    function setTokenCaps(address token, uint256 caps) external;

    /**
     * @notice Pause the token
     * @dev Pause capability must be enabled for the token
     * @param token The ERC-3643 token address
     */
    function pause(address token) external;

    /**
     * @notice Unpause the token
     * @dev Pause capability must be enabled for the token
     * @param token The ERC-3643 token address
     */
    function unpause(address token) external;

    /**
     * @notice Mint tokens to a recipient (requires MINTER_ROLE and mint capability)
     * @param token The ERC-3643 token address
     * @param to Recipient address
     * @param amount Amount to mint (token smallest units)
     */
    function mint(address token, address to, uint256 amount) external;

    /**
     * @notice Burn tokens from a user
     * @dev Burn capability must be enabled for the token
     * @param token The ERC-3643 token address
     * @param user Address to burn from
     * @param amount Amount to burn (token smallest units)
     */
    function burn(address token, address user, uint256 amount) external;

    /**
     * @notice Force transfer tokens between addresses
     * @dev Force capability must be enabled for the token
     * @param token The ERC-3643 token address
     * @param from Sender address
     * @param to Recipient address
     * @param amount Amount to transfer (token smallest units)
     */
    function forceTransfer(address token, address from, address to, uint256 amount) external;

    /**
     * @notice Freeze or unfreeze a user's wallet
     * @dev Freeze capability must be enabled for the token
     * @param token The ERC-3643 token address
     * @param user The wallet to update
     * @param freeze True to freeze, false to unfreeze
     */
    function setFrozen(address token, address user, bool freeze) external;

    /**
     * @notice Recover tokens from a lost wallet to a new wallet
     * @dev Recovery capability must be enabled for the token
     * @param token The ERC-3643 token address
     * @param lostWallet The wallet considered lost
     * @param newWallet The replacement wallet
     * @param investorOnchainID The investor's ONCHAINID contract address
     */
    function recover(address token, address lostWallet, address newWallet, address investorOnchainID) external;
}
