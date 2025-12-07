// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {KipuBankV3} from "../src/KipuBankV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract KipuBankV3Test is Test {
    KipuBankV3 public kipuBank;
    
    address public admin;
    address public user1;
    address public user2;
    
    // Sepolia addresses
    address constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address constant UNISWAP_ROUTER = 0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008;
    address constant ETH_USD_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    
    uint256 constant BANK_CAP = 1_000_000 * 1e6; // 1M USDC
    uint256 constant SEPOLIA_FORK_BLOCK = 9679717;
    
    function setUp() public {
        // Fork Sepolia para tests
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"), SEPOLIA_FORK_BLOCK);
        
        admin = makeAddr("admin");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        
        // Deploy contrato
        vm.prank(admin);
        kipuBank = new KipuBankV3(
            admin,
            USDC,
            UNISWAP_ROUTER,
            ETH_USD_FEED,
            BANK_CAP
        );
        
        // Dar ETH a usuarios de prueba
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
    }
    
    // ============ DEPLOYMENT TESTS ============
    
    function test_Deployment() public view {
        assertEq(kipuBank.USDC(), USDC);
        assertEq(kipuBank.globalBankCap(), BANK_CAP);
        assertEq(kipuBank.totalUSDCBalance(), 0);
        assertTrue(kipuBank.hasRole(kipuBank.ADMIN_ROLE(), admin));
    }
    
    function test_InitialConfiguration() public view {
        // Verificar que ETH está configurado
        (bool supported, , , , , , ) = kipuBank.tokenConfigs(address(0));
        assertTrue(supported, "ETH should be supported");
        
        // Verificar que USDC está configurado
        (bool usdcSupported, , , , , , ) = kipuBank.tokenConfigs(USDC);
        assertTrue(usdcSupported, "USDC should be supported");
    }
    
    // ============ DEPOSIT ETH TESTS ============
    
    function test_DepositETH() public {
        uint256 depositAmount = 0.1 ether;
        uint256 minUSDCout = 0; // Para test, aceptamos cualquier output
        
        vm.startPrank(user1);
        
        uint256 balanceBefore = kipuBank.getUSDCBalance(user1);
        
        kipuBank.depositETH{value: depositAmount}(minUSDCout);
        
        uint256 balanceAfter = kipuBank.getUSDCBalance(user1);
        
        vm.stopPrank();
        
        assertGt(balanceAfter, balanceBefore, "Balance should increase");
        console.log("USDC received for 0.1 ETH:", balanceAfter);
    }
    
    function test_DepositETH_RevertsOnZeroAmount() public {
        vm.startPrank(user1);
        
        vm.expectRevert(KipuBankV3.ZeroAmount.selector);
        kipuBank.depositETH{value: 0}(0);
        
        vm.stopPrank();
    }
    
    function test_DepositETH_UpdatesDailyLimits() public {
        uint256 depositAmount = 0.1 ether;
        
        vm.startPrank(user1);
        kipuBank.depositETH{value: depositAmount}(0);
        vm.stopPrank();
        
        (uint256 depositsUsed, , , ) = kipuBank.getUserDailyLimits(user1);
        assertGt(depositsUsed, 0, "Daily deposits should be tracked");
    }
    
    // ============ WITHDRAW TESTS ============
    
    function test_WithdrawUSDC() public {
        // Primero depositar algo
        uint256 depositAmount = 0.1 ether;
        
        vm.startPrank(user1);
        kipuBank.depositETH{value: depositAmount}(0);
        
        uint256 balance = kipuBank.getUSDCBalance(user1);
        require(balance > 0, "Must have balance to test withdrawal");
        
        // Retirar la mitad
        uint256 withdrawAmount = balance / 2;
        
        uint256 usdcBalanceBefore = IERC20(USDC).balanceOf(user1);
        
        kipuBank.withdrawUSDC(withdrawAmount);
        
        uint256 usdcBalanceAfter = IERC20(USDC).balanceOf(user1);
        
        vm.stopPrank();
        
        assertEq(
            usdcBalanceAfter - usdcBalanceBefore,
            withdrawAmount,
            "USDC should be transferred"
        );
        assertEq(
            kipuBank.getUSDCBalance(user1),
            balance - withdrawAmount,
            "Internal balance should decrease"
        );
    }
    
    function test_WithdrawUSDC_RevertsOnInsufficientBalance() public {
        vm.startPrank(user1);
        
        vm.expectRevert("Insufficient balance");
        kipuBank.withdrawUSDC(1000e6);
        
        vm.stopPrank();
    }
    
    // ============ BANK CAP TESTS ============
    
    function test_BankCap_EnforcesLimit() public {
        // Intentar depositar más del bank cap
        // Para simplificar, actualizamos el bank cap a un valor bajo
        vm.prank(admin);
        kipuBank.setGlobalBankCap(100e6); // 100 USDC
        
        vm.startPrank(user1);
        
        // Primer depósito pequeño debe funcionar
        kipuBank.depositETH{value: 0.001 ether}(0);
        
        // Segundo depósito que excede debe fallar
        vm.expectRevert("Exceeds bank cap");
        kipuBank.depositETH{value: 10 ether}(0);
        
        vm.stopPrank();
    }
    
    function test_SetBankCap_OnlyAdmin() public {
        vm.prank(user1);
        
        vm.expectRevert();
        kipuBank.setGlobalBankCap(2_000_000e6);
    }
    
    function test_SetBankCap_Success() public {
        uint256 newCap = 2_000_000e6;
        
        vm.prank(admin);
        kipuBank.setGlobalBankCap(newCap);
        
        assertEq(kipuBank.globalBankCap(), newCap);
    }
    
    // ============ DAILY LIMITS TESTS ============
    
    function test_DailyLimits_ResetAfterDay() public {
        vm.startPrank(user1);
        
        // Hacer depósito hoy
        kipuBank.depositETH{value: 0.1 ether}(0);
        
        (uint256 depositsToday, , , ) = kipuBank.getUserDailyLimits(user1);
        assertGt(depositsToday, 0);
        
        // Avanzar 1 día
        skip(1 days);
        
        // Hacer otro depósito
        kipuBank.depositETH{value: 0.1 ether}(0);
        
        // Los límites deberían haberse reseteado
        (uint256 depositsAfterReset, , , ) = kipuBank.getUserDailyLimits(user1);
        
        vm.stopPrank();
        
        assertLt(depositsAfterReset, depositsToday + depositsToday, "Limits should reset");
    }
    
    // ============ PAUSE TESTS ============
    
    function test_EmergencyPause() public {
        vm.prank(admin);
        kipuBank.emergencyPause();
        
        assertTrue(kipuBank.paused());
        
        // Las operaciones deben fallar
        vm.startPrank(user1);
        
        vm.expectRevert();
        kipuBank.depositETH{value: 0.1 ether}(0);
        
        vm.stopPrank();
    }
    
    function test_EmergencyUnpause() public {
        vm.startPrank(admin);
        
        kipuBank.emergencyPause();
        assertTrue(kipuBank.paused());
        
        kipuBank.emergencyUnpause();
        assertFalse(kipuBank.paused());
        
        vm.stopPrank();
    }
    
    // ============ ROLE TESTS ============
    
    function test_RoleManagement() public {
        address newOperator = makeAddr("newOperator");
        
        vm.prank(admin);
        kipuBank.grantRole(kipuBank.OPERATOR_ROLE(), newOperator);
        
        assertTrue(kipuBank.hasRole(kipuBank.OPERATOR_ROLE(), newOperator));
    }
    
    function test_OnlyAdminCanGrantRoles() public {
        address newOperator = makeAddr("newOperator");
        
        vm.prank(user1);
        
        vm.expectRevert();
        kipuBank.grantRole(kipuBank.OPERATOR_ROLE(), newOperator);
    }
    
    // ============ VIEW FUNCTIONS TESTS ============
    
    function test_GetBankStats() public view {
        (uint256 totalBalance, uint256 bankCap, uint256 tokensCount) = kipuBank.getBankStats();
        
        assertEq(totalBalance, 0);
        assertEq(bankCap, BANK_CAP);
        assertGt(tokensCount, 0);
    }
    
    function test_EstimateUSDCOutput() public view {
        uint256 ethAmount = 1 ether;
        uint256 estimated = kipuBank.estimateUSDCOutput(address(0), ethAmount);
        
        assertGt(estimated, 0, "Should return estimated USDC");
        console.log("Estimated USDC for 1 ETH:", estimated);
    }
    
    // ============ INTEGRATION TESTS ============
    
    function test_FullDepositWithdrawCycle() public {
        uint256 depositAmount = 0.5 ether;
        
        vm.startPrank(user1);
        
        // 1. Depositar ETH
        kipuBank.depositETH{value: depositAmount}(0);
        uint256 balance = kipuBank.getUSDCBalance(user1);
        
        assertGt(balance, 0, "Should have USDC balance");
        
        // 2. Retirar todo
        uint256 usdcBefore = IERC20(USDC).balanceOf(user1);
        kipuBank.withdrawUSDC(balance);
        uint256 usdcAfter = IERC20(USDC).balanceOf(user1);
        
        assertEq(usdcAfter - usdcBefore, balance, "Should receive all USDC");
        assertEq(kipuBank.getUSDCBalance(user1), 0, "Internal balance should be 0");
        
        vm.stopPrank();
    }
    
    function test_MultipleUsersIndependentBalances() public {
        // User1 deposita
        vm.prank(user1);
        kipuBank.depositETH{value: 0.1 ether}(0);
        uint256 balance1 = kipuBank.getUSDCBalance(user1);
        
        // User2 deposita diferente cantidad
        vm.prank(user2);
        kipuBank.depositETH{value: 0.2 ether}(0);
        uint256 balance2 = kipuBank.getUSDCBalance(user2);
        
        assertGt(balance1, 0);
        assertGt(balance2, 0);
        assertGt(balance2, balance1);
        
        // User1 retira, no debería afectar a User2
        vm.prank(user1);
        kipuBank.withdrawUSDC(balance1);
        
        assertEq(kipuBank.getUSDCBalance(user1), 0);
        assertEq(kipuBank.getUSDCBalance(user2), balance2);
    }
    
    // ============ FUZZ TESTS ============
    
    function testFuzz_DepositETH(uint256 amount) public {
        // Limitar amount a rango razonable
        amount = bound(amount, 0.001 ether, 10 ether);
        
        vm.deal(user1, amount);
        
        vm.startPrank(user1);
        kipuBank.depositETH{value: amount}(0);
        vm.stopPrank();
        
        assertGt(kipuBank.getUSDCBalance(user1), 0);
    }
    
    function testFuzz_WithdrawUSDC(uint256 depositAmount, uint256 withdrawAmount) public {
        depositAmount = bound(depositAmount, 0.01 ether, 1 ether);
        
        vm.deal(user1, depositAmount);
        
        vm.startPrank(user1);
        
        kipuBank.depositETH{value: depositAmount}(0);
        uint256 balance = kipuBank.getUSDCBalance(user1);
        
        withdrawAmount = bound(withdrawAmount, 0, balance);
        
        if (withdrawAmount > 0) {
            kipuBank.withdrawUSDC(withdrawAmount);
            assertEq(kipuBank.getUSDCBalance(user1), balance - withdrawAmount);
        }
        
        vm.stopPrank();
    }
}