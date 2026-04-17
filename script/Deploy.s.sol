// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {DungeonCore} from "../src/DungeonCore.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployDungeon is Script {
    // Адреса для Sepolia Testnet
    address constant ASSET = 0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8; // USDC (Aave Sepolia)
    address constant AAVE_POOL = 0x6Ae43d534944d6df31b76198d4533eeFb452c10f; // Aave V3 Pool
    address constant VRF_COORDINATOR = 0x9DdfaCa811a735813D4e4dAD8F2dC23eb988cf39;
    bytes32 constant KEY_HASH = 0x787d74caea10b2b357790d5b5244c2f63d1d91572a9846f780606e4d953677ae;
    uint256 constant SUB_ID = 123456789; // Твой ID подписки Chainlink VRF

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

        vm.stopBroadcast();
    }
}