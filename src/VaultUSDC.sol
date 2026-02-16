// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";

/**
 * @title VaultUSDC
 * @author [Tura11]
 * @notice ERC4626 compliant vault for USDC deposits with automated strategy management
 * @dev Implements vault functionality with management fees, deposit/withdraw limits, and automatic rebalancing
 */
contract VaultUSDC is ERC4626, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Custom Errors
    error VaultUSDC__DepositExceedsLimit();
    error VaultUSDC__WithdrawExceedsLimit();
    error VaultUSDC__ZeroAmount();
    error VaultUSDC__InvalidReceiver();
    error VaultUSDC__InsufficientBalance();
    error VaultUSDC__TransferFailed();
    error VaultUSDC__VaultPaused();
    error VaultUSDC__InvalidUserAddress();
    error VaultUSDC__NoStrategySet();
    error VaultUSDC__InsufficientStrategyLiquidity();
    error VaultUSDC__NoShares();

    /**
     * @notice Emitted when a user deposits assets into the vault
     * @param user Address that initiated the deposit
     * @param receiver Address that received the shares
     * @param assetsDeposited Total assets deposited (including fees)
     * @param sharesReceived Amount of shares minted to receiver
     * @param managementFeeCharged Fee amount charged for the deposit
     * @param timestamp Block timestamp of the deposit
     */
    event DepositExecuted(
        address indexed user,
        address indexed receiver,
        uint256 assetsDeposited,
        uint256 sharesReceived,
        uint256 managementFeeCharged,
        uint256 timestamp
    );

    /**
     * @notice Emitted when assets are withdrawn from the vault
     * @param user Address that initiated the withdrawal
     * @param receiver Address that received the assets
     * @param shareOwner Address whose shares were burned
     * @param assetsWithdrawn Amount of assets withdrawn
     * @param sharesBurned Amount of shares burned
     * @param timestamp Block timestamp of the withdrawal
     */
    event WithdrawalExecuted(
        address indexed user,
        address indexed receiver,
        address indexed shareOwner,
        uint256 assetsWithdrawn,
        uint256 sharesBurned,
        uint256 timestamp
    );

    /**
     * @notice Emitted when vault parameters are updated
     * @param oldMaxDeposit Previous maximum deposit limit
     * @param newMaxDeposit New maximum deposit limit
     * @param oldMaxWithdraw Previous maximum withdrawal limit
     * @param newMaxWithdraw New maximum withdrawal limit
     * @param oldManagementFee Previous management fee in basis points
     * @param newManagementFee New management fee in basis points
     */
    event VaultParametersUpdated(
        uint256 oldMaxDeposit,
        uint256 newMaxDeposit,
        uint256 oldMaxWithdraw,
        uint256 newMaxWithdraw,
        uint256 oldManagementFee,
        uint256 newManagementFee
    );

    /**
     * @notice Emitted when an emergency action is performed
     * @param actionType Description of the emergency action
     * @param admin Address that performed the action
     * @param timestamp Block timestamp of the action
     */
    event EmergencyAction(string actionType, address indexed admin, uint256 timestamp);

    /// @notice Maximum amount that can be deposited in a single transaction (in asset decimals)
    uint256 public maxDepositLimit;

    /// @notice Maximum amount that can be withdrawn in a single transaction (in asset decimals)
    uint256 public maxWithdrawLimit;

    /// @notice Management fee charged on deposits in basis points (e.g., 200 = 2%)
    uint256 public managementFee;

    /// @notice Total amount of assets deposited (excluding fees)
    uint256 public totalDeposited;

    /// @notice Total management fees collected by the vault
    uint256 public totalFeesCollected;

    /// @notice Total number of unique users who have deposited
    uint256 public totalUsers;

    /// @notice Target liquidity to maintain in vault in basis points (e.g., 1500 = 15%)
    uint256 public targetLiquidityBPS = 1500; // 15%

    /// @notice Rebalance threshold in basis points - triggers rebalance if liquidity deviates by this amount
    uint256 public constant REBALANCE_THRESHOLD_BPS = 500; // 5%

    /// @notice Address of the strategy contract where excess funds are deployed
    address public strategy;

    /// @notice Timestamp of user's first deposit
    mapping(address => uint256) public userFirstDepositTime;

    /// @notice Total amount deposited by user (excluding fees)
    mapping(address => uint256) public userTotalDeposited;

    /// @notice Total amount withdrawn by user
    mapping(address => uint256) public userTotalWithdrawn;

    /// @notice User's cost basis for profit calculation
    mapping(address => uint256) public userCostBasis;

    /**
     * @notice Validates that the provided amount is not zero
     * @param amount The amount to validate
     */
    modifier validAmount(uint256 amount) {
        if (amount == 0) revert VaultUSDC__ZeroAmount();
        _;
    }

    /**
     * @notice Validates that the provided address is not zero address
     * @param addr The address to validate
     */
    modifier validAddress(address addr) {
        if (addr == address(0)) revert VaultUSDC__InvalidReceiver();
        _;
    }

    /**
     * @notice Constructs the VaultUSDC contract
     * @param _asset The ERC20 token that will be used as the vault's underlying asset
     * @dev Initializes with default limits: 1M USDC max deposit, 100K USDC max withdraw, 2% management fee
     */
    constructor(ERC20 _asset) ERC4626(_asset) ERC20("VaultUSDC", "vUSDC") Ownable(msg.sender) {
        maxDepositLimit = 1000000e6;
        maxWithdrawLimit = 100000e6;
        managementFee = 200;
        totalDeposited = 0;
        totalFeesCollected = 0;
        totalUsers = 0;
    }

    /**
     * @notice Deposits assets into the vault and mints shares to receiver
     * @param assets Amount of assets to deposit
     * @param receiver Address that will receive the minted shares
     * @return shares Amount of shares minted
     * @dev Charges management fee on deposit, updates user tracking, and rebalances to strategy
     */
    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        validAmount(assets)
        validAddress(receiver)
        returns (uint256)
    {
        if (assets > maxDepositLimit) {
            revert VaultUSDC__DepositExceedsLimit();
        }

        uint256 assetsFee = (assets * managementFee) / 10000;
        uint256 assetsAfterFee = assets - assetsFee;

        if (assetsFee > 0) {
            IERC20(asset()).safeTransferFrom(msg.sender, owner(), assetsFee);//audit-low, what if owner has no receive or fallback fucntiuon?? better pull over push.
            totalFeesCollected += assetsFee;
        }

        uint256 shares = super.deposit(assetsAfterFee, receiver);

        // Track new users and update user statistics
        if (userCostBasis[receiver] == 0) {
            totalUsers++;
            userFirstDepositTime[receiver] = block.timestamp;
        }

        userCostBasis[receiver] += assetsAfterFee;
        userTotalDeposited[receiver] += assetsAfterFee;
        totalDeposited += assetsAfterFee;

        // Automatically rebalance excess funds to strategy
        _rebalanceToStrategy();

        emit DepositExecuted(msg.sender, receiver, assets, shares, assetsFee, block.timestamp);

        return shares;
    }

    /**
     * @notice Rebalances vault funds to strategy to maintain target liquidity
     * @dev Sends excess funds above target liquidity to the strategy contract
     */
    function _rebalanceToStrategy() public {audith-high, should be intreal
        if (strategy == address(0)) {
            revert VaultUSDC__NoStrategySet();
        }

        uint256 vaultBalance = IERC20(asset()).balanceOf(address(this));
        uint256 total = totalAssets();

        if (total == 0) {
            revert VaultUSDC__NoShares();
        }

        uint256 targetLiquidity = (total * targetLiquidityBPS) / 10000;

        if (vaultBalance > targetLiquidity) {
            uint256 toSend = vaultBalance - targetLiquidity;
            IERC20(asset()).approve(strategy, toSend);
            IStrategy(strategy).deposit(toSend);
        }
    }

    /**
     * @notice Withdraws assets from the vault by burning shares
     * @param assets Amount of assets to withdraw
     * @param receiver Address that will receive the assets
     * @param shareOwner Address whose shares will be burned
     * @return shares Amount of shares burned
     * @dev Pulls funds from strategy if vault balance is insufficient, updates user tracking
     */
    function withdraw(uint256 assets, address receiver, address shareOwner)
        public
        override
        nonReentrant
        whenNotPaused
        validAmount(assets)
        validAddress(receiver)
        returns (uint256)
    {
        if (assets > maxWithdrawLimit) {
            revert VaultUSDC__WithdrawExceedsLimit();
        }

        // Calculate shares to burn
        uint256 shares = previewWithdraw(assets);

        // Check allowance if caller is not the share owner
        if (msg.sender != shareOwner) {
            _spendAllowance(shareOwner, msg.sender, shares);
        }

        // Withdraw from strategy if vault doesn't have enough liquidity
        uint256 vaultBalance = IERC20(asset()).balanceOf(address(this));

        if (assets > vaultBalance) {
            uint256 needed = assets - vaultBalance;
            _withdrawFromStrategy(needed);
        }

        // Burn shares and transfer assets
        _burn(shareOwner, shares);
        IERC20(asset()).safeTransfer(receiver, assets);//audit-gigh possibility of reentrancy

        if (totalDeposited >= assets) {
            totalDeposited -= assets;
        } else {
            totalDeposited = 0;
        }

        _updateCostBasisOnWithdraw(shareOwner, shares);
        userTotalWithdrawn[shareOwner] += assets;

        // Rebalance from strategy if vault liquidity is too low
        _checkAndRebalanceFromStrategy();

        emit WithdrawalExecuted(msg.sender, receiver, shareOwner, assets, shares, block.timestamp);

        return shares;
    }

    /**
     * @notice Withdraws specified amount from the strategy
     * @param amount Amount of assets to withdraw from strategy
     * @dev Reverts if strategy doesn't have sufficient liquidity
     */
    function _withdrawFromStrategy(uint256 amount) public {//audith-high, should be intreal
        if (strategy == address(0)) {
            revert VaultUSDC__NoStrategySet();
        }

        uint256 withdrawn = IStrategy(strategy).withdraw(amount);

        if (withdrawn < amount) {
            revert VaultUSDC__InsufficientStrategyLiquidity();
        }
    }

    /**
     * @notice Checks if vault liquidity is below threshold and rebalances from strategy
     * @dev Pulls funds from strategy if current liquidity ratio falls below minimum threshold
     */
    function _checkAndRebalanceFromStrategy() public {//audith-high, should be intreal 
        if (strategy == address(0)) {
            revert VaultUSDC__NoStrategySet();
        }

        uint256 vaultBalance = IERC20(asset()).balanceOf(address(this));
        uint256 total = totalAssets();

        if (total == 0) return;

        uint256 currentRatio = (vaultBalance * 10000) / total;
        uint256 minRatio = targetLiquidityBPS - REBALANCE_THRESHOLD_BPS; // 10%

        if (currentRatio < minRatio) {
            uint256 targetAmount = (total * targetLiquidityBPS) / 10000;
            uint256 toWithdraw = targetAmount - vaultBalance;

            if (toWithdraw > 0) {
                try IStrategy(strategy).withdraw(toWithdraw) {
                    // Successfully withdrew from strategy
                } catch {
                    // Strategy doesn't have liquidity
                }
            }
        }
    }

    /**
     * @notice Updates user's cost basis proportionally when shares are burned
     * @param user Address of the user
     * @param sharesBurned Amount of shares being burned
     * @dev Maintains proportional cost basis for remaining shares
     */
    function _updateCostBasisOnWithdraw(address user, uint256 sharesBurned) internal {
        uint256 remainingShares = balanceOf(user);

        if (remainingShares == 0) {
            userCostBasis[user] = 0;
        } else {
            uint256 totalSharesBefore = remainingShares + sharesBurned;
            uint256 costReduction = (userCostBasis[user] * sharesBurned) / totalSharesBefore;
            userCostBasis[user] -= costReduction;
        }
    }

    /**
     * @notice Withdraws only the profit portion of user's position
     * @param receiver Address that will receive the withdrawn profit
     * @return shares Amount of shares burned
     * @dev Compares current value to cost basis and withdraws only gains
     */
    function withdrawProfit(address receiver) public whenNotPaused returns (uint256) {
        uint256 userShares = balanceOf(msg.sender);
        if (userShares == 0) {
            revert VaultUSDC__NoShares();
        }

        uint256 currentValue = convertToAssets(userShares);
        uint256 costBasis = userCostBasis[msg.sender];

        if (currentValue <= costBasis) {
            return 0;
        }

        uint256 profit = currentValue - costBasis;

        return withdraw(profit, receiver, msg.sender);
    }

    /**
     * @notice Returns total assets under management (vault + strategy)
     * @return Total amount of underlying assets controlled by the vault
     * @dev Overrides ERC4626 to include strategy balance
     */
    function totalAssets() public view override returns (uint256) {
        uint256 vaultBalance = IERC20(asset()).balanceOf(address(this));
        uint256 strategyBalance = 0;

        if (strategy != address(0)) {
            strategyBalance = IStrategy(strategy).balanceOf();
        }

        return vaultBalance + strategyBalance;
    }

    /**
     * @notice Manually triggers rebalancing to strategy
     * @dev Only callable by owner
     */
    function rebalance() external onlyOwner {
        _rebalanceToStrategy();
    }

    /**
     * @notice Updates the target liquidity ratio for the vault
     * @param newTargetBPS New target liquidity in basis points (500-5000, i.e., 5%-50%)
     * @dev Only callable by owner
     */
    function updateTargetLiquidity(uint256 newTargetBPS) external onlyOwner {
        require(newTargetBPS <= 5000, "Max 50%");
        require(newTargetBPS >= 500, "Min 5%");

        uint256 oldTarget = targetLiquidityBPS;
        targetLiquidityBPS = newTargetBPS;
    }

    /**
     * @notice Emergency function to withdraw all funds from strategy
     * @dev Only callable by owner when vault is paused
     */
    function emergencyWithdrawFromStrategy() external onlyOwner whenPaused {
        if (strategy != address(0)) {
            IStrategy(strategy).emergencyWithdraw();
        }
    }

    /**
     * @notice Sets the strategy address for the vault
     * @param _strategy Address of the strategy contract
     * @dev Only callable by owner, strategy cannot be zero address
     */
    function setStrategy(address _strategy) external onlyOwner {
        if (_strategy == address(0)) revert VaultUSDC__NoStrategySet();
        strategy = _strategy;
    }

    /**
     * @notice Removes the current strategy
     * @dev Only callable by owner
     */
    function clearStrategy() external onlyOwner {
        address oldStrategy = strategy;
        strategy = address(0);
    }

    /**
     * @notice Returns the share balance of a user
     * @param user Address to query
     * @return shares Amount of shares owned by the user
     */
    function getUserBalance(address user) public view returns (uint256 shares) {
        return balanceOf(user);
    }

    /**
     * @notice Returns comprehensive information about a user's position
     * @param user Address to query
     * @return totalShares Amount of shares owned
     * @return totalAssets Current value of shares in assets
     * @return totalDeposits Total amount deposited by user
     * @return totalWithdrawals Total amount withdrawn by user
     * @return firstDepositTime Timestamp of first deposit
     */
    function getUserInfo(address user)
        external
        view
        returns (
            uint256 totalShares,
            uint256 totalAssets,
            uint256 totalDeposits,
            uint256 totalWithdrawals,
            uint256 firstDepositTime
        )
    {
        totalShares = balanceOf(user);
        totalAssets = convertToAssets(totalShares);
        totalDeposits = userTotalDeposited[user];
        totalWithdrawals = userTotalWithdrawn[user];
        firstDepositTime = userFirstDepositTime[user];
    }

    /**
     * @notice Returns overall vault statistics
     * @return totalValueLocked Total assets under management
     * @return activeUsers Total number of users who have deposited
     * @return feesCollected Total management fees collected
     * @return currentMaxDeposit Current maximum deposit limit
     * @return currentMaxWithdraw Current maximum withdrawal limit
     * @return currentManagementFee Current management fee in basis points
     */
    function getVaultStats()
        external
        view
        returns (
            uint256 totalValueLocked,
            uint256 activeUsers,
            uint256 feesCollected,
            uint256 currentMaxDeposit,
            uint256 currentMaxWithdraw,
            uint256 currentManagementFee
        )
    {
        totalValueLocked = totalAssets();
        activeUsers = totalUsers;
        feesCollected = totalFeesCollected;
        currentMaxDeposit = maxDepositLimit;
        currentMaxWithdraw = maxWithdrawLimit;
        currentManagementFee = managementFee;
    }

    /**
     * @notice Checks if a deposit is valid and would succeed
     * @param user Address attempting to deposit
     * @param amount Amount to deposit
     * @dev Reverts with specific error if deposit would fail
     */
    function canDeposit(address user, uint256 amount) external view {
        if (paused()) {
            revert VaultUSDC__VaultPaused();
        }
        if (amount == 0) {
            revert VaultUSDC__ZeroAmount();
        }
        if (amount > maxDepositLimit) {
            revert VaultUSDC__DepositExceedsLimit();
        }
        if (user == address(0)) {
            revert VaultUSDC__InvalidUserAddress();
        }
    }

    /**
     * @notice Checks if a withdrawal is valid and would succeed
     * @param user Address attempting to withdraw
     * @param amount Amount to withdraw
     * @dev Reverts with specific error if withdrawal would fail
     */
    function canWithdraw(address user, uint256 amount) external view {
        if (paused()) {
            revert VaultUSDC__VaultPaused();
        }
        if (amount == 0) {
            revert VaultUSDC__ZeroAmount();
        }
        if (amount > maxWithdrawLimit) {
            revert VaultUSDC__WithdrawExceedsLimit();
        }
        uint256 userAssets = convertToAssets(balanceOf(user));
        if (amount > userAssets) {
            revert VaultUSDC__InsufficientBalance();
        }
    }

    /**
     * @notice Updates vault operational parameters
     * @param _maxDeposit New maximum deposit limit
     * @param _maxWithdraw New maximum withdrawal limit
     * @param _managementFee New management fee in basis points (max 1000 = 10%)
     * @dev Only callable by owner
     */
    function updateVaultParameters(uint256 _maxDeposit, uint256 _maxWithdraw, uint256 _managementFee)
        external
        onlyOwner
    {
        require(_managementFee <= 1000, "Fee cannot exceed 10%");

        emit VaultParametersUpdated(
            maxDepositLimit, _maxDeposit, maxWithdrawLimit, _maxWithdraw, managementFee, _managementFee
        );

        maxDepositLimit = _maxDeposit;
        maxWithdrawLimit = _maxWithdraw;
        managementFee = _managementFee;
    }

    /**
     * @notice Pauses all vault operations
     * @dev Only callable by owner
     */
    function pause() external onlyOwner {
        _pause();
        emit EmergencyAction("PAUSED", msg.sender, block.timestamp);
    }

    /**
     * @notice Unpauses vault operations
     * @dev Only callable by owner
     */
    function unpause() external onlyOwner {
        _unpause();
        emit EmergencyAction("UNPAUSED", msg.sender, block.timestamp);
    }

    /**
     * @notice Emergency withdrawal of all vault funds to owner
     * @dev Only callable by owner when vault is paused
     */
    function emergencyWithdraw() external onlyOwner whenPaused {
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        if (balance > 0) {
            IERC20(asset()).safeTransfer(owner(), balance);
            emit EmergencyAction("EMERGENCY_WITHDRAW", msg.sender, block.timestamp);
        }
    }
}
