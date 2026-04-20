// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockAavePool {
    // DungeonCore вызывает supply и withdraw. Реализуем их минимально.

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        // Просто забираем токены у DungeonCore, имитируя депозит
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        uint256 amountToWithdraw = amount;

        if (amount == type(uint256).max) {
            // В реальном Aave это был бы баланс конкретного пользователя (aToken),
            // но так как мок изолирован под наш тест, мы просто отдаем все, что есть на контракте
            amountToWithdraw = IERC20(asset).balanceOf(address(this));
        }

        console.log("MockAavePool: Withdrawing amount:", amountToWithdraw); // Логируем для проверки

        IERC20(asset).transfer(to, amountToWithdraw);
        return amountToWithdraw;
    }

    // Хелпер для тестов: закинуть "процент" (yield) в пул
    // Чтобы когда DungeonCore сделает withdraw, там было больше денег, чем положили
    function addYield(address asset, uint256 amount) external {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
    }
}
