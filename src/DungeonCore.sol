// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol"; 
import {VRFV2PlusClient} from "@chainlink-brownie/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {AutomationCompatibleInterface} from "@chainlink-brownie/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";
import {IVRFCoordinatorV2Plus} from "@chainlink-brownie/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPool} from "./interfaces/IPool.sol"; // Интерфейс Aave V3

contract DungeonCore is
         Initializable, 
    UUPSUpgradeable, 
    OwnableUpgradeable, 
    PausableUpgradeable, 
    ReentrancyGuard, 
    AutomationCompatibleInterface {
    
    //Переменные для Стейкинга
    IERC20 public asset;
    IPool public pool;

    //
    IVRFCoordinatorV2Plus public s_vrfCoordinator;
    uint256 public s_subscriptionId;
    bytes32 public keyHash;
    uint32 public callbackGasLimit;
    
    enum RaidStatus { Open, Closed, Finished }

    struct Adventurer {
        uint256 realDeposit;   // Сумма для возврата 
        uint256 weightedPower; // Сумма * буст для лотереи
    }

    struct Raid {
        uint256 startTime;
        uint256 endTime;
        uint256 totalRealDeposits;
        uint256 totalWeightedPower;
        RaidStatus status;
        address winner;
        uint256 yieldGenerated;
        uint256 maxBoost;
        address[] participants;
    }

    mapping(uint256 => mapping(address => Adventurer)) public adventurers;
    mapping(uint256 => Raid) public raids;
    mapping(uint256 => uint256) public vrfRequestToRaid; // Связь запроса VRF с ID рейда

    uint256 public currentRaidId;

    constructor() {
        _disableInitializers(); // Безопасность: предотвращает инициализацию реализации без прокси
    }

    event RaidStarted(uint256 indexed raidId, uint256 endTime, uint256 maxBoost);
    event WinnerSelected(uint256 indexed raidId, address winner, uint256 prize);

    function initialize(
        address _asset,
        address _aavePool,
        address _initialOwner,
        uint256 _subscriptionId,
        bytes32 _keyHash,
        address _vrfCoordinator,
        uint256 _defaultMaxBoost
    ) public initializer {

        
        // Инициализация базовых контрактов OpenZeppelin
        __Ownable_init(_initialOwner);
        __Pausable_init();
        
        // Инициализация Chainlink VRF (вызов конструктора базового класса вручную)
        // В новых версиях VRFConsumerBaseV2Plus это делается через внутренние переменные
        s_vrfCoordinator = IVRFCoordinatorV2Plus(_vrfCoordinator);
        s_subscriptionId = _subscriptionId;
        keyHash = _keyHash;
        callbackGasLimit = 300000;

        //Инициализация что и куда кладётся для стейкинга
        asset = IERC20(_asset);
        pool = IPool(_aavePool);


        currentRaidId = 0;

        // Одобряем пул Aave на бесконечный вывод
        asset.approve(_aavePool, type(uint256).max);
    }


    // Ограничение функций по состоянию рейда
    modifier onlyInStatus(uint256 _raidId, RaidStatus _status) {
        require(raids[_raidId].status == _status, "Invalid raid status");
        _;
    }
    
    /// @notice Вход в рейд с расчетом временного буста
    function enterRaid(uint256 _amount) 
        external 
        nonReentrant 
        onlyInStatus(currentRaidId, RaidStatus.Open) {
            
            Raid storage raid = raids[currentRaidId];
            require(block.timestamp < raid.endTime, "Raid time expired");

            asset.transferFrom(msg.sender, address(this), _amount);
            pool.supply(address(asset), _amount, address(this), 0);

            if (adventurers[currentRaidId][msg.sender].realDeposit == 0) {
                raid.participants.push(msg.sender);
            }   
            // Расчет буста B_t = 1 + (maxBoost * (endTime - current) / (endTime - startTime))
            // Используем базовые пункты (10000 = 100%) для точности
            uint256 timeRemaining = raid.endTime - block.timestamp;
            uint256 duration = raid.endTime - raid.startTime;
            
            // Линейно затухающий коэффициент
            uint256 currentBoost = 10000 + (raid.maxBoost * timeRemaining / duration);
            uint256 weightedPower = (_amount * currentBoost) / 10000;

            adventurers[currentRaidId][msg.sender].realDeposit += _amount;
            adventurers[currentRaidId][msg.sender].weightedPower += weightedPower;  

            // Обновление состояния (упрощенно)
            raid.totalRealDeposits += _amount;
            raid.totalWeightedPower += weightedPower;
    }


    function checkUpkeep(bytes calldata /* checkData */) 
        external 
        view 
        override 
        returns (bool upkeepNeeded, bytes memory performData) {
        Raid storage raid = raids[currentRaidId];
        // Условие: время вышло, но рейд всё ещё открыт
        upkeepNeeded = (block.timestamp >= raid.endTime && raid.status == RaidStatus.Open);
    }

    /**
     * @dev Выполнение перехода состояния и запрос рандома
     */
    function performUpkeep(bytes calldata /* performData */) 
        external 
        override {
        Raid storage raid = raids[currentRaidId];
        require(block.timestamp >= raid.endTime && raid.status == RaidStatus.Open, "Condition not meet: too early or too late");
        if (raid.totalRealDeposits > 0 ) {raid.status = RaidStatus.Closed; return;} 
        raid.status = RaidStatus.Closed;

        // Запрос случайного числа у Chainlink VRF
        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: s_subscriptionId,
                requestConfirmations: 3,
                callbackGasLimit: callbackGasLimit,
                numWords: 1,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: false}))
            })
        );

        vrfRequestToRaid[requestId] = currentRaidId;
    }

   /**
     * @dev Эту функцию вызывает VRFCoordinator. 
     * Мы реализуем её вручную, чтобы избежать конфликтов наследования.
     */
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != address(s_vrfCoordinator)) revert("Only Coordinator can fulfill");
        fulfillRandomWords(requestId, randomWords);
    }

    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal {
        uint256 raidId = vrfRequestToRaid[requestId];
        Raid storage raid = raids[raidId];
        if (raid.status != RaidStatus.Closed) return;

        uint256 winningTicket = randomWords[0] % raid.totalWeightedPower;
        uint256 cumulativePower = 0;
        address winner;

        for (uint256 i = 0; i < raid.participants.length; i++) {
            address participant = raid.participants[i];
            cumulativePower += adventurers[raidId][participant].weightedPower;
            if (cumulativePower > winningTicket) {
                winner = participant;
                break;
            }
        }

        raid.winner = winner;
        _finishRaid(raidId);
    }
    

    function _finishRaid(uint256 _raidId) internal {
        Raid storage raid = raids[_raidId];
        
        // Выводим ВСЕ средства из Aave (тело + доход)
        // В Aave V3 вывод max uint256 выводит весь баланс aToken
        uint256 totalBalance = pool.withdraw(address(asset), type(uint256).max, address(this));
        
        raid.yieldGenerated = totalBalance - raid.totalRealDeposits;
        raid.status = RaidStatus.Finished;

        // Отправляем доход победителю
        if (raid.yieldGenerated > 0 && raid.winner != address(0)) {
            asset.transfer(raid.winner, raid.yieldGenerated);
        }

        emit WinnerSelected(_raidId, raid.winner, raid.yieldGenerated);
    }


    /**
     * @notice Пользователи забирают свои депозиты после завершения рейда
     */
    function withdrawPrincipal(uint256 _raidId) external nonReentrant {
        require(raids[_raidId].status == RaidStatus.Finished, "Raid not finished");
        uint256 amount = adventurers[_raidId][msg.sender].realDeposit;
        require(amount > 0, "Nothing to withdraw");

        adventurers[_raidId][msg.sender].realDeposit = 0;
        asset.transfer(msg.sender, amount);
    }

    
    function startNewRaid(uint256 _duration, uint256 _maxBoost) external onlyOwner {
    // Убеждаемся, что текущий рейд либо не существует (самый первый), 
    // либо уже полностью завершен
        require(
            currentRaidId == 0 || raids[currentRaidId].status == RaidStatus.Finished, 
            "Previous raid still active"
        );

        currentRaidId++;
        
        Raid storage newRaid = raids[currentRaidId];
        newRaid.startTime = block.timestamp;
        newRaid.endTime = block.timestamp + _duration;
        newRaid.maxBoost = _maxBoost;
        newRaid.status = RaidStatus.Open;

        emit RaidStarted(currentRaidId, newRaid.endTime, _maxBoost);
    }   


    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function _authorizeUpgrade(address newImplementation) internal virtual override onlyOwner {}
}