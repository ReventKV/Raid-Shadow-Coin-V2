// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console, Vm} from "forge-std/Test.sol";
import {DungeonCore} from "../src/DungeonCore.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink-brownie/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {MockAavePool} from "./mocks/MockAavePool.sol";

contract DungeonCoreTest is Test {
    DungeonCore public dungeon;
    VRFCoordinatorV2_5Mock public vrfMock;
    MockAavePool public mockPool;

    // Адреса Sepolia
    address constant ASSET = 0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8; // USDC

    uint256 subId;
    bytes32 constant KEY_HASH = 0x787d74caea10b2b357790d5b5244c2f63d1d91572a9846f780606e4d953677ae;

    address public owner = address(1);
    address public alice = address(2);
    address public bob = address(3);

    uint256 public constant INITIAL_BALANCE = 1000 * 1e6; // 1000 USDC (6 decimals)
    uint256 public constant MAX_BOOST = 5000; // 50%

    function setUp() public {
        // Форк Sepolia
        string memory rpcUrl = vm.envString("SEPOLIA_RPC_URL");
        vm.createSelectFork(rpcUrl);

        // Деплой моков
        vrfMock = new VRFCoordinatorV2_5Mock(0.1 ether, 0.001 ether, 1e18);
        mockPool = new MockAavePool();

        subId = vrfMock.createSubscription();
        vrfMock.fundSubscription(subId, 100 ether);

        // Деплой основного контракта
        DungeonCore implementation = new DungeonCore();
        bytes memory initData = abi.encodeWithSelector(
            DungeonCore.initialize.selector,
            ASSET,
            address(mockPool), // Используем наш Mock вместо реального Aave
            owner,
            subId,
            KEY_HASH,
            address(vrfMock),
            MAX_BOOST
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        dungeon = DungeonCore(address(proxy));

        vrfMock.addConsumer(subId, address(dungeon));

        // Подготовка фековых игроков
        deal(ASSET, alice, INITIAL_BALANCE);
        deal(ASSET, bob, INITIAL_BALANCE);

        vm.prank(alice);
        IERC20(ASSET).approve(address(dungeon), type(uint256).max);
        vm.prank(bob);
        IERC20(ASSET).approve(address(dungeon), type(uint256).max);
    }

    // Тесты Логики Контрактов

    function test_BoostCalculation() public {
        vm.startPrank(owner);
        dungeon.startNewRaid(1 hours, MAX_BOOST);
        vm.stopPrank();

        vm.prank(alice);
        dungeon.enterRaid(100 * 1e6);

        skip(30 minutes);

        vm.prank(bob);
        dungeon.enterRaid(100 * 1e6);

        (, uint256 alicePower) = dungeon.adventurers(1, alice);
        (, uint256 bobPower) = dungeon.adventurers(1, bob);

        assertGt(alicePower, bobPower, "Early participant should have more power");
        assertEq(alicePower, 150 * 1e6); // 1.5x boost
        assertEq(bobPower, 125 * 1e6); // 1.25x boost
    }

    function test_EnterRaidReverts() public {
        vm.prank(owner);
        dungeon.startNewRaid(1 hours, MAX_BOOST);

        skip(2 hours); // Время вышло

        vm.expectRevert("Raid time expired");
        vm.prank(alice);
        dungeon.enterRaid(100 * 1e6);
    }

    // Тесты на работу с пулом

    function test_SupplyToAave() public {
        vm.prank(owner);
        dungeon.startNewRaid(1 hours, MAX_BOOST);

        uint256 depositAmount = 500 * 1e6;
        vm.prank(alice);
        dungeon.enterRaid(depositAmount);

        // USDC должны уйти на адрес MockAavePool
        assertEq(IERC20(ASSET).balanceOf(address(dungeon)), 0);
        assertEq(IERC20(ASSET).balanceOf(address(mockPool)), depositAmount);
    }

    // Тесты работоспособности

    function test_FullCycleWithMockYield() public {
        // Старт и деп
        vm.prank(owner);
        dungeon.startNewRaid(1 days, MAX_BOOST);

        vm.prank(alice);
        dungeon.enterRaid(100 * 1e6);
        vm.prank(bob);
        dungeon.enterRaid(100 * 1e6);

        // Симуляция дохода от Aave (накидываю в MockPool 50 USDC сверху)
        uint256 yieldAmount = 50 * 1e6;
        deal(ASSET, address(this), yieldAmount);
        IERC20(ASSET).approve(address(mockPool), yieldAmount);
        mockPool.addYield(ASSET, yieldAmount);

        // З авершение рейда
        skip(1 days + 1);

        (bool upkeepNeeded,) = dungeon.checkUpkeep("");
        assertTrue(upkeepNeeded);

        vm.recordLogs();
        dungeon.performUpkeep("");
        uint256 requestId = _getVrfRequestId();

        //VRF Callback
        vrfMock.fulfillRandomWords(requestId, address(dungeon));

        //Проверки
        (,,,, DungeonCore.RaidStatus status, address winner, uint256 yieldGen,) = dungeon.raids(1);

        assertEq(uint256(status), uint256(DungeonCore.RaidStatus.Finished));
        assertTrue(winner == alice || winner == bob);
        assertEq(yieldGen, yieldAmount, "Yield should match the simulated amount");

        uint256 expectedWinnerBalance = INITIAL_BALANCE - (100 * 1e6) + yieldGen;
        assertEq(IERC20(ASSET).balanceOf(winner), expectedWinnerBalance);
    }

    // всякие Эдж тесты

    function test_SingleParticipantWins() public {
        vm.prank(owner);
        dungeon.startNewRaid(1 hours, MAX_BOOST);

        vm.prank(alice);
        dungeon.enterRaid(100 * 1e6);

        skip(2 hours);

        vm.recordLogs();
        dungeon.performUpkeep("");
        uint256 requestId = _getVrfRequestId();

        vrfMock.fulfillRandomWords(requestId, address(dungeon));

        (,,,,, address winner,,) = dungeon.raids(1);
        assertEq(winner, alice, "Single participant must win");
    }

    function test_WithdrawPrincipal() public {
        test_FullCycleWithMockYield(); // Запускаем полный цикл, чтобы завершить рейд

        //(,,,,, address winner,,) = dungeon.raids(1);

        // Проверяем Алису
        uint256 aliceBalanceBefore = IERC20(ASSET).balanceOf(alice);
        vm.prank(alice);
        dungeon.withdrawPrincipal(1);
        assertEq(IERC20(ASSET).balanceOf(alice), aliceBalanceBefore + (100 * 1e6)); // Вернула свои 100

        // Проверяем Боба
        uint256 bobBalanceBefore = IERC20(ASSET).balanceOf(bob);
        vm.prank(bob);
        dungeon.withdrawPrincipal(1);
        assertEq(IERC20(ASSET).balanceOf(bob), bobBalanceBefore + (100 * 1e6)); // Вернул свои 100
    }

    function test_Revert_FulfillOnlyByCoordinator() public {
        vm.prank(owner);
        dungeon.startNewRaid(1 days, 5000);

        vm.prank(alice);
        dungeon.enterRaid(100 * 1e6);

        skip(2 days);

        vm.recordLogs();
        dungeon.performUpkeep("");
        uint256 requestId = _getVrfRequestId();

        uint256[] memory words = new uint256[](1);
        words[0] = 123;

        vm.prank(alice);
        vm.expectRevert("Only Coordinator can fulfill");
        dungeon.rawFulfillRandomWords(requestId, words);
    }

    function _getVrfRequestId() internal returns (uint256) {
        Vm.Log[] memory entries = vm.getRecordedLogs();

        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter == address(vrfMock)) {
                uint256 reqId = abi.decode(entries[i].data, (uint256));
                return reqId;
            }
        }
        revert("VRF Request ID not found in logs");
    }
}
