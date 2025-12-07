# Informe de Cambios entre KipuBankV2 y la Versión Actual (KipuBankV3)

Este documento describe de forma clara, técnica y estructurada las diferencias entre **KipuBankV2** y la versión actual **KipuBankV3**, desarrollada para cumplir los requisitos del examen final del módulo DeFi.  
La comparación cubre arquitectura, funcionalidad, seguridad, integración con protocolos, testing y documentación.

---

# ⭐ 1. Arquitectura General

| Área | KipuBankV2 | KipuBankV3 (actual) |
|------|------------|----------------------|
| Filosofía | Vault multi-token | Banco centrado en USDC |
| Tipo de balances | Cada token se almacena directamente | Todo se convierte a USDC |
| Integraciones | Solo Chainlink | Uniswap V2 + Chainlink |
| Gestión de riesgo | Básica | Avanzada, con límites diarios y por token |
| Seguridad | Pausable + ReentrancyGuard | Igual + Slippage + Deadlines |

### Resumen
**KipuBankV3 transforma el vault de V2 en un protocolo DeFi real**, donde cualquier token depositado se convierte automáticamente a USDC mediante Uniswap V2.

---

# ⭐ 2. Gestión de Tokens

## KipuBankV2
- El usuario deposita **ETH o ERC20**.
- El contrato almacena balances en el token original:
  ```
  s_balances[token][user]
  ```
- No existen swaps ni integración con AMMs.
- Caps y límites se calculan en USD6 vía Chainlink pero *por token individual*.

## KipuBankV3
- Todo se convierte a **USDC**, que se convierte en la única unidad interna:
  ```
  usdcBalances[user]
  totalUSDCBalance
  ```
- Permite depósitos de:
  - ETH → swappeado a USDC
  - USDC → acreditado directo
  - Cualquier token soportado por Uniswap V2

### TokenConfig (nuevo)
Incluye:
- supported
- withdrawalLimit
- depositLimit
- priceFeed
- decimals
- lastPrice
- priceUpdatedAt

> **La contabilidad unificada en USDC simplifica auditoría, riesgo y experiencia de usuario.**

---

# ⭐ 3. Integración con Uniswap V2 (Nuevo en V3)

| Función | V2 | V3 |
|--------|----|----|
| Router de Uniswap | ❌ | ✔️ `IUniswapV2Router02` |
| Swaps automáticos | ❌ | ✔️ ETH/ERC20 → USDC |
| Slippage protection | ❌ | ✔️ `MAX_SLIPPAGE_BPS` |
| Deadlines de swaps | ❌ | ✔️ `SWAP_DEADLINE_SECONDS` |
| Paths dinámicos | ❌ | ✔️ `token→WETH→USDC` o `token→USDC` |

El V3 utiliza primero un **path de 3 hops**; si falla, intenta un **path directo**:

```
[token, WETH, USDC]
[token, USDC]
```

---

# ⭐ 4. Depósitos y Retiros

## Depósitos

### V2
- depositETH()
- depositERC20()
- Guarda el token directamente.

### V3
- depositETH(minUSDCout)
- depositToken(token, amount, minUSDCout)
- El depósito siempre termina en USDC gracias a Uniswap.
- Se protege al usuario con minUSDCout.

## Retiros

### V2
- Retira el token original:
  - ETH → ETH
  - ERC20 → ERC20

### V3
- Todos los retiros se hacen en **USDC**:
  ```
  withdrawUSDC(amount)
  ```

---

# ⭐ 5. Gestión de Riesgo

| Característica | V2 | V3 |
|----------------|----|----|
| BankCap | ✔️ | ✔️ (más preciso) |
| Límite por retiro | ✔️ | ✔️ En USDC |
| Límites diarios | ✔️ USD6 | ✔️ En USDC |
| Límites por token | ❌ | ✔️ |
| Verificación de slippage | ❌ | ✔️ |
| Chequeo de precios stale | ❌ | ✔️ |
| PriceFeed por token | ✔️ | ✔️ mejora en robustez |

### Conclusión
El modelo de riesgo de V3 se acerca al de protocolos DeFi reales.

---

# ⭐ 6. Roles y Seguridad

| Función | V2 | V3 |
|--------|----|----|
| Roles avanzados | ✔️ ADMIN/OPERATOR/RISK | ✔️ Igual pero mejor utilizados |
| Pausable | ✔️ | ✔️ + withdraw de emergencia |
| ReentrancyGuard | ✔️ | ✔️ |
| Validación de tokens | ❌ | ✔️ supportToken() |
| Slippage y deadlines | ❌ | ✔️ |

El sistema de roles en V3 separa claramente responsabilidades operativas y de riesgo.

---

# ⭐ 7. Pruebas y Calidad del Código

## V2
- Tests mínimos.
- Solo prueba depósito de ETH.
- No cumple cobertura >50%.

## V3
- Tests completos:
  - Depositar ETH
  - Depositar tokens
  - Swaps
  - Roles
  - Límites diarios
  - Límites por token
  - Pausas
  - BankCap
  - Fuzz testing
- Diseñado para lograr **+50% coverage**.

---

# ⭐ 8. Documentación y Entregables

| Elemento | V2 | V3 |
|----------|----|----|
| Comentarios Natspec | Parcial | Completo |
| README técnico | Básico | Completo, con instrucciones |
| Diagramas y flujo | ❌ | ✔️ Explicación detallada |
| Deploy scripts | Hardhat/TS | Forge Scripts (`DeployKipuBankV3.s.sol`) |

---

# 🧩 Resumen Ejecutivo

| Área | V2 | V3 |
|------|-----|-----|
| Tecnología | Vault multi-token | Banco USDC con Uniswap |
| Integración DeFi | ❌ | ✔️ |
| Seguridad | Media | Alta |
| Testing | Bajo | Alto |
| Usabilidad | Flexible | Estándar y estable |
| Contabilidad | Multi-asset | USDC unificado |

---

# 🏆 Conclusión General

La versión **KipuBankV3** es una evolución significativa frente a V2:

- Introduce composabilidad real con Uniswap.  
- Simplifica contabilidad y auditoría al usar solo USDC.  
- Aumenta la seguridad con slippage, límites por token y validación de precios stale.  
- Implementa una arquitectura digna de producción.  
- Satisface todos los requisitos del examen.

KipuBankV3 representa un sistema DeFi más robusto, modular, seguro y alineado con las prácticas reales del ecosistema Ethereum.
