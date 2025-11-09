// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockStrategy} from "../mocks/AaveStrategyMock.sol"; // adjust path if needed
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/**
 * @title MockStrategyTest
 * @notice Unit tests for MockStrategy contract
 */
contract MockStrategyTest is Test {
    MockStrategy public strategy;
    ERC20Mock public usdc;

    address public constant VAULT = address(0xBEEF);
    address public constant USER = address(0xCAFE);

    function setUp() public {
        // Create mock ERC20 token (USDC)
        usdc = new ERC20Mock();

        // Mint some tokens to the vault
        usdc.mint(VAULT, 1_000_000e6);

        // Deploy strategy
        strategy = new MockStrategy(address(usdc), VAULT);

        // Approve strategy to pull funds from vault
        vm.startPrank(VAULT);
        usdc.approve(address(strategy), type(uint256).max);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                DEPOSIT
    //////////////////////////////////////////////////////////////*/

    function testDepositUpdatesTotalDeposited() public {
        uint256 amount = 100_000e6;

        vm.startPrank(VAULT);
        usdc.transfer(address(strategy), amount); // simulate vault transfer
        uint256 returned = strategy.deposit(amount);
        vm.stopPrank();

        assertEq(returned, amount, "Deposit should return the same amount");
        assertEq(strategy.totalDeposited(), amount, "Total deposited should match amount");
    }

    function testDepositRevertsIfNotVault() public {
        vm.expectRevert(MockStrategy.AaveYieldFarm__OnlyVault.selector);
        strategy.deposit(1000);
    }

    function testDepositRevertsIfInactive() public {
        vm.startPrank(VAULT);
        strategy.emergencyWithdraw(); // sets active = false
        vm.expectRevert(MockStrategy.AaveYieldFarm__StrategyInactive.selector);
        strategy.deposit(1e6);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function testWithdrawPartialAmount() public {
        uint256 amount = 200_000e6;

        vm.startPrank(VAULT);
        usdc.transfer(address(strategy), amount);
        strategy.deposit(amount);
        uint256 beforeVault = usdc.balanceOf(VAULT);
        strategy.withdraw(100_000e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(VAULT), beforeVault + 100_000e6, "Vault should receive withdrawn amount");
        assertEq(strategy.totalDeposited(), 100_000e6, "Total deposited should decrease");
    }

    function testWithdrawRevertsIfNotVault() public {
        vm.expectRevert(MockStrategy.AaveYieldFarm__OnlyVault.selector);
        strategy.withdraw(1e6);
    }

    /*//////////////////////////////////////////////////////////////
                                HARVEST
    //////////////////////////////////////////////////////////////*/

    function testHarvestReturnsZero() public {
        vm.startPrank(VAULT);
        uint256 yield = strategy.harvest();
        vm.stopPrank();
        assertEq(yield, 0, "Mock harvest should always return 0");
    }

    function testHarvestRevertsIfNotVault() public {
        vm.expectRevert(MockStrategy.AaveYieldFarm__OnlyVault.selector);
        strategy.harvest();
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function testAssetAndIsActive() public {
        assertEq(strategy.asset(), address(usdc), "Asset should match");
        assertEq(strategy.isActive(), true, "Should start as active");
    }

    /*//////////////////////////////////////////////////////////////
                            EMERGENCY WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function testEmergencyWithdrawTransfersFundsAndDisables() public {
        vm.startPrank(VAULT);
        usdc.transfer(address(strategy), 50_000e6);
        strategy.deposit(50_000e6);
        vm.stopPrank();

        uint256 before = usdc.balanceOf(VAULT);
        strategy.emergencyWithdraw();

        assertEq(usdc.balanceOf(VAULT), before + 100_000e6, "Funds should be sent back to vault");
        assertEq(strategy.totalDeposited(), 0, "Total deposited should reset to 0");
        assertEq(strategy.isActive(), false, "Strategy should be deactivated");
    }

    /*//////////////////////////////////////////////////////////////
                            SIMULATE YIELD
    //////////////////////////////////////////////////////////////*/

    function testSimulateYieldIncreasesTotalDeposited() public {
        uint256 before = strategy.totalDeposited();
        strategy.simulateYield(10_000e6);
        assertEq(strategy.totalDeposited(), before + 10_000e6, "Simulated yield should increase totalDeposited");
    }
}
