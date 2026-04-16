// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/AutomationCompatibleInterface.sol";

contract DungeonCore is UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuard {
    
    // Переменные Chainlink VRF
    uint256 public s_subscriptionId;
    bytes32 public keyHash;
    uint32 public callbackGasLimit = 100000;

    //
    enum RaidStatus { Open, Closed, Finished }

    struct Raid {
        uint256 startTime;
        uint256 endTime;
        uint256 totalRealDeposits;
        uint256 totalWeightedPower;
        RaidStatus status;
        address winner;
        uint256 yieldGenerated;
    }

    mapping(uint256 => Raid) public raids;
    uint256 public currentRaidId;

    // Ограничение функций по состоянию рейда
    modifier onlyInStatus(uint256 _raidId, RaidStatus _status) {
        require(raids[_raidId].status == _status, "Invalid raid status");
        _;
    }

    /// @notice Вход в рейд с расчетом временного буста
    function enterRaid(uint256 _amount) 
        external 
        nonReentrant 
        onlyInStatus(currentRaidId, RaidStatus.Open) 
    {
        Raid storage raid = raids[currentRaidId];
        require(block.timestamp < raid.endTime, "Raid time expired");

        // Расчет буста B_t = 1 + (maxBoost * (endTime - current) / (endTime - startTime))
        // Используем базовые пункты (10000 = 100%) для точности
        uint256 timeRemaining = raid.endTime - block.timestamp;
        uint256 duration = raid.endTime - raid.startTime;
        
        // Линейно затухающий коэффициент
        uint256 currentBoost = 10000 + (maxBoost * timeRemaining / duration);
        uint256 weightedPower = (_amount * currentBoost) / 10000;

        // Обновление состояния (упрощенно)
        raid.totalRealDeposits += _amount;
        raid.totalWeightedPower += weightedPower;
        
        // Логика трансфера токенов в Vault (Aave/Compound) должна быть здесь [cite: 6, 34]
    }

    // Внутренняя функция для UUPS прокси 
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}