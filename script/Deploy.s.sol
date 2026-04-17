// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {DungeonCore} from "../src/DungeonCore.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployDungeon is Script {
    // Адреса для Sepolia Testnet
    address constant ASSET = 0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8; // USDC (Aave Sepolia)
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2; // Aave V3 Pool
    address constant VRF_COORDINATOR =0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B;
    bytes32 constant KEY_HASH = 0x787d74caea10b2b357790d5b5244c2f63d1d91572a9846f780606e4d953677ae;
    uint256 constant SUB_ID = 56358236429338791114483957913597823340078748010671808189139093886351107633268; // Твой ID подписки Chainlink VRF

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Деплоим контракт реализации (Implementation)
        DungeonCore implementation = new DungeonCore();
        console.log("Implementation deployed at:", address(implementation));

        // 2. Подготавливаем данные для вызова initialize()
        bytes memory initData = abi.encodeWithSelector(
            DungeonCore.initialize.selector,
            ASSET,
            AAVE_POOL,
            owner,
            SUB_ID,
            KEY_HASH,
            VRF_COORDINATOR,
            5000 // defaultMaxBoost (50%)
        );

        // 3. Деплоим прокси и связываем его с реализацией
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        console.log("Proxy (DungeonCore) deployed at:", address(proxy));

        DungeonCore dungeon = DungeonCore(address(proxy));

        console.log("----------------------------------------------");
        console.log("PROXY (Yield Dungeons) deployed at:", address(dungeon));
        console.log("Asset Address:", address(dungeon.asset()));
        console.log("Owner Address:", dungeon.owner());
        console.log("----------------------------------------------");
        console.log("CRITICAL STEP: Add the PROXY address above as a Consumer");
        console.log("in your Chainlink VRF Subscription #", SUB_ID);
        console.log("----------------------------------------------");

        vm.stopBroadcast();
    }
}