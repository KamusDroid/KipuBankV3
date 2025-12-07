// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/**
 * @title KipuBankV3
 * @notice Sistema bancario DeFi que acepta múltiples tokens y los convierte a USDC usando Uniswap V2
 * @dev Integración con Uniswap V2 Router y Chainlink Price Feeds para valoración de activos
 */

// ============ INTERFACES EXTERNAS ============

/// @notice Interface de Chainlink Price Feed para obtener precios de activos
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

/// @notice Interface del Router V2 de Uniswap para realizar swaps
interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);

    function getAmountsOut(
        uint amountIn,
        address[] calldata path
    ) external view returns (uint[] memory amounts);

    function WETH() external pure returns (address);
}

// ============ CONTRATO PRINCIPAL ============

contract KipuBankV3 is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using Address for address payable;

    // ============ CONSTANTES ============
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant RISK_MANAGER_ROLE = keccak256("RISK_MANAGER_ROLE");

    uint256 public constant PRICE_STALE_THRESHOLD = 12 hours;
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_SLIPPAGE_BPS = 300; // 3% máximo slippage permitido
    uint256 public constant SWAP_DEADLINE_SECONDS = 300; // 5 minutos para ejecutar swap

    // ============ VARIABLES INMUTABLES ============
    address public immutable USDC;
    IUniswapV2Router02 public immutable uniswapRouter;
    AggregatorV3Interface public immutable ethUsdPriceFeed;
    address public immutable WETH;

    // ============ VARIABLES DE ESTADO ============
    uint256 public globalBankCap;
    uint256 public totalUSDCBalance;

    mapping(address => uint256) public usdcBalances;

    struct TokenConfig {
        bool supported;
        uint256 withdrawalLimit;
        uint256 depositLimit;
        address priceFeed;
        uint8 decimals;
        uint256 lastPrice;
        uint256 priceUpdatedAt;
    }

    mapping(address => TokenConfig) public tokenConfigs;
    address[] public supportedTokens;

    struct UserDailyLimits {
        uint256 depositsUSD;
        uint256 withdrawalsUSD;
        uint256 lastActivityDate;
    }
    mapping(address => UserDailyLimits) public userDailyLimits;

    // ============ EVENTOS ============
    event Deposited(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 usdcReceived,
        uint256 timestamp
    );

    event Withdrawn(
        address indexed user,
        uint256 usdcAmount,
        uint256 timestamp
    );

    event TokenSwapped(
        address indexed token,
        uint256 amountIn,
        uint256 usdcOut,
        address[] path
    );

    event TokenSupported(address indexed token, address priceFeed);
    event BankCapUpdated(uint256 newCap);
    event EmergencyPaused(address indexed by, uint256 timestamp);

    // ============ ERRORES PERSONALIZADOS ============
    error ExceedsBankCap();
    error ExceedsWithdrawalThreshold();
    error ExceedsDepositThreshold();
    error InsufficientBalance();
    error Unauthorized();
    error ZeroAmount();
    error TokenNotSupported();
    error InvalidToken();
    error SlippageTooHigh();
    error PriceManipulationDetected();
    error SwapFailed();
    error StalePrice();

    // ============ MODIFICADORES ============
    modifier nonZeroAmount(uint256 amount) {
        if (amount == 0) revert ZeroAmount();
        _;
    }

    modifier onlySupportedToken(address token) {
        if (!tokenConfigs[token].supported && token != address(0))
            revert TokenNotSupported();
        _;
    }

    // ============ CONSTRUCTOR ============
    /**
     * @notice Inicializa el contrato KipuBankV3
     * @param _admin Dirección del administrador principal
     * @param _usdc Dirección del token USDC
     * @param _uniswapRouter Dirección del Uniswap V2 Router
     * @param _ethUsdPriceFeed Dirección del Chainlink ETH/USD Price Feed
     * @param _globalBankCap Límite máximo total de USDC que puede almacenar el banco
     */
    constructor(
        address _admin,
        address _usdc,
        address _uniswapRouter,
        address _ethUsdPriceFeed,
        uint256 _globalBankCap
    ) {
        require(_admin != address(0), "Invalid admin");
        require(_usdc != address(0), "Invalid USDC");
        require(_uniswapRouter != address(0), "Invalid router");
        require(_ethUsdPriceFeed != address(0), "Invalid price feed");

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);
        _grantRole(RISK_MANAGER_ROLE, _admin);

        _setRoleAdmin(OPERATOR_ROLE, ADMIN_ROLE);
        _setRoleAdmin(RISK_MANAGER_ROLE, ADMIN_ROLE);

        USDC = _usdc;
        uniswapRouter = IUniswapV2Router02(_uniswapRouter);
        ethUsdPriceFeed = AggregatorV3Interface(_ethUsdPriceFeed);
        WETH = uniswapRouter.WETH();
        globalBankCap = _globalBankCap;

        // Configurar ETH nativo (address(0) representa ETH)
        _setupToken(address(0), 10 ether, 50 ether, _ethUsdPriceFeed, 18);

        // Configurar USDC (no necesita swap)
        _setupToken(_usdc, 100_000e6, 500_000e6, address(0), 6);
    }

    // ============ GESTIÓN DE TOKENS ============

    /**
     * @notice Permite al operador agregar soporte para un nuevo token ERC20
     * @param token Dirección del token a soportar
     * @param withdrawalLimit Límite máximo por retiro
     * @param depositLimit Límite máximo por depósito
     * @param priceFeed Dirección del Chainlink Price Feed (opcional)
     */
    function supportToken(
        address token,
        uint256 withdrawalLimit,
        uint256 depositLimit,
        address priceFeed
    ) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        require(token != address(0) && token != USDC, "Invalid token");
        require(!tokenConfigs[token].supported, "Token already supported");

        try IERC20Metadata(token).decimals() returns (uint8 decimals) {
            _setupToken(token, withdrawalLimit, depositLimit, priceFeed, decimals);
            supportedTokens.push(token);
            emit TokenSupported(token, priceFeed);
        } catch {
            revert InvalidToken();
        }
    }

    /**
     * @dev Configura internamente un token con sus parámetros
     */
    function _setupToken(
        address token,
        uint256 withdrawalLimit,
        uint256 depositLimit,
        address priceFeed,
        uint8 decimals
    ) internal {
        tokenConfigs[token] = TokenConfig({
            supported: true,
            withdrawalLimit: withdrawalLimit,
            depositLimit: depositLimit,
            priceFeed: priceFeed,
            decimals: decimals,
            lastPrice: 0,
            priceUpdatedAt: 0
        });

        if (priceFeed != address(0)) {
            _updateTokenPrice(token);
        }
    }

    // ============ GESTIÓN DE PRECIOS (CHAINLINK) ============

    /**
     * @dev Actualiza el precio de un token desde su Chainlink Price Feed
     */
    function _updateTokenPrice(address token) internal {
        TokenConfig storage config = tokenConfigs[token];

        if (config.priceFeed == address(0)) return;

        try AggregatorV3Interface(config.priceFeed).latestRoundData() returns (
            uint80,
            int256 price,
            uint256,
            uint256 updatedAt,
            uint80
        ) {
            if (block.timestamp - updatedAt > PRICE_STALE_THRESHOLD) {
                revert StalePrice();
            }

            require(price > 0, "Invalid price");

            config.lastPrice = uint256(price);
            config.priceUpdatedAt = updatedAt;
        } catch {
            // Si falla, continuar sin actualizar precio
            return;
        }
    }

    /**
     * @dev Calcula el valor en USD de una cantidad de tokens
     * @param token Dirección del token
     * @param amount Cantidad de tokens
     * @return Valor en USD (18 decimales)
     */
    function _getUSDValue(address token, uint256 amount) internal view returns (uint256) {
        TokenConfig memory config = tokenConfigs[token];

        if (config.priceFeed == address(0) || config.lastPrice == 0) {
            return 0;
        }

        require(
            block.timestamp - config.priceUpdatedAt <= PRICE_STALE_THRESHOLD,
            "Stale price"
        );

        uint8 priceFeedDecimals = AggregatorV3Interface(config.priceFeed).decimals();
        uint256 normalizedAmount = (amount * 1e18) / (10 ** config.decimals);
        uint256 usdValue = (normalizedAmount * config.lastPrice) / (10 ** priceFeedDecimals);

        return usdValue;
    }

    // ============ LÓGICA DE SWAP (UNISWAP V2) ============

    /**
     * @dev Ejecuta el swap de un token a USDC usando Uniswap V2
     * @param token Dirección del token a intercambiar
     * @param amount Cantidad de tokens a intercambiar
     * @param minUSDCout Cantidad mínima de USDC esperada (protección slippage)
     * @return usdcReceived Cantidad real de USDC recibida
     */
    function _swapToUSDC(
        address token,
        uint256 amount,
        uint256 minUSDCout
    ) internal returns (uint256 usdcReceived) {
        // Si ya es USDC, no hacer swap
        if (token == USDC) {
            return amount;
        }

        // Para ETH nativo
        if (token == address(0)) {
            return _swapETHToUSDC(amount, minUSDCout);
        }

        // Para tokens ERC20
        return _swapTokenToUSDC(token, amount, minUSDCout);
    }

    /**
     * @dev Swap de ETH a USDC
     */
    function _swapETHToUSDC(uint256 amount, uint256 minUSDCout)
        internal
        returns (uint256)
    {
        // Construir path: ETH (WETH) -> USDC
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;

        // Verificar cantidad esperada vs slippage
        uint256[] memory expectedAmounts = uniswapRouter.getAmountsOut(amount, path);
        uint256 expectedUSDC = expectedAmounts[1];

        _validateSlippage(expectedUSDC, minUSDCout);

        // Ejecutar swap
        uint256 balanceBefore = IERC20(USDC).balanceOf(address(this));

        try uniswapRouter.swapExactETHForTokens{value: amount}(
            minUSDCout,
            path,
            address(this),
            block.timestamp + SWAP_DEADLINE_SECONDS
        ) returns (uint256[] memory amounts) {
            uint256 balanceAfter = IERC20(USDC).balanceOf(address(this));
            uint256 usdcReceived = balanceAfter - balanceBefore;

            emit TokenSwapped(address(0), amount, usdcReceived, path);
            return usdcReceived;
        } catch {
            revert SwapFailed();
        }
    }

    /**
     * @dev Swap de token ERC20 a USDC
     */
    function _swapTokenToUSDC(
        address token,
        uint256 amount,
        uint256 minUSDCout
    ) internal returns (uint256) {
        // Aprobar al router para gastar tokens
        IERC20(token).forceApprove(address(uniswapRouter), amount);

        // Construir path: Token -> WETH -> USDC (path más común)
        address[] memory path = new address[](3);
        path[0] = token;
        path[1] = WETH;
        path[2] = USDC;

        // Intentar path directo Token -> USDC si falla el path con WETH
        uint256 usdcReceived;
        bool swapSuccess = false;

        // Intentar path con WETH primero
        try uniswapRouter.getAmountsOut(amount, path) returns (uint256[] memory expectedAmounts) {
            uint256 expectedUSDC = expectedAmounts[2];
            _validateSlippage(expectedUSDC, minUSDCout);

            uint256 balanceBefore = IERC20(USDC).balanceOf(address(this));

            try uniswapRouter.swapExactTokensForTokens(
                amount,
                minUSDCout,
                path,
                address(this),
                block.timestamp + SWAP_DEADLINE_SECONDS
            ) returns (uint256[] memory) {
                uint256 balanceAfter = IERC20(USDC).balanceOf(address(this));
                usdcReceived = balanceAfter - balanceBefore;
                swapSuccess = true;

                emit TokenSwapped(token, amount, usdcReceived, path);
            } catch {
                // Falló, intentar path directo
            }
        } catch {
            // No existe path con WETH, intentar directo
        }

        // Si el primer path falló, intentar path directo Token -> USDC
        if (!swapSuccess) {
            address[] memory directPath = new address[](2);
            directPath[0] = token;
            directPath[1] = USDC;

            try uniswapRouter.getAmountsOut(amount, directPath) returns (
                uint256[] memory expectedAmounts
            ) {
                uint256 expectedUSDC = expectedAmounts[1];
                _validateSlippage(expectedUSDC, minUSDCout);

                uint256 balanceBefore = IERC20(USDC).balanceOf(address(this));

                uniswapRouter.swapExactTokensForTokens(
                    amount,
                    minUSDCout,
                    directPath,
                    address(this),
                    block.timestamp + SWAP_DEADLINE_SECONDS
                );

                uint256 balanceAfter = IERC20(USDC).balanceOf(address(this));
                usdcReceived = balanceAfter - balanceBefore;

                emit TokenSwapped(token, amount, usdcReceived, directPath);
            } catch {
                revert SwapFailed();
            }
        }

        return usdcReceived;
    }

    /**
     * @dev Valida que el slippage esté dentro del límite permitido
     */
    function _validateSlippage(uint256 expectedAmount, uint256 minAmount) internal pure {
        if (minAmount > expectedAmount) {
            revert SlippageTooHigh();
        }

        uint256 slippage = ((expectedAmount - minAmount) * BASIS_POINTS) / expectedAmount;

        if (slippage > MAX_SLIPPAGE_BPS) {
            revert SlippageTooHigh();
        }
    }

    // ============ FUNCIONES DE DEPÓSITO ============

    /**
     * @notice Permite depositar ETH que será convertido a USDC
     * @param minUSDCout Cantidad mínima de USDC esperada
     */
    function depositETH(uint256 minUSDCout)
        external
        payable
        nonZeroAmount(msg.value)
        whenNotPaused
        nonReentrant
    {
        TokenConfig memory config = tokenConfigs[address(0)];
        require(msg.value <= config.depositLimit, "Exceeds deposit limit");

        _updateTokenPrice(address(0));
        uint256 usdcReceived = _swapToUSDC(address(0), msg.value, minUSDCout);

        _processDeposit(usdcReceived);
        emit Deposited(msg.sender, address(0), msg.value, usdcReceived, block.timestamp);
    }

    /**
     * @notice Permite depositar cualquier token ERC20 soportado que será convertido a USDC
     * @param token Dirección del token a depositar
     * @param amount Cantidad de tokens a depositar
     * @param minUSDCout Cantidad mínima de USDC esperada
     */
    function depositToken(
        address token,
        uint256 amount,
        uint256 minUSDCout
    ) external nonZeroAmount(amount) onlySupportedToken(token) whenNotPaused nonReentrant {
        TokenConfig memory config = tokenConfigs[token];
        require(amount <= config.depositLimit, "Exceeds deposit limit");

        // Transferir tokens del usuario al contrato
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Si es USDC, depositar directamente sin swap
        if (token == USDC) {
            _processDeposit(amount);
            emit Deposited(msg.sender, token, amount, amount, block.timestamp);
            return;
        }

        // Para otros tokens, hacer swap a USDC
        _updateTokenPrice(token);
        uint256 usdcReceived = _swapToUSDC(token, amount, minUSDCout);

        _processDeposit(usdcReceived);
        emit Deposited(msg.sender, token, amount, usdcReceived, block.timestamp);
    }

    /**
     * @dev Procesa el depósito verificando límites y actualizando balances
     */
    function _processDeposit(uint256 usdcReceived) internal {
        require(totalUSDCBalance + usdcReceived <= globalBankCap, "Exceeds bank cap");

        _resetDailyLimitsIfNeeded(msg.sender);
        UserDailyLimits storage limits = userDailyLimits[msg.sender];

        require(
            limits.depositsUSD + usdcReceived <= _getUserDailyDepositLimit(),
            "Exceeds daily deposit limit"
        );

        usdcBalances[msg.sender] += usdcReceived;
        totalUSDCBalance += usdcReceived;
        limits.depositsUSD += usdcReceived;
    }

    // ============ FUNCIONES DE RETIRO ============

    /**
     * @notice Permite retirar USDC del balance del usuario
     * @param amount Cantidad de USDC a retirar
     */
    function withdrawUSDC(uint256 amount)
        external
        nonZeroAmount(amount)
        whenNotPaused
        nonReentrant
    {
        require(usdcBalances[msg.sender] >= amount, "Insufficient balance");

        TokenConfig memory config = tokenConfigs[USDC];
        require(amount <= config.withdrawalLimit, "Exceeds withdrawal limit");

        _resetDailyLimitsIfNeeded(msg.sender);
        UserDailyLimits storage limits = userDailyLimits[msg.sender];

        require(
            limits.withdrawalsUSD + amount <= _getUserDailyWithdrawalLimit(),
            "Exceeds daily withdrawal limit"
        );

        usdcBalances[msg.sender] -= amount;
        totalUSDCBalance -= amount;
        limits.withdrawalsUSD += amount;

        IERC20(USDC).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, block.timestamp);
    }

    // ============ GESTIÓN DE LÍMITES DIARIOS ============

    /**
     * @dev Resetea los límites diarios si es un nuevo día
     */
    function _resetDailyLimitsIfNeeded(address user) internal {
        UserDailyLimits storage limits = userDailyLimits[user];
        uint256 today = block.timestamp / 1 days;

        if (limits.lastActivityDate < today) {
            limits.depositsUSD = 0;
            limits.withdrawalsUSD = 0;
            limits.lastActivityDate = today;
        }
    }

    /**
     * @dev Retorna el límite diario de depósitos por usuario
     */
    function _getUserDailyDepositLimit() internal pure returns (uint256) {
        return 10_000 * 1e6; // $10,000 en USDC (6 decimales)
    }

    /**
     * @dev Retorna el límite diario de retiros por usuario
     */
    function _getUserDailyWithdrawalLimit() internal pure returns (uint256) {
        return 5_000 * 1e6; // $5,000 en USDC (6 decimales)
    }

    // ============ FUNCIONES ADMINISTRATIVAS ============

    /**
     * @notice Actualiza el límite global del banco (Bank Cap)
     * @param newCap Nuevo límite en USDC
     */
    function setGlobalBankCap(uint256 newCap) external onlyRole(ADMIN_ROLE) {
        require(newCap >= totalUSDCBalance, "New cap below current balance");
        globalBankCap = newCap;
        emit BankCapUpdated(newCap);
    }

    /**
     * @notice Pausa todas las operaciones del contrato en caso de emergencia
     */
    function emergencyPause() external onlyRole(ADMIN_ROLE) {
        _pause();
        emit EmergencyPaused(msg.sender, block.timestamp);
    }

    /**
     * @notice Reanuda las operaciones del contrato
     */
    function emergencyUnpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Permite retirar fondos en caso de emergencia
     * @param token Dirección del token a retirar (address(0) para ETH)
     * @param to Dirección destino
     */
    function emergencyWithdraw(address token, address to)
        external
        onlyRole(ADMIN_ROLE)
    {
        require(to != address(0), "Invalid recipient");

        if (token == address(0)) {
            uint256 balance = address(this).balance;
            payable(to).sendValue(balance);
        } else {
            uint256 balance = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransfer(to, balance);
        }
    }

    /**
     * @notice Actualiza los límites de un token específico
     */
    function updateTokenLimits(
        address token,
        uint256 newWithdrawalLimit,
        uint256 newDepositLimit
    ) external onlyRole(RISK_MANAGER_ROLE) {
        require(tokenConfigs[token].supported, "Token not supported");
        tokenConfigs[token].withdrawalLimit = newWithdrawalLimit;
        tokenConfigs[token].depositLimit = newDepositLimit;
    }

    // ============ FUNCIONES DE CONSULTA (VIEW) ============

    /**
     * @notice Obtiene el balance en USDC de un usuario
     * @param user Dirección del usuario
     * @return Balance en USDC
     */
    function getUSDCBalance(address user) external view returns (uint256) {
        return usdcBalances[user];
    }

    /**
     * @notice Obtiene las estadísticas generales del banco
     * @return totalBalance Balance total en USDC
     * @return bankCap Límite máximo del banco
     * @return tokensCount Cantidad de tokens soportados
     */
    function getBankStats()
        external
        view
        returns (
            uint256 totalBalance,
            uint256 bankCap,
            uint256 tokensCount
        )
    {
        return (totalUSDCBalance, globalBankCap, supportedTokens.length);
    }

    /**
     * @notice Obtiene la lista completa de tokens soportados
     * @return Array de direcciones de tokens
     */
    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokens;
    }

    /**
     * @notice Obtiene los límites diarios actuales de un usuario
     * @param user Dirección del usuario
     * @return depositsUsed Cantidad de depósitos usados hoy
     * @return withdrawalsUsed Cantidad de retiros usados hoy
     * @return depositLimit Límite diario de depósitos
     * @return withdrawalLimit Límite diario de retiros
     */
    function getUserDailyLimits(address user)
        external
        view
        returns (
            uint256 depositsUsed,
            uint256 withdrawalsUsed,
            uint256 depositLimit,
            uint256 withdrawalLimit
        )
    {
        UserDailyLimits memory limits = userDailyLimits[user];
        uint256 today = block.timestamp / 1 days;

        // Si es un día diferente, los límites usados son 0
        if (limits.lastActivityDate < today) {
            depositsUsed = 0;
            withdrawalsUsed = 0;
        } else {
            depositsUsed = limits.depositsUSD;
            withdrawalsUsed = limits.withdrawalsUSD;
        }

        depositLimit = _getUserDailyDepositLimit();
        withdrawalLimit = _getUserDailyWithdrawalLimit();
    }

    /**
     * @notice Estima cuánto USDC se recibiría al depositar un token
     * @param token Dirección del token
     * @param amount Cantidad de tokens
     * @return Cantidad estimada de USDC
     */
    function estimateUSDCOutput(address token, uint256 amount)
        external
        view
        returns (uint256)
    {
        if (token == USDC) {
            return amount;
        }

        if (token == address(0)) {
            // ETH
            address[] memory directPath = new address[](2);
            directPath[0] = token;
            directPath[1] = USDC;

            try uniswapRouter.getAmountsOut(amount, directPath) returns (uint256[] memory amounts) {
                return amounts[1];
            } catch {
                return 0;
            }
        }

        // Token ERC20 - intentar path con WETH
        address[] memory path = new address[](3);
        path[0] = token;
        path[1] = WETH;
        path[2] = USDC;

        try uniswapRouter.getAmountsOut(amount, path) returns (uint256[] memory amounts) {
            return amounts[2];
        } catch {
            // Intentar path directo
            address[] memory directPath = new address[](2);
            directPath[0] = token;
            directPath[1] = USDC;

            try uniswapRouter.getAmountsOut(amount, directPath) returns (
                uint256[] memory amounts
            ) {
                return amounts[1];
            } catch {
                return 0;
            }
        }
    }

    // ============ FALLBACK Y RECEIVE ============

    /**
     * @notice Rechaza ETH enviado directamente sin usar depositETH()
     */
    receive() external payable {
        revert("Use depositETH function");
    }

    fallback() external payable {
        revert("Use depositETH function");
    }
}