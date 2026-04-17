// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/DungeonCore.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DungeonCoreTest is Test {
    DungeonCore public dungeon;
    ERC1967Proxy public proxy;
    
    // Адреса из скрипта деплоя (Sepolia)
    address constant ASSET = 0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8; // USDC
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant VRF_COORDINATOR = 0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B;

    address owner = address(1);
    address alice = address(2);
    address bob = address(3);

    uint256 sepoliaFork;

    function setUp() public {
        // Создаем форк Sepolia (нужен RPC_URL в env или просто строкой)
        sepoliaFork = vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));

        vm.startPrank(owner);
        
        // 1. Деплой логики и прокси
        DungeonCore implementation = new DungeonCore();
        bytes memory initData = abi.encodeWithSelector(
            DungeonCore.initialize.selector,
            ASSET,
            AAVE_POOL,
            owner,
            123, // subId
            bytes32(0), // keyHash
            VRF_COORDINATOR,
            5000 // 50% maxBoost
        );
        proxy = new ERC1967Proxy(address(implementation), initData);
        dungeon = DungeonCore(address(proxy));

        vm.stopPrank();

        // Даем Алисе и Бобу немного USDC (делаем deal или берем у кита)
        // На форке проще всего использовать deal для ERC20
        deal(ASSET, alice, 1000 * 1e6); // 1000 USDC
        deal(ASSET, bob, 1000 * 1e6);
    }

    // --- Тест 1: Проверка математики буста ---
    function testBoostLogic() public {
        uint256 duration = 1 days;
        vm.prank(owner);
        dungeon.startNewRaid(duration, 5000); // 50% max boost

        uint256 depositAmount = 100 * 1e6;

        // Алиса заходит сразу (максимальный буст)
        vm.startPrank(alice);
        IERC20(ASSET).approve(address(dungeon), depositAmount);
        dungeon.enterRaid(depositAmount);
        vm.stopPrank();

        // Проматываем время на 50% длительности фазы Open
        skip(duration / 2);

        // Боб заходит в середине (буст должен быть в 2 раза меньше)
        vm.startPrank(bob);
        IERC20(ASSET).approve(address(dungeon), depositAmount);
        dungeon.enterRaid(depositAmount);
        vm.stopPrank();

        ( , uint256 alicePower) = dungeon.adventurers(1, alice);
        ( , uint256 bobPower) = dungeon.adventurers(1, bob);

        assertGt(alicePower, bobPower, "Alice should have more power than Bob");
        console.log("Alice Power:", alicePower);
        console.log("Bob Power:", bobPower);
    }

    // --- Тест 2: Edge Case - Никто не зашел в рейд ---
    function testEmptyRaid() public {
        vm.prank(owner);
        dungeon.startNewRaid(1 days, 5000);

        skip(1.1 days);

        // Проверяем checkUpkeep
        (bool upkeepNeeded, ) = dungeon.checkUpkeep("");
        // Должно быть false, так как в коде мы добавили проверку totalRealDeposits > 0
        assertEq(upkeepNeeded, false, "Upkeep should not be needed for empty raid");
    }

    // --- Тест 3: Полный цикл и вывод средств (Mock VRF) ---
    function testFullFlowAndWithdraw() public {
        vm.prank(owner);
        dungeon.startNewRaid(1 days, 5000);

        // Алиса вносит депозит
        uint256 amount = 100 * 1e6;
        vm.startPrank(alice);
        IERC20(ASSET).approve(address(dungeon), amount);
        dungeon.enterRaid(amount);
        vm.stopPrank();

        skip(1.1 days);

        // Симулируем вызов от Chainlink Automation
        dungeon.performUpkeep("");

        // Симулируем ответ от Chainlink VRF
        // Находим requestId (он генерируется координатором)
        uint256 requestId = 1; // В тестах часто первый ID равен 1
        uint256[] memory words = new uint256[](1);
        words[0] = 777; // Случайное число

        // Вызываем fulfillment от имени Координатора
        vm.prank(VRF_COORDINATOR);
        dungeon.rawFulfillRandomWords(requestId, words);

        // Проверяем статус
        ( , , , , DungeonCore.RaidStatus status, address winner, , ) = dungeon.raids(1);
        assertEq(uint(status), uint(DungeonCore.RaidStatus.Finished));
        assertEq(winner, alice, "Alice should be the winner (only participant)");

        // Проверяем вывод тела депозита
        uint256 balanceBefore = IERC20(ASSET).balanceOf(alice);
        vm.prank(alice);
        dungeon.withdrawPrincipal(1);
        uint256 balanceAfter = IERC20(ASSET).balanceOf(alice);

        assertEq(balanceAfter - balanceBefore, amount, "Alice should get her principal back");
    }

    // --- Тест 4: Защита от преждевременного вывода ---
    function testCannotWithdrawEarly() public {
        vm.prank(owner);
        dungeon.startNewRaid(1 days, 5000);

        vm.startPrank(alice);
        IERC20(ASSET).approve(address(dungeon), 100 * 1e6);
        dungeon.enterRaid(100 * 1e6);

        vm.expectRevert("Raid not finished");
        dungeon.withdrawPrincipal(1);
        vm.stopPrank();
    }
}