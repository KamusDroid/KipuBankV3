// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {KipuBankV3} from "../src/KipuBankV3.sol";

/**
 * @title DeployKipuBankV3
 * @notice Script para desplegar KipuBankV3 en diferentes redes
 * @dev Uso: forge script script/Deploy.s.sol:DeployKipuBankV3 --rpc-url $RPC_URL --broadcast
 */
contract DeployKipuBankV3 is Script {
    
    // Direcciones en Sepolia
    address constant USDC_SEPOLIA = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address constant UNISWAP_V2_ROUTER_SEPOLIA = 0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008;
    address constant ETH_USD_PRICE_FEED_SEPOLIA = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    
    // Parámetros de configuración
    uint256 constant BANK_CAP = 1_000_000 * 1e6; // 1 millón de USDC

    function run() external returns (KipuBankV3) {
        // Obtener la clave privada del deployer
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("========================================");
        console.log("Deploying KipuBankV3");
        console.log("========================================");
        console.log("Deployer address:", deployer);
        console.log("Deployer balance:", deployer.balance / 1e18, "ETH");
        console.log("");
        
        // Validar balance suficiente
        require(deployer.balance > 0.01 ether, "Insufficient ETH for deployment");
        
        // Iniciar broadcast
        vm.startBroadcast(deployerPrivateKey);
        
        // Desplegar contrato
        KipuBankV3 kipuBank = new KipuBankV3(
            deployer,                      // admin
            USDC_SEPOLIA,                 // usdc
            UNISWAP_V2_ROUTER_SEPOLIA,    // uniswapRouter
            ETH_USD_PRICE_FEED_SEPOLIA,   // ethUsdPriceFeed
            BANK_CAP                      // globalBankCap
        );
        
        vm.stopBroadcast();
        
        // Logging de información importante
        console.log("========================================");
        console.log("Deployment Successful!");
        console.log("========================================");
        console.log("KipuBankV3 address:", address(kipuBank));
        console.log("Admin:", deployer);
        console.log("USDC:", USDC_SEPOLIA);
        console.log("Uniswap V2 Router:", UNISWAP_V2_ROUTER_SEPOLIA);
        console.log("ETH/USD Price Feed:", ETH_USD_PRICE_FEED_SEPOLIA);
        console.log("Bank Cap:", BANK_CAP / 1e6, "USDC");
        console.log("");
        console.log("Next steps:");
        console.log("1. Verify contract on Etherscan:");
        console.log("   forge verify-contract", address(kipuBank), "src/KipuBankV3.sol:KipuBankV3 --chain sepolia");
        console.log("2. Add token support:");
        console.log("   cast send", address(kipuBank), '"supportToken(address,uint256,uint256,address)" <TOKEN> <WITHDRAWAL_LIMIT> <DEPOSIT_LIMIT> <PRICE_FEED>');
        console.log("========================================");
        
        return kipuBank;
    }
    
    /**
     * @notice Deploy para testing local (Anvil)
     */
    function deployLocal() external returns (KipuBankV3) {
        address deployer = msg.sender;
        
        console.log("Deploying locally with mock addresses...");
        
        vm.startBroadcast();
        
        // Usar addresses mock para testing local
        KipuBankV3 kipuBank = new KipuBankV3(
            deployer,
            address(0x1), // Mock USDC
            address(0x2), // Mock Router
            address(0x3), // Mock Price Feed
            BANK_CAP
        );
        
        vm.stopBroadcast();
        
        console.log("Local deployment at:", address(kipuBank));
        
        return kipuBank;
    }
}