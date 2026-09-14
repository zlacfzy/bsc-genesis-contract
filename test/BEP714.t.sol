pragma solidity ^0.8.17;

import "forge-std/Test.sol";

interface IBEP714ValidatorSet {
    function init() external;
    function tryEnterMaintenance(
        address validator
    ) external;
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
    function getSlashIndicator(
        address validator
    ) external view returns (uint256, uint256);
    function settleMaintenance(address validator, uint256 count) external;
    function indicators(
        address validator
    ) external view returns (uint256, uint256, bool);
    function validators(
        uint256 index
    ) external view returns (address);
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
        // populate validatorExtraSet, which live chains did at the BEP-127 upgrade
        vm.prank(address(slash));
        validators.tryEnterMaintenance(address(0));
        members = validators.getValidators();
    }

    function _param(address target, string memory key, uint256 value) internal {
        vm.prank(GOV);
        IBEP714ValidatorSet(target).updateParam(key, abi.encode(value));
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
        (, count) = slash.getSlashIndicator(validator);
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

    function _exit(
        address validator
    ) internal {
        vm.prank(validator);
        validators.exitMaintenance();
    }

    function _forceDailyUpdate() internal {
        uint64[] memory powers = new uint64[](members.length);
        bytes[] memory votes = new bytes[](members.length);
        for (uint256 i; i < members.length; ++i) {
            powers[i] = 1;
        }
        vm.prank(PRODUCER);
        validators.updateValidatorSetV2(members, powers, votes);
    }

    function _useLegacyParams() internal {
        _param(address(slash), "felonyThreshold", 1000);
        _param(address(slash), "misdemeanorThreshold", 333);
        _param(address(validators), "maxNumOfMaintaining", 0);
    }

    // Pre-BEP-714 indicators are plain (height, count, exist) records. Seed one directly:
    // SlashIndicator keeps `validators` at slot 1 and `indicators` at slot 2.
    function _seedLegacyIndicator(address validator, uint256 count) internal {
        bytes32 base = keccak256(abi.encode(validator, uint256(2)));
        vm.store(address(slash), base, bytes32(block.number));
        vm.store(address(slash), bytes32(uint256(base) + 1), bytes32(count));
        vm.store(address(slash), bytes32(uint256(base) + 2), bytes32(uint256(1)));
        uint256 length = uint256(vm.load(address(slash), bytes32(uint256(1))));
        bytes32 element = bytes32(uint256(keccak256(abi.encode(uint256(1)))) + length);
        vm.store(address(slash), element, bytes32(uint256(uint160(validator))));
        vm.store(address(slash), bytes32(uint256(1)), bytes32(length + 1));
        (, uint256 stored, bool exist) = slash.indicators(validator);
        assertEq(stored, count);
        assertTrue(exist);
        assertEq(slash.validators(length), validator);
    }

    /*----------------- admission -----------------*/

    function testThresholdEntryWithoutPenalty() public {
        address validator = members[0];
        uint256 income = _deposit(validator);
        _miss(validator, 39);
        assertTrue(validators.isCurrentValidator(validator));
        _miss(validator, 1); // the 40th miss admits the validator in the same slash transaction
        assertFalse(validators.isCurrentValidator(validator));
        assertEq(validators.getIncoming(validator), income);
        _miss(validator, 4); // misses after entry are not counted
        assertEq(_count(validator), 40);
    }

    function testCapacityIsGrantedInArrivalOrderAndRetried() public {
        for (uint256 i; i < 4; ++i) {
            _miss(members[i], 40);
        }
        for (uint256 i; i < 3; ++i) {
            assertFalse(validators.isCurrentValidator(members[i]));
        }
        assertTrue(validators.isCurrentValidator(members[3])); // capacity 3
        _miss(members[3], 5);
        assertTrue(validators.isCurrentValidator(members[3]));
        assertEq(_count(members[3]), 45);
        _exit(members[0]);
        _miss(members[3], 1); // retried on the next miss once capacity is free
        assertFalse(validators.isCurrentValidator(members[3]));
        _miss(members[0], 1); // once per day
        assertTrue(validators.isCurrentValidator(members[0]));
    }

    function testAutomaticMaintenanceRequiresEnabledMaintenance() public {
        _param(address(validators), "maxNumOfMaintaining", 0);
        _miss(members[0], 40);
        assertTrue(validators.isCurrentValidator(members[0])); // BEP-127: zero disables maintenance
        _param(address(validators), "maxNumOfMaintaining", 3);
        _miss(members[0], 1);
        assertFalse(validators.isCurrentValidator(members[0]));
    }

    function testAutomaticMaintenancePreservesLastWorkingValidator() public {
        address[] memory smallSet = new address[](2);
        smallSet[0] = members[0];
        smallSet[1] = members[1];
        uint64[] memory powers = new uint64[](2);
        bytes[] memory votes = new bytes[](2);
        vm.prank(PRODUCER);
        validators.updateValidatorSetV2(smallSet, powers, votes);
        _miss(smallSet[0], 40);
        assertFalse(validators.isCurrentValidator(smallSet[0]));
        _miss(smallSet[1], 40);
        assertTrue(validators.isCurrentValidator(smallSet[1]));
        assertEq(validators.getValidators().length, 1);
    }

    /*----------------- settlement -----------------*/

    function testCombinedSettlementAtMisdemeanorAndPersistence() public {
        address validator = members[0];
        _deposit(validator);
        _miss(validator, 40);
        _advanceMaintenance(validator, 160);
        _exit(validator);
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
        _advanceMaintenance(validator, 159);
        _exit(validator);
        assertEq(_count(validator), 199);
        assertEq(validators.getIncoming(validator), income);
        _miss(validator, 1); // ordinary slashing charges the boundary
        assertEq(validators.getIncoming(validator), 0);
    }

    function testManualEntryIncludesMisses() public {
        address validator = members[0];
        _miss(validator, 30);
        vm.prank(validator);
        validators.enterMaintenance();
        _advanceMaintenance(validator, 10);
        _exit(validator);
        assertEq(_count(validator), 40);
    }

    function testMisdemeanorEntryDoesNotChargeTwice() public {
        address validator = members[0];
        _param(address(validators), "maxNumOfMaintaining", 0);
        _miss(validator, 199);
        _param(address(validators), "maxNumOfMaintaining", 3);
        _miss(validator, 1); // ordinary misdemeanor synchronously enters maintenance
        assertFalse(validators.isCurrentValidator(validator));
        uint256 income = _deposit(validator);
        _advanceMaintenance(validator, 1);
        _exit(validator);
        assertEq(_count(validator), 201); // entry must capture the 200th miss
        assertEq(validators.getIncoming(validator), income);
    }

    function testCountJumpChargesOnlyOnce() public {
        address validator = members[0];
        _deposit(validator);
        _miss(validator, 40);
        _advanceMaintenance(validator, 410);
        _exit(validator);
        assertEq(_count(validator), 450);
        assertEq(validators.getIncoming(validator), 0);
        uint256 income = _deposit(validator);
        _miss(validator, 1);
        assertEq(validators.getIncoming(validator), income);
    }

    function testCombinedFelonyResetsCount() public {
        address validator = members[0];
        _miss(validator, 40);
        _advanceMaintenance(validator, 560);
        _exit(validator);
        assertFalse(validators.isCurrentValidator(validator));
        assertEq(_count(validator), 0);
        vm.expectRevert("only current validators");
        validators.getCurrentValidatorIndex(validator);
    }

    function testForcedExitFelonyResetsCount() public {
        address validator = members[0];
        _miss(validator, 40);
        _advanceMaintenance(validator, 560);
        _forceDailyUpdate();
        assertFalse(validators.isCurrentValidator(validator));
        assertEq(_count(validator), 0);
    }

    function testManualFelonyDoesNotCreateEmptyIndicator() public {
        address validator = members[0];
        vm.prank(validator);
        validators.enterMaintenance();
        _advanceMaintenance(validator, 600);
        _exit(validator);
        (, uint256 count, bool exists) = slash.indicators(validator);
        assertEq(count, 0);
        assertFalse(exists);
        vm.expectRevert();
        slash.validators(0);
    }

    function testLegacySessionKeepsIndependentAccounting() public {
        address validator = members[0];
        uint256 income = _deposit(validator);
        _miss(validator, 40);
        uint256 index = validators.getCurrentValidatorIndex(validator);
        // ValidatorExtra array at slot 11, stride 22 words, reserved words start at offset 3.
        uint256 entrySlot = uint256(keccak256(abi.encode(uint256(11)))) + index * 22 + 3;
        assertEq(uint256(vm.load(address(validators), bytes32(entrySlot))), 41);
        vm.store(address(validators), bytes32(entrySlot), bytes32(0)); // a session that predates the upgrade
        _advanceMaintenance(validator, 160);
        _exit(validator);
        assertEq(_count(validator), 40);
        assertEq(validators.getIncoming(validator), income); // 160 < 200, not 40 + 160
    }

    function testFuzzMaintenanceCount(uint16 missing, uint16 equivalent) public {
        uint256 entry = bound(missing, 0, 39);
        uint256 elapsed = bound(equivalent, 0, 599 - entry);
        address validator = members[0];
        _miss(validator, entry);
        vm.prank(validator);
        validators.enterMaintenance();
        _advanceMaintenance(validator, elapsed);
        _exit(validator);
        assertEq(_count(validator), entry + elapsed);
    }

    function testDailySettlementPersistsThenDecays() public {
        address validator = members[0];
        _miss(validator, 40);
        _advanceMaintenance(validator, 160);
        _forceDailyUpdate();
        assertEq(_count(validator), 50); // 200 - 600 / 4
        uint256 income = _deposit(validator);
        _miss(validator, 1); // 51 >= 40 and the daily allowance was reset
        assertEq(validators.getIncoming(validator), income);
        assertFalse(validators.isCurrentValidator(validator));
    }

    /*----------------- governance -----------------*/

    function testGovernanceBoundsAndAuthorization() public {
        assertEq(slash.maintenanceThreshold(), 40);
        vm.expectRevert("the message sender must be slash contract");
        validators.tryEnterMaintenance(members[0]);
        vm.expectRevert("the message sender must be validatorSet contract");
        slash.settleMaintenance(members[0], 0);
        vm.expectRevert("the maintenanceThreshold out of range");
        _param(address(slash), "maintenanceThreshold", 0);
        vm.expectRevert("the maintenanceThreshold out of range");
        _param(address(slash), "maintenanceThreshold", 200);
        vm.expectRevert("the misdemeanorThreshold out of range");
        _param(address(slash), "misdemeanorThreshold", 40);
        _param(address(slash), "maintenanceThreshold", 41);
        assertEq(slash.maintenanceThreshold(), 41);
    }

    function testGovernanceChangeDuringMaintenance() public {
        address validator = members[0];
        _param(address(slash), "felonyThreshold", 1000);
        _param(address(slash), "misdemeanorThreshold", 333);
        _miss(validator, 40);
        _advanceMaintenance(validator, 160);
        _param(address(slash), "misdemeanorThreshold", 200);
        _param(address(slash), "felonyThreshold", 600);
        _deposit(validator);
        _exit(validator);
        assertEq(_count(validator), 200);
        assertEq(validators.getIncoming(validator), 0);
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

    // Threshold changes are not retroactive: ordinary slashing waits for the next multiple of the new threshold.
    function testLoweredMisdemeanorThresholdIsNotRetroactive() public {
        address validator = members[0];
        _param(address(validators), "maxNumOfMaintaining", 0);
        _miss(validator, 380); // charged at 200
        _param(address(slash), "misdemeanorThreshold", 150);
        uint256 income = _deposit(validator);
        _miss(validator, 69); // 449
        assertEq(validators.getIncoming(validator), income);
        _miss(validator, 1); // 450
        assertEq(validators.getIncoming(validator), 0);
    }

    function testLoweredMisdemeanorThresholdDuringMaintenanceComparesEntryAndTotal() public {
        address validator = members[0];
        _param(address(validators), "maxNumOfMaintaining", 0);
        _miss(validator, 180);
        _param(address(validators), "maxNumOfMaintaining", 3);
        vm.prank(validator);
        validators.enterMaintenance();
        _param(address(slash), "misdemeanorThreshold", 100);
        uint256 income = _deposit(validator);
        _exit(validator); // zero maintenance increment: 180 / 100 == 180 / 100
        assertEq(_count(validator), 180);
        assertEq(validators.getIncoming(validator), income);
    }

    function testRaisedMisdemeanorThresholdIsNotRetroactive() public {
        address validator = members[0];
        _param(address(validators), "maxNumOfMaintaining", 0);
        _miss(validator, 380); // charged at 200
        _param(address(slash), "misdemeanorThreshold", 300);
        uint256 income = _deposit(validator);
        _miss(validator, 1);
        assertEq(validators.getIncoming(validator), income);
    }

    /*----------------- pre-upgrade indicators -----------------*/

    function testUpgradePreservesPreviouslyChargedIndicator() public {
        _useLegacyParams();
        address validator = members[0];
        _seedLegacyIndicator(validator, 333); // the old implementation charged this boundary
        uint256 income = _deposit(validator);
        _miss(validator, 1);
        assertEq(_count(validator), 334);
        assertEq(validators.getIncoming(validator), income);
    }

    function testUpgradeChargesFirstBoundaryOnce() public {
        _useLegacyParams();
        address validator = members[0];
        _seedLegacyIndicator(validator, 332);
        _deposit(validator);
        _miss(validator, 1);
        assertEq(_count(validator), 333);
        assertEq(validators.getIncoming(validator), 0);
        uint256 income = _deposit(validator);
        _miss(validator, 1);
        assertEq(validators.getIncoming(validator), income);
    }

    function testDecayKeepsModuloBoundaries() public {
        address validator = members[0];
        _param(address(validators), "maxNumOfMaintaining", 0);
        _miss(validator, 399); // charged at 200
        vm.prank(address(validators));
        slash.clean();
        assertEq(_count(validator), 249);
        uint256 income = _deposit(validator);
        _miss(validator, 150); // 399
        assertEq(validators.getIncoming(validator), income);
        _miss(validator, 1); // 400
        assertEq(validators.getIncoming(validator), 0);
    }
}
