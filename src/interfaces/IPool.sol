// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPool {
    /**
     * @notice Вносит `amount` базового актива в пул Aave, получая взамен aTokens.
     * @param asset Адрес базового актива (например, USDC)
     * @param amount Сумма для депозита
     * @param onBehalfOf Адрес, который получит aTokens (в нашем случае address(this))
     * @param referralCode Код реферала (передаем 0)
     */
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;

    /**
     * @notice Выводит `amount` базового актива из резерва, сжигая эквивалентные aTokens.
     * @param asset Адрес базового актива для вывода
     * @param amount Сумма для вывода (используй type(uint256).max для вывода всего баланса)
     * @param to Адрес, который получит базовый актив
     * @return Финальная выведенная сумма
     */
    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256);
}