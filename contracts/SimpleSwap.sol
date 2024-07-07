// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ISimpleSwap } from "./interface/ISimpleSwap.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title SimpleSwap
 * @dev A decentralized token swap contract that allows users to swap tokens and provide/remove liquidity.
 */
contract SimpleSwap is ISimpleSwap, ERC20("SimpleSwap", "SSwap") {
    address private _tokenA;
    address private _tokenB;

    // The reserves must be manually calculated and not directly obtained using balanceOf(address(this))
    // to avoid manipulation by transferring tokens into the contract, which could affect the LP token calculation.
    uint256 private _reserveA;
    uint256 private _reserveB;

    /**
     * @dev Sets the values for {_tokenA} and {_tokenB}.
     * Both of these values are immutable: they can only be set once during
     * construction.
     */
    constructor(address token0, address token1) {
        require(token0 != address(0), "SimpleSwap: TOKENA_IS_NOT_CONTRACT");
        require(token1 != address(0), "SimpleSwap: TOKENB_IS_NOT_CONTRACT");
        require(token0 != token1, "SimpleSwap: TOKENA_TOKENB_IDENTICAL_ADDRESS");

        _tokenA = uint160(token0) < uint160(token1) ? token0 : token1;
        _tokenB = uint160(token0) < uint160(token1) ? token1 : token0;
    }

    /**
     * @dev Swaps `amountIn` of `tokenIn` for `tokenOut`.
     * @param tokenIn Address of the input token.
     * @param tokenOut Address of the output token.
     * @param amountIn Amount of the input token.
     * @return amountOut Amount of the output token.
     */
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external override returns (uint256) {
        require(tokenIn == address(_tokenA) || tokenIn == address(_tokenB), "SimpleSwap: INVALID_TOKEN_IN");
        require(tokenOut == address(_tokenA) || tokenOut == address(_tokenB), "SimpleSwap: INVALID_TOKEN_OUT");
        require(amountIn != 0, "SimpleSwap: INSUFFICIENT_INPUT_AMOUNT");
        require(tokenIn != tokenOut, "SimpleSwap: IDENTICAL_ADDRESS");

        uint256 actualAmountIn = doTransferIn(tokenIn, amountIn);

        // Always multiply before dividing to maintain precision.
        // This calculation is based on the constant product formula xy = k,
        // which ensures that the product of the reserves remains constant after the swap.
        // The formula used here calculates the amount of output tokens (amountOut)
        // based on the input tokens (actualAmountIn) and the current reserves (_reserveA and _reserveB).
        // If the input token is _tokenA, the formula is: amountOut = (_reserveB * actualAmountIn) / (_reserveA + actualAmountIn).
        // If the input token is _tokenB, the formula is: amountOut = (_reserveA * actualAmountIn) / (_reserveB + actualAmountIn).
        uint256 amountOut = tokenIn == _tokenA
            ? _reserveB * actualAmountIn / (_reserveA + actualAmountIn)
            : _reserveA * actualAmountIn / (_reserveB + actualAmountIn);

        // Ensure the calculated output amount is not zero to prevent invalid swaps.
        require(amountOut != 0, "SimpleSwap: INSUFFICIENT_OUTPUT_AMOUNT");

        // Update state before transferring tokens to prevent reentrancy attacks
        if (tokenIn == address(_tokenA)) {
            _reserveA += actualAmountIn;
            _reserveB -= amountOut;
        } else {
            _reserveB += actualAmountIn;
            _reserveA -= amountOut;
        }

        require(ERC20(tokenOut).transfer(msg.sender, amountOut), "Transfer failed");

        emit Swap(msg.sender, tokenIn, tokenOut, actualAmountIn, amountOut);

        return amountOut;
    }

    /**
     * @dev Adds liquidity to the pool.
     * @param amountAIn Amount of token A to add.
     * @param amountBIn Amount of token B to add.
     * @return actualAmountAIn Actual amount of token A added.
     * @return actualAmountBIn Actual amount of token B added.
     * @return liquidity Amount of liquidity tokens minted.
     */
    function addLiquidity(uint256 amountAIn, uint256 amountBIn)
        external
        override
        returns (
            uint256 actualAmountAIn,
            uint256 actualAmountBIn,
            uint256 liquidity
        )
    {
        require(amountAIn != 0 && amountBIn != 0, "SimpleSwap: INSUFFICIENT_INPUT_AMOUNT");
        uint256 totalSupply = totalSupply();

        if (totalSupply == 0) {
            actualAmountAIn = doTransferIn(_tokenA, amountAIn);
            actualAmountBIn = doTransferIn(_tokenB, amountBIn);
            liquidity = Math.sqrt(actualAmountAIn * actualAmountBIn);
        } else {
            uint256 _actualAmountAIn = Math.min(amountAIn, amountBIn * _reserveA / _reserveB);
            uint256 _actualAmountBIn = Math.min(amountBIn, amountAIn * _reserveB / _reserveA);
            
            actualAmountAIn = doTransferIn(_tokenA, _actualAmountAIn);
            actualAmountBIn = doTransferIn(_tokenB, _actualAmountBIn);

            liquidity = Math.min(
                (actualAmountAIn * totalSupply) / _reserveA,
                (actualAmountBIn * totalSupply) / _reserveB
            );
            // Or this way:
            // liquidity = Math.sqrt(actualAmountAIn * actualAmountBIn);
        }

        _reserveA += actualAmountAIn;
        _reserveB += actualAmountBIn;
        _mint(msg.sender, liquidity);
        emit AddLiquidity(msg.sender, actualAmountAIn, actualAmountBIn, liquidity);
        return (actualAmountAIn, actualAmountBIn, liquidity);
    }

    /**
     * @dev Removes liquidity from the pool.
     * @param liquidity Amount of liquidity tokens to burn.
     * @return amountA Amount of token A withdrawn.
     * @return amountB Amount of token B withdrawn.
     */
    function removeLiquidity(uint256 liquidity) external override returns (uint256 amountA, uint256 amountB) {
        require(liquidity != 0, "SimpleSwap: INSUFFICIENT_LIQUIDITY_BURNED");

        amountA = liquidity * _reserveA / totalSupply();
        amountB = liquidity * _reserveB / totalSupply();

        _reserveA -= amountA;
        _reserveB -= amountB;
        
        _transfer(msg.sender, address(this), liquidity);
        _burn(address(this), liquidity);
        ERC20(_tokenA).transfer(msg.sender, amountA);
        ERC20(_tokenB).transfer(msg.sender, amountB);

        emit RemoveLiquidity(msg.sender, amountA, amountB, liquidity);

        return (amountA, amountB);
    }

    /**
     * @dev Returns the reserves of token A and token B.
     * @return reserveA The reserve of token A.
     * @return reserveB The reserve of token B.
     */
    function getReserves() external view override returns (uint256 reserveA, uint256 reserveB) {
        return (_reserveA, _reserveB);
    }

    /**
     * @dev Returns the address of token A.
     * @return tokenA The address of token A.
     */
    function getTokenA() external view override returns (address tokenA) {
        return _tokenA;
    }

    /**
     * @dev Returns the address of token B.
     * @return tokenB The address of token B.
     */
    function getTokenB() external view override returns (address tokenB) {
        return _tokenB;
    }

    /**
     * @dev Transfers tokens into the contract and returns the actual amount transferred.
     * @param tokenIn The address of the token being transferred.
     * @param amountIn The amount of tokens being transferred.
     * @return The actual amount of tokens transferred.
     */
    function doTransferIn(address tokenIn, uint256 amountIn) public returns (uint256) {
        uint256 balance = ERC20(tokenIn).balanceOf(address(this));
        require(ERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn), "Transfer failed");
        return ERC20(tokenIn).balanceOf(address(this)) - balance;
    }
}
