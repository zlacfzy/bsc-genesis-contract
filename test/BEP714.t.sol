pragma solidity ^0.8.17;

import "forge-std/Test.sol";

interface IBEP714ValidatorSet {
    function init() external;
    function checkMaintenance() external;
    function enterMaintenance() external;
    function exitMaintenance() external;
    function updateParam(string calldata key, bytes calldata value) external;
    function getValidators() external view returns (address[] memory);
    function isCurrentValidator(
        address validator
    ) external view returns (bool);
    function getWorkingValidatorCount() external view returns (uint256);
    function getCurrentValidatorIndex(
        address validator
    ) external view returns (uint256);
    function validatorExtraSet(
        uint256 index
    ) external view returns (uint256, bool, bytes memory);
    function getIncoming(
        address validator
    ) external view returns (uint256);
    function deposit(
        address validator
    ) external payable;
    function updateValidatorSetV2(
        address[] calldata validators,
        uint64[] calldata powers,
        bytes[] calldata votes
    ) external;
}

interface IBEP714SlashIndicator {
    function init() external;
    function slash(
        address validator
    ) external;
    function clean() external;
    function updateParam(string calldata key, bytes calldata value) external;
    function maintenanceThreshold() external view returns (uint256);
    function getMaintenanceIndicator(
        address validator
    ) external view returns (uint256, uint256);
    function settleMaintenance(address validator, uint256 count, uint256 charged) external returns (bool);
}

// Runs against real system-contract bytecode and fresh storage, without an RPC fork.
contract BEP714Test is Test {
    IBEP714ValidatorSet internal validators = IBEP714ValidatorSet(address(0x1000));
    IBEP714SlashIndicator internal slash = IBEP714SlashIndicator(address(0x1001));
    address internal constant GOV = address(0x1007);
    address internal constant PRODUCER = address(0xbeef);
    address[] internal members;

    function setUp() public {
        vm.roll(1);
        vm.coinbase(PRODUCER);
        vm.txGasPrice(0);
        vm.deal(PRODUCER, 100 ether);
        vm.etch(address(validators), vm.getDeployedCode("BSCValidatorSet.sol:BSCValidatorSet"));
        vm.etch(address(slash), vm.getDeployedCode("SlashIndicator.sol:SlashIndicator"));
        // Downtime jail and reward distribution are tested separately in StakeHub.
        vm.etch(address(0x2002), hex"00");
        vm.mockCall(address(0x2002), abi.encodeWithSignature("consensusToOperator(address)"), abi.encode(address(0)));
        validators.init();
        slash.init();
        _param(address(slash), "felonyThreshold", 600);
        _param(address(slash), "misdemeanorThreshold", 200);
        _param(address(validators), "maxNumOfMaintaining", 3);
        _param(address(validators), "maintainSlashScale", 3);
        _check(); // initialize the existing validator-extra array
        members = validators.getValidators();
    }

    function _param(address target, string memory key, uint256 value) internal {
        vm.prank(GOV);
        IBEP714ValidatorSet(target).updateParam(key, abi.encode(value));
    }

    function _check() internal {
        vm.prank(PRODUCER);
        validators.checkMaintenance();
    }

    function _miss(address validator, uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            vm.roll(block.number + 1);
            vm.prank(PRODUCER);
            slash.slash(validator);
        }
    }

    function _count(
        address validator
    ) internal view returns (uint256 count) {
        (count,) = slash.getMaintenanceIndicator(validator);
    }

    function _deposit(
        address validator
    ) internal returns (uint256) {
        vm.prank(PRODUCER);
        validators.deposit{ value: 1 ether }(validator);
        return validators.getIncoming(validator);
    }

    function _advanceMaintenance(address validator, uint256 count) internal {
        (uint256 height,,) = validators.validatorExtraSet(validators.getCurrentValidatorIndex(validator));
        vm.roll(height + count * validators.getWorkingValidatorCount() * 3);
    }

    function testThresholdAndRewardPreservation() public {
        address validator = members[0];
        uint256 income = _deposit(validator);
        _miss(validator, 39);
        _check();
        assertTrue(validators.isCurrentValidator(validator));
        _miss(validator, 1);
        _check();
        assertFalse(validators.isCurrentValidator(validator));
        assertEq(validators.getIncoming(validator), income);
        _miss(validator, 4); // snapshot lag must not create ordinary penalties
        assertEq(_count(validator), 40);
        _check(); // idempotent
    }

    function testCapacityUsesAddressOrderAndRetries() public {
        for (uint256 i; i < 4; ++i) {
            _miss(members[i], 40);
        }
        address[] memory ordered = new address[](4);
        for (uint256 i; i < 4; ++i) {
            ordered[i] = members[i];
        }
        for (uint256 i; i < 4; ++i) {
            for (uint256 j = i + 1; j < 4; ++j) {
                if (ordered[j] < ordered[i]) (ordered[i], ordered[j]) = (ordered[j], ordered[i]);
            }
        }
        _check();
        for (uint256 i; i < 3; ++i) {
            assertFalse(validators.isCurrentValidator(ordered[i]));
        }
        assertTrue(validators.isCurrentValidator(ordered[3]));
        vm.prank(ordered[0]);
        validators.exitMaintenance();
        _check();
        assertTrue(validators.isCurrentValidator(ordered[0])); // once per day
        assertFalse(validators.isCurrentValidator(ordered[3]));
    }

    function testCombinedSettlementAtMisdemeanorAndPersistence() public {
        address validator = members[0];
        _deposit(validator);
        _miss(validator, 40);
        _check();
        _advanceMaintenance(validator, 160);
        vm.prank(validator);
        validators.exitMaintenance();
        assertEq(_count(validator), 200);
        assertEq(validators.getIncoming(validator), 0);
        uint256 income = _deposit(validator);
        _miss(validator, 1);
        assertEq(_count(validator), 201);
        assertEq(validators.getIncoming(validator), income);
    }

    function testNoPenaltyBelowCombinedThreshold() public {
        address validator = members[0];
        uint256 income = _deposit(validator);
        _miss(validator, 40);
        _check();
        _advanceMaintenance(validator, 159);
        vm.prank(validator);
        validators.exitMaintenance();
        assertEq(_count(validator), 199);
        assertEq(validators.getIncoming(validator), income);
        _miss(validator, 1);
        assertEq(validators.getIncoming(validator), 0);
    }

    function testManualEntryIncludesMisses() public {
        address validator = members[0];
        _miss(validator, 30);
        vm.prank(validator);
        validators.enterMaintenance();
        _advanceMaintenance(validator, 10);
        vm.prank(validator);
        validators.exitMaintenance();
        assertEq(_count(validator), 40);
    }

    function testMisdemeanorEntryDoesNotChargeTwice() public {
        address validator = members[0];
        _miss(validator, 200); // ordinary misdemeanor synchronously enters maintenance
        uint256 income = _deposit(validator);
        _advanceMaintenance(validator, 1);
        vm.prank(validator);
        validators.exitMaintenance();
        assertEq(_count(validator), 201); // entry must capture the 200th miss
        assertEq(validators.getIncoming(validator), income);
    }

    function testCombinedFelonyResetsCount() public {
        address validator = members[0];
        _miss(validator, 40);
        _check();
        _advanceMaintenance(validator, 560);
        vm.prank(validator);
        validators.exitMaintenance();
        assertFalse(validators.isCurrentValidator(validator));
        assertEq(_count(validator), 0);
        vm.expectRevert("only current validators");
        validators.getCurrentValidatorIndex(validator);
    }

    function testLegacySessionKeepsIndependentAccounting() public {
        address validator = members[0];
        uint256 income = _deposit(validator);
        _miss(validator, 40);
        _check();
        uint256 index = validators.getCurrentValidatorIndex(validator);
        // Pre-upgrade ValidatorExtra: array at slot 11, stride 22 words,
        // reserved words start at offset 3. Legacy sessions have zero markers.
        uint256 entrySlot = uint256(keccak256(abi.encode(uint256(11)))) + index * 22 + 3;
        assertEq(uint256(vm.load(address(validators), bytes32(entrySlot))), 41);
        vm.store(address(validators), bytes32(entrySlot), bytes32(0));
        vm.store(address(validators), bytes32(entrySlot + 1), bytes32(0));
        _advanceMaintenance(validator, 160);
        vm.prank(validator);
        validators.exitMaintenance();
        assertEq(_count(validator), 40);
        assertEq(validators.getIncoming(validator), income); // 160 < 200, not 40 + 160
    }

    function testCountJumpChargesOnlyOnce() public {
        address validator = members[0];
        _deposit(validator);
        _miss(validator, 40);
        _check();
        _advanceMaintenance(validator, 410);
        vm.prank(validator);
        validators.exitMaintenance();
        assertEq(_count(validator), 450);
        uint256 income = _deposit(validator);
        _miss(validator, 1);
        assertEq(validators.getIncoming(validator), income);
    }

    function testGovernanceChangeDuringMaintenance() public {
        address validator = members[0];
        _param(address(slash), "felonyThreshold", 1000);
        _param(address(slash), "misdemeanorThreshold", 333);
        _miss(validator, 40);
        _check();
        _advanceMaintenance(validator, 160);
        _param(address(slash), "misdemeanorThreshold", 200);
        _param(address(slash), "felonyThreshold", 600);
        _deposit(validator);
        vm.prank(validator);
        validators.exitMaintenance();
        assertEq(_count(validator), 200);
        assertEq(validators.getIncoming(validator), 0);
    }

    function testFuzzMaintenanceCount(uint16 missing, uint16 equivalent) public {
        uint256 entry = bound(missing, 0, 39);
        uint256 elapsed = bound(equivalent, 0, 599 - entry);
        address validator = members[0];
        _miss(validator, entry);
        vm.prank(validator);
        validators.enterMaintenance();
        _advanceMaintenance(validator, elapsed);
        vm.prank(validator);
        validators.exitMaintenance();
        assertEq(_count(validator), entry + elapsed);
    }

    function testLoweredFelonyThresholdDoesNotWaitForMultiple() public {
        address validator = members[0];
        _param(address(validators), "maxNumOfMaintaining", 0);
        _param(address(slash), "felonyThreshold", 1000);
        _miss(validator, 650);
        _param(address(slash), "felonyThreshold", 600);
        _miss(validator, 1);
        assertEq(_count(validator), 0);
        assertFalse(validators.isCurrentValidator(validator));
    }

    function testGovernanceBoundsAndAuthorization() public {
        assertEq(slash.maintenanceThreshold(), 40);
        vm.expectRevert("the message sender must be the block producer");
        validators.checkMaintenance();
        vm.expectRevert("the message sender must be validatorSet contract");
        slash.settleMaintenance(members[0], 0, 0);
        vm.expectRevert("the maintenanceThreshold out of range");
        _param(address(slash), "maintenanceThreshold", 0);
        vm.expectRevert("the maintenanceThreshold out of range");
        _param(address(slash), "maintenanceThreshold", 200);
        vm.expectRevert("the misdemeanorThreshold out of range");
        _param(address(slash), "misdemeanorThreshold", 40);
        _param(address(slash), "maintenanceThreshold", 41);
        assertEq(slash.maintenanceThreshold(), 41);
    }

    function testDailySettlementPersistsThenDecays() public {
        address validator = members[0];
        _miss(validator, 40);
        _check();
        _advanceMaintenance(validator, 160);
        uint64[] memory powers = new uint64[](members.length);
        bytes[] memory votes = new bytes[](members.length);
        for (uint256 i; i < members.length; ++i) {
            powers[i] = 1;
        }
        vm.prank(PRODUCER);
        validators.updateValidatorSetV2(members, powers, votes);
        assertEq(_count(validator), 50); // 200 - 600 / 4
        uint256 income = _deposit(validator);
        _miss(validator, 1);
        assertEq(validators.getIncoming(validator), income);
        _check(); // daily maintenance eligibility was reset
        assertFalse(validators.isCurrentValidator(validator));
    }
}
