# KipuBankV3 – Banco DeFi USDC con Uniswap V2

KipuBankV3 es un contrato bancario DeFi que:

- Acepta **ETH, USDC y cualquier ERC20** soportado por Uniswap V2.  
- **Swapea todo a USDC** usando el router de Uniswap V2.  
- Mantiene los balances de los usuarios **solo en USDC**.  
- Aplica límites por usuario, por token y un `globalBankCap`.  
- Integra Chainlink para precios y Uniswap para enrutar tokens.  
- Usa seguridad avanzada: `ReentrancyGuard`, `Pausable`, slippage, deadlines y roles.

Este README está diseñado para que **desarrolladores backend o frontend** puedan integrar el contrato fácilmente.

---

## 📌 Índice

1. [Arquitectura General](#arquitectura-general)  
2. [Despliegue](#despliegue)  
3. [Interacción desde Frontend](#interacción-desde-frontend)  
4. [Funciones Principales](#funciones-principales)  
5. [Lecturas Útiles para UI (Views)](#lecturas-útiles-para-ui-views)  
6. [Ejemplos con ethers.js](#ejemplos-con-ethersjs)  
7. [Roles y Permisos](#roles-y-permisos)  
8. [Límites y Seguridad](#límites-y-seguridad)  
9. [Estructura del Proyecto](#estructura-del-proyecto)  
10. [Notas para Integradores Frontend](#notas-para-integradores-frontend)

---

## 🧱 Arquitectura General

- **Contrato principal:** `KipuBankV3.sol`  
- **Unidades:** Todos los valores de usuario se almacenan en **USDC (6 decimales)**.  
- **Integraciones:**
  - Uniswap V2 Router (para swaps).
  - Chainlink Price Feeds.
  - OpenZeppelin: AccessControl, IERC20, SafeERC20, ReentrancyGuard, Pausable.

### Flujo general de depósito:

1. Usuario envía ETH o ERC20.
2. El contrato **swapea automáticamente a USDC** mediante Uniswap.
3. Acredita el resultado en `usdcBalances[user]`.

---

## 🚀 Despliegue

### 1. Instalar dependencias

```bash
forge install openzeppelin/openzeppelin-contracts
forge install foundry-rs/forge-std
```

### 2. Build

```bash
forge build
```

### 3. Ejecutar Script de Deploy

```bash
forge script script/DeployKipuBankV3.s.sol:DeployKipuBankV3     --rpc-url $RPC_URL     --broadcast     --verify
```

### Configurar antes de desplegar:

- Dirección de USDC  
- Router Uniswap V2  
- WETH  
- Price Feed ETH/USD  
- `globalBankCap` inicial  
- Tokens soportados  

---

## 🖥 Interacción desde Frontend

### Cómo funciona para la UI

- Los usuarios **siempre verán su saldo en USDC**.  
- Al depositar con cualquier token, el frontend debe:
  1. Pedir approve si es ERC20.  
  2. Calcular `minUSDCout` para proteger del slippage.  
  3. Mostrar la estimación de USDC recibido.  

- Retiros:  
  El usuario siempre retira **USDC**, no necesita elegir token.

---

## 🔧 Funciones Principales

### 1. Depositar ETH

```solidity
function depositETH(uint256 minUSDCout)
    external
    payable;
```

- `msg.value` = monto de ETH.
- Swappea a USDC automáticamente.
- `minUSDCout` previene slippage.

---

### 2. Depositar Tokens ERC20

```solidity
function depositToken(
    address token,
    uint256 amount,
    uint256 minUSDCout
) external;
```

Flujo UI:

1. `approve(KipuBankV3, amount)`
2. `depositToken(token, amount, minUSDCout)`

---

### 3. Retirar USDC

```solidity
function withdrawUSDC(uint256 amount) external;
```

- Siempre retira USDC.
- Reduce el `usdcBalances[user]`.

---

## 🔍 Lecturas útiles para UI (Views)

### Saldo USDC del usuario

```solidity
function usdcBalances(address user) external view returns (uint256);
```

### Tokens soportados

```solidity
function getSupportedTokens() external view returns (address[] memory);
```

### Configuración de token

```solidity
function tokenConfigs(address token) external view returns (TokenConfig memory);
```

Incluye:  
- depositLimit  
- withdrawalLimit  
- decimals  
- priceFeed  
- supported  

### Límites diarios

```solidity
function userDailyLimits(address user) external view returns (UserDailyLimits memory);
```

### Estadísticas globales

```solidity
function getBankStats()
    external
    view
    returns (uint256 cap, uint256 total);
```

---

## 🧪 Ejemplos con ethers.js

### Instanciar contrato

```js
const kipuBank = new ethers.Contract(address, abi, signer);
```

---

### Depositar ETH

```js
await kipuBank.depositETH(minUSDCout, {
    value: ethers.utils.parseEther("0.1")
});
```

---

### Depositar ERC20

```js
await erc20.approve(kipuBank.address, amount);
await kipuBank.depositToken(tokenAddress, amount, minUSDCout);
```

---

### Retirar USDC

```js
await kipuBank.withdrawUSDC(ethers.utils.parseUnits("50", 6));
```

---

## 🛡 Roles y Permisos

| Rol | Funciones |
|-----|-----------|
| **ADMIN_ROLE** | Pausar, despausar, emergencyWithdraw |
| **OPERATOR_ROLE** | Agregar tokens soportados, ajustar límites |
| **RISK_MANAGER_ROLE** | Configurar parámetros de riesgo |

---

## ⚠ Límites y Seguridad

- **globalBankCap**: capacidad máxima del banco en USDC.  
- **Límites diarios por usuario**: depósitos y retiros.  
- **Slippage**: requiere `minUSDCout`.  
- **ReentrancyGuard**: protege depósitos y retiros.  
- **Pausable**: admins pueden pausar el protocolo.  

---

## 📁 Estructura del Proyecto

```
src/
  KipuBankV3.sol
  

script/
  DeployKipuBankV3.s.sol
  

test/
  KipuBankV3.t.sol
  

foundry.toml
README.md
```

---

## 📝 Notas para Integradores Frontend

- Usa siempre decimales correctos (USDC = 6).  
- Calcula `minUSDCout` con tu propio estimador o usando `estimateAmountsOut`.  
- Muestra siempre los límites diarios y globales al usuario.  
- Siempre pide `approve` **antes** del depósito ERC20.  
- Identifica si el protocolo está pausado (deshabilita botones del UI).  

---


