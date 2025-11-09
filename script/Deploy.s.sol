// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {VaultUSDC} from "../src/VaultUSDC.sol";
import {AaveYieldFarm} from "../src/AaveYieldFarm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract DeployVault is Script {
    function run() external returns (VaultUSDC, AaveYieldFarm) {
        // Load deployer's private key from environment variable
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Sepolia testnet addresses
        address USDC_SEPOLIA = 0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8; // Mock USDC
        address AAVE_POOL_SEPOLIA = 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951;
        address AUSDC_SEPOLIA = 0x16dA4541aD1807f4443d92D26044C1147406EB80;

        vm.startBroadcast(deployerPrivateKey);

        // 1️⃣ Deploy the Vault contract
        console.log("Deploying VaultUSDC...");
        VaultUSDC vault = new VaultUSDC(ERC20(USDC_SEPOLIA));
        console.log("VaultUSDC deployed at:", address(vault));

        // 2️⃣ Deploy the Strategy contract
        console.log("Deploying AaveYieldFarm...");
        AaveYieldFarm strategy = new AaveYieldFarm(
            address(USDC_SEPOLIA),
            AAVE_POOL_SEPOLIA,
            AUSDC_SEPOLIA,
            address(vault)
        );
        console.log("AaveYieldFarm deployed at:", address(strategy));

        // 3️⃣ Link the Vault to the Strategy
        console.log("Connecting Vault to Strategy...");
        vault.setStrategy(address(strategy));
        console.log("Vault successfully linked to Strategy!");

        vm.stopBroadcast();
        //returning the deployed contracts
        return (vault, strategy);
    }
}
