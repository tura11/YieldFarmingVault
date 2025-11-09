// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {VaultUSDC} from "../../src/VaultUSDC.sol";
import {AaveYieldFarm} from "../../src/AaveYieldFarm.sol";
import {MockStrategy} from "../mocks/AaveStrategyMock.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockTokenA} from "../mocks/MockTokenA.sol";

/// @title VaultUSDC Invariant Test
/// @notice Invariant tests for VaultUSDC and its associated strategy.
/// @dev Uses Foundry invariant testing framework to validate protocol consistency.
contract VaultUSDCInvariantTest is Test {
    VaultUSDC public vault;
    AaveYieldFarm public strategy;
    ERC20Mock public usdc;
    MockTokenA public aToken;
    MockAavePool public lendingPool;

    address public constant OWNER = address(0x1);
    address public constant USER1 = address(0x2);
    address public constant USER2 = address(0x3);
    address public constant USER3 = address(0x4);

    VaultHandler public handler;

    /// @notice Initializes the test environment with mock tokens, vault, and strategy.
    function setUp() public {
        // === Initialize mocks ===
        usdc = new ERC20Mock();
        aToken = new MockTokenA();

        // Force decimals to 6 for both USDC and aToken
        vm.store(address(usdc), bytes32(uint256(8)), bytes32(uint256(6)));
        vm.store(address(aToken), bytes32(uint256(8)), bytes32(uint256(6)));

        // Mock Aave Pool (lending pool)
        lendingPool = new MockAavePool(address(usdc), address(aToken));

        // === Deploy Vault and Strategy ===
        vm.startPrank(OWNER);
        vault = new VaultUSDC(usdc);
        strategy = new AaveYieldFarm(address(usdc), address(lendingPool), address(aToken), address(vault));
        vm.stopPrank();

        // === Connect Vault to Strategy ===
        vm.startPrank(OWNER);
        vault.setStrategy(address(strategy));

        // Initialize invariant handler
        handler = new VaultHandler(vault, usdc, strategy, lendingPool);

        // Direct all invariant fuzz calls to the handler contract
        targetContract(address(handler));
        vm.stopPrank();

        // === Mint tokens for users and vault ===
        vm.startPrank(OWNER);
        usdc.mint(USER1, 10_000_000e6);
        usdc.mint(USER2, 10_000_000e6);
        usdc.mint(USER3, 10_000_000e6);
        usdc.mint(address(vault), 1_000_000e6);
        vm.stopPrank();

        // === Approve Vault for USDC spending ===
        vm.startPrank(USER1);
        usdc.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(USER2);
        usdc.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(USER3);
        usdc.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Invariant: Vault + Strategy balances must equal `totalAssets()`.
    function invariant_totalAssetsConsistency() public {
        uint256 vaultBalance = usdc.balanceOf(address(vault));
        uint256 strategyBalance = strategy.balanceOf();
        uint256 totalAssets = vault.totalAssets();

        assertEq(
            vaultBalance + strategyBalance,
            totalAssets,
            "Invariant violated: Vault + Strategy balances mismatch totalAssets()"
        );
    }

    /// @notice Invariant: No user can withdraw more assets than they own in shares.
    function invariant_userCannotWithdrawMoreThanBalance() public {
        uint256 user1Shares = vault.balanceOf(USER1);
        uint256 user1Assets = vault.convertToAssets(user1Shares);
        uint256 user2Shares = vault.balanceOf(USER2);
        uint256 user2Assets = vault.convertToAssets(user2Shares);
        uint256 user3Shares = vault.balanceOf(USER3);
        uint256 user3Assets = vault.convertToAssets(user3Shares);

        uint256 totalAssets = vault.totalAssets();
        assertLe(user1Assets, totalAssets, "User1 assets exceed total assets");
        assertLe(user2Assets, totalAssets, "User2 assets exceed total assets");
        assertLe(user3Assets, totalAssets, "User3 assets exceed total assets");
    }

    /// @notice Invariant: Strategy balance must not be less than the total deposited amount.
    /// @dev Profits may increase the strategy’s balance above the deposited amount.
    function invariant_strategyBalance() public {
        uint256 strategyBalance = strategy.balanceOf();
        uint256 totalDepositedToStrategy = strategy.totalDeposited();
        assertLe(
            totalDepositedToStrategy,
            strategyBalance,
            "Strategy deposited amount exceeds current balance"
        );
    }
}

/// @title VaultHandler
/// @notice Handler for invariant testing of VaultUSDC operations.
/// @dev Simulates user actions such as deposit, withdraw, rebalancing, and yield generation.
contract VaultHandler is Test {
    VaultUSDC public vault;
    ERC20Mock public usdc;
    AaveYieldFarm public strategy;
    MockAavePool public lendingPool;

    address[] public users = [address(0x2), address(0x3), address(0x4)];
    uint256 public totalDeposited;
    uint256 public totalWithdrawn;

    /// @param _vault The VaultUSDC contract instance.
    /// @param _usdc The mock USDC token used for deposits.
    /// @param _strategy The AaveYieldFarm strategy contract.
    /// @param _lendingPool The mock Aave lending pool.
    constructor(
        VaultUSDC _vault,
        ERC20Mock _usdc,
        AaveYieldFarm _strategy,
        MockAavePool _lendingPool
    ) {
        vault = _vault;
        usdc = _usdc;
        strategy = _strategy;
        lendingPool = _lendingPool;
    }

    /// @notice Simulates user deposits into the vault.
    /// @param amount The amount of USDC to deposit.
    /// @param userIndex Index of user (0–2) performing the action.
    function deposit(uint256 amount, uint256 userIndex) public {
        address user = users[userIndex % users.length];
        amount = bound(amount, 1e6, vault.maxDepositLimit());

        vm.startPrank(user);
        try vault.deposit(amount, user) {
            totalDeposited += amount;
        } catch {
            // Ignore failed deposits (e.g., paused or exceeded limits)
        }
        vm.stopPrank();
    }

    /// @notice Simulates user withdrawals from the vault.
    /// @param amount The amount of assets to withdraw.
    /// @param userIndex Index of user (0–2) performing the action.
    function withdraw(uint256 amount, uint256 userIndex) public {
        address user = users[userIndex % users.length];
        amount = bound(amount, 1e6, vault.maxWithdrawLimit());

        vm.startPrank(user);
        try vault.withdraw(amount, user, user) {
            totalWithdrawn += amount;
        } catch {
            // Ignore failed withdrawals
        }
        vm.stopPrank();
    }

    /// @notice Simulates users withdrawing only profits from the vault.
    /// @param userIndex Index of user (0–2) performing the action.
    function withdrawProfit(uint256 userIndex) public {
        address user = users[userIndex % users.length];

        vm.startPrank(user);
        try vault.withdrawProfit(user) {
            // Record profit withdrawal (ignored for simplicity)
        } catch {
            // Ignore failed profit withdrawals
        }
        vm.stopPrank();
    }

    /// @notice Simulates rebalancing of the vault by the owner.
    function rebalance() public {
        vm.prank(vault.owner());
        try vault.rebalance() {
            // Successful rebalance
        } catch {
            // Ignore failed rebalances
        }
    }

    /// @notice Simulates yield (profit) generation in the mock lending pool.
    /// @param amount The simulated profit amount.
    function simulateYield(uint256 amount) public {
        amount = bound(amount, 0, 100_000e6);
        vm.prank(vault.owner());
        lendingPool.simulateYield(address(strategy), amount);
    }

    /// @notice Pauses the vault (onlyOwner).
    function pause() public {
        vm.prank(vault.owner());
        try vault.pause() {} catch {}
    }

    /// @notice Unpauses the vault (onlyOwner).
    function unpause() public {
        vm.prank(vault.owner());
        try vault.unpause() {} catch {}
    }

    /// @notice Updates vault parameters like limits and management fee.
    /// @param maxDeposit New max deposit limit.
    /// @param maxWithdraw New max withdraw limit.
    /// @param managementFee New management fee (basis points).
    function updateVaultParameters(
        uint256 maxDeposit,
        uint256 maxWithdraw,
        uint256 managementFee
    ) public {
        maxDeposit = bound(maxDeposit, 1e6, 10_000_000e6);
        maxWithdraw = bound(maxWithdraw, 1e6, 1_000_000e6);
        managementFee = bound(managementFee, 0, 1000); // Max 10%

        vm.prank(vault.owner());
        try vault.updateVaultParameters(maxDeposit, maxWithdraw, managementFee) {} catch {}
    }

    /// @notice Returns all simulated user addresses.
    /// @return Array of users.
    function getUsers() public view returns (address[] memory) {
        return users;
    }
}
