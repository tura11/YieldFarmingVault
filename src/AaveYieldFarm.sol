// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {IAaveLendingPool} from "./interfaces/AaveLendingPool.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract AaveYieldFarm is IStrategy, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error AaveYieldFarm__ZeroDeposit();
    error AaveYieldFarm__ZeroAmount();
    error AaveYieldFarm__InsufficientBalance();
    error AaveYieldFarm__OnlyVault();
    error AaveYieldFarm__StrategyInactive();

    event Deposited(uint256 amount, uint256 timestamp);
    event Withdrawn(uint256 amount, uint256 timestamp);
    event Harvested(uint256 profit, uint256 timestamp);
    event EmergencyWithdrawal(uint256 amount, uint256 timestamp);

    IERC20 public immutable assetToken;
    IAaveLendingPool public immutable lendingPool;
    address public vault;
    IERC20 public aToken; // aUSDC
    bool public active;

    uint256 public totalDeposited;

    modifier onlyVault() {
        if (msg.sender != vault) revert AaveYieldFarm__OnlyVault();
        _;
    }

    modifier whenActive() {
        if (!active) revert AaveYieldFarm__StrategyInactive();
        _;
    }

    constructor(address _asset, address _lendingPool, address _aToken, address _vault) Ownable(msg.sender) {
        assetToken = IERC20(_asset);
        lendingPool = IAaveLendingPool(_lendingPool);
        aToken = IERC20(_aToken);
        vault = _vault;
        active = true;

        assetToken.approve(_lendingPool, type(uint256).max);
    }

    /**
     * @notice Deposit USDC to Aave
     * @param amount Amount to deposit
     * @return Amount deposited
     */
    function deposit(uint256 amount) external override onlyVault whenActive nonReentrant returns (uint256) {
        if (amount == 0) revert AaveYieldFarm__ZeroDeposit();

        assetToken.safeTransferFrom(vault, address(this), amount);

        // 2. Deposit to Aave
        lendingPool.deposit(address(assetToken), amount, address(this), 0);

        // 3. Update tracking
        totalDeposited += amount;

        emit Deposited(amount, block.timestamp);

        return amount;
    }

    /**
     * @notice Withdraw USDC from Aave
     * @param amount Amount to withdraw
     * @return Amount withdrawn
     */
    function withdraw(uint256 amount) external override onlyVault nonReentrant returns (uint256) {
        if (amount == 0) revert AaveYieldFarm__ZeroAmount();

        uint256 available = balanceOf();
        if (amount > available) revert AaveYieldFarm__InsufficientBalance();
        // Withdraw from Aave to vault
        uint256 withdrawn = lendingPool.withdraw(address(assetToken), amount, vault);

        // Update tracking
        if (totalDeposited >= withdrawn) {
            totalDeposited -= withdrawn;
        } else {
            totalDeposited = 0;
        }

        emit Withdrawn(withdrawn, block.timestamp);
        return withdrawn;
    }

    /**
     * @notice Harvest yield from Aave
     * @return Profit harvested
     */
    function harvest() external override onlyVault whenActive returns (uint256) {
        uint256 currentBalance = balanceOf();

        // Profit = current balance - what we deposited
        uint256 profit = 0;
        if (currentBalance > totalDeposited) {
            profit = currentBalance - totalDeposited;
        }

        if (profit > 0) {
            // Withdraw profit to vault
            lendingPool.withdraw(address(assetToken), profit, vault);
        }

        emit Harvested(profit, block.timestamp);
        return profit;
    }

    /**
     * @notice Get balance of aUSDC (our deposited amount + yield)
     * @return Balance in USDC
     */
    function balanceOf() public view override returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    /**
     * @notice Get asset address (USDC)
     * @return Asset address
     */
    function asset() external view override returns (address) {
        return address(assetToken);
    }

    /**
     * @notice Check if strategy is active
     * @return Active status
     */
    function isActive() external view override returns (bool) {
        return active;
    }

    /**
     * @notice Emergency withdraw all funds
     */
    function emergencyWithdraw() external override onlyOwner nonReentrant {
        active = false;

        uint256 balance = balanceOf();

        if (balance > 0) {
            // Withdraw everything from Aave to vault
            lendingPool.withdraw(address(assetToken), type(uint256).max, vault);
        }

        emit EmergencyWithdrawal(balance, block.timestamp);
    }

    /**
     * @notice Activate strategy
     */
    function activateStrategy() external onlyOwner {
        active = true;
    }

    /**
     * @notice Deactivate strategy
     */
    function deactivateStrategy() external onlyOwner {
        active = false;
    }

    /**
     * @notice Update vault address
     */
    function updateVault(address _newVault) external onlyOwner {
        require(_newVault != address(0), "Invalid vault");
        vault = _newVault;
    }
    /**
     * @notice Get asset token address
     * @return Asset token (USDC)
     */

    function getAssetToken() external view returns (address) {
        return address(assetToken);
    }

    /**
     * @notice Get lending pool address
     * @return Lending pool address
     */
    function getLendingPool() external view returns (address) {
        return address(lendingPool);
    }
}
