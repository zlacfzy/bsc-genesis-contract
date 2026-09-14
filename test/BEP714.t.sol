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

    function _useLegacyParams() internal {
        _param(address(slash), "felonyThreshold", 1000);
        _param(address(slash), "misdemeanorThreshold", 333);
        _param(address(validators), "maxNumOfMaintaining", 0);
    }

    // Pre-BEP-714 indicators were produced by `%` slashing and carry no charged-boundary
    // record. Seed one directly: SlashIndicator keeps `validators` at slot 1 and
    // `indicators` at slot 2 as (height, count, exist).
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

    function testUpgradePreservesPreviouslyChargedIndicator() public {
        _useLegacyParams();
        address validator = members[0];
        _seedLegacyIndicator(validator, 333); // the old implementation charged this boundary
        uint256 income = _deposit(validator);
        (uint256 count, uint256 charged) = slash.getMaintenanceIndicator(validator);
        assertEq(count, 333);
        assertEq(charged, 333);
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

    function testUpgradeGovernanceTracksOldBoundaryBeforeFirstSlash() public {
        _useLegacyParams();
        address validator = members[0];
        _seedLegacyIndicator(validator, 333);
        uint256 income = _deposit(validator);
        _param(address(slash), "misdemeanorThreshold", 200);
        (, uint256 charged) = slash.getMaintenanceIndicator(validator);
        assertEq(charged, 333);
        _miss(validator, 1);
        assertEq(validators.getIncoming(validator), income);
        _miss(validator, 66); // the next uncharged boundary is 400
        assertEq(validators.getIncoming(validator), 0);
    }

    function testUpgradeDailyDecayBeforeFirstSlash() public {
        _useLegacyParams();
        address validator = members[0];
        _seedLegacyIndicator(validator, 333);
        vm.prank(address(validators));
        slash.clean();
        (uint256 count, uint256 charged) = slash.getMaintenanceIndicator(validator);
        assertEq(count, 83); // 333 - 1000 / 4
        assertEq(charged, 83);
        uint256 income = _deposit(validator);
        _miss(validator, 1);
        assertEq(validators.getIncoming(validator), income);
    }

    function testUninitializedSlashSkipsAutomaticMaintenance() public {
        _seedLegacyIndicator(members[0], 40);
        // Restore the inherited init flag and threshold slots to bootstrap values.
        vm.store(address(slash), bytes32(uint256(0)), bytes32(0));
        vm.store(address(slash), bytes32(uint256(4)), bytes32(0));
        vm.store(address(slash), bytes32(uint256(5)), bytes32(0));
        (uint256 count, uint256 charged) = slash.getMaintenanceIndicator(members[0]);
        assertEq(count, 0);
        assertEq(charged, 0);
        _check(); // must neither divide by zero nor admit anyone
        assertTrue(validators.isCurrentValidator(members[0]));
        slash.init();
        _check();
        assertFalse(validators.isCurrentValidator(members[0]));
    }

    function testMissingCompanionUpgradeReverts() public {
        vm.etch(address(slash), hex"00"); // a SlashIndicator without the BEP-714 entry points
        vm.prank(PRODUCER);
        vm.expectRevert();
        validators.checkMaintenance();
    }

    function testManualFelonyDoesNotCreateEmptyIndicator() public {
        address validator = members[0];
        vm.prank(validator);
        validators.enterMaintenance();
        _advanceMaintenance(validator, 600);
        vm.prank(validator);
        validators.exitMaintenance();
        (, uint256 count, bool exists) = slash.indicators(validator);
        assertEq(count, 0);
        assertFalse(exists);
        vm.expectRevert();
        slash.validators(0);
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
        _miss(smallSet[1], 40);
        _check();
        assertEq(validators.getValidators().length, 1);
        address first = smallSet[0] < smallSet[1] ? smallSet[0] : smallSet[1];
        assertFalse(validators.isCurrentValidator(first));
    }

    function testAutomaticMaintenanceRequiresEnabledMaintenance() public {
        _param(address(validators), "maxNumOfMaintaining", 0);
        _miss(members[0], 40);
        _check(); // BEP-127 semantics: zero disables maintenance, including automatic admission
        assertTrue(validators.isCurrentValidator(members[0]));
        _param(address(validators), "maxNumOfMaintaining", 3);
        _check();
        assertFalse(validators.isCurrentValidator(members[0]));
    }

    // Governance changes evaluate the recorded charged boundary against the new threshold.
    function testLoweredMisdemeanorThresholdChargesUncoveredBoundary() public {
        address validator = members[0];
        _param(address(validators), "maxNumOfMaintaining", 0);
        _miss(validator, 380); // charged at 200
        (, uint256 charged) = slash.getMaintenanceIndicator(validator);
        assertEq(charged, 200);
        _param(address(slash), "misdemeanorThreshold", 150);
        uint256 income = _deposit(validator);
        _miss(validator, 1); // 381/150 = 2 > 200/150 = 1: the 300 boundary was never charged
        assertEq(validators.getIncoming(validator), 0);
        income = _deposit(validator);
        _miss(validator, 68); // 449
        assertEq(validators.getIncoming(validator), income);
        _miss(validator, 1); // 450
        assertEq(validators.getIncoming(validator), 0);
    }

    function testLoweredMisdemeanorThresholdDuringMaintenanceChargesAtExit() public {
        address validator = members[0];
        _miss(validator, 180);
        vm.prank(validator);
        validators.enterMaintenance();
        _param(address(slash), "misdemeanorThreshold", 100);
        _deposit(validator);
        vm.prank(validator);
        validators.exitMaintenance(); // zero maintenance increment, total 180
        assertEq(_count(validator), 180);
        assertEq(validators.getIncoming(validator), 0);
    }

    function testRaisedMisdemeanorThresholdChargesUncoveredBoundary() public {
        address validator = members[0];
        _param(address(validators), "maxNumOfMaintaining", 0);
        _miss(validator, 380); // charged at 200
        _param(address(slash), "misdemeanorThreshold", 300);
        _deposit(validator);
        _miss(validator, 1); // 381/300 = 1 > 200/300 = 0
        assertEq(validators.getIncoming(validator), 0);
    }

    function testDecayKeepsChargedBoundaryBelowCount() public {
        address validator = members[0];
        _param(address(validators), "maxNumOfMaintaining", 0);
        _miss(validator, 399); // charged at 200
        vm.prank(address(validators));
        slash.clean();
        (uint256 count, uint256 charged) = slash.getMaintenanceIndicator(validator);
        assertEq(count, 249);
        assertEq(charged, 200); // not clamped: still below the decayed count
        uint256 income = _deposit(validator);
        _miss(validator, 150); // 399
        assertEq(validators.getIncoming(validator), income);
        _miss(validator, 1); // 400
        assertEq(validators.getIncoming(validator), 0);
    }

    function testCleanCompactsTrackingWithIndicators() public {
        _param(address(validators), "maxNumOfMaintaining", 0);
        _miss(members[0], 300); // survives: decays to 150, charged clamps 200 -> 150
        _miss(members[1], 50); // removed by the swap branch
        _miss(members[2], 250); // survives: decays to 100, charged clamps 200 -> 100
        _miss(members[3], 30); // removed by the pop branch
        vm.prank(address(validators));
        slash.clean();
        (uint256 count, uint256 charged) = slash.getMaintenanceIndicator(members[0]);
        assertEq(count, 150);
        assertEq(charged, 150);
        (count, charged) = slash.getMaintenanceIndicator(members[2]);
        assertEq(count, 100);
        assertEq(charged, 100);
        for (uint256 i = 1; i < 4; i += 2) {
            (, uint256 stored, bool exists) = slash.indicators(members[i]);
            assertEq(stored, 0);
            assertFalse(exists);
            (count, charged) = slash.getMaintenanceIndicator(members[i]);
            assertEq(count, 0);
            assertEq(charged, 0);
        }
        assertEq(slash.validators(0), members[0]);
        assertEq(slash.validators(1), members[2]);
        vm.expectRevert();
        slash.validators(2);
        _miss(members[1], 1); // a removed record restarts from scratch
        assertEq(_count(members[1]), 1);
    }

    function testForcedExitFelonyResetsCount() public {
        address validator = members[0];
        _miss(validator, 40);
        _check();
        _advanceMaintenance(validator, 560); // total 600
        uint64[] memory powers = new uint64[](members.length);
        bytes[] memory votes = new bytes[](members.length);
        for (uint256 i; i < members.length; ++i) {
            powers[i] = 1;
        }
        vm.prank(PRODUCER);
        validators.updateValidatorSetV2(members, powers, votes);
        assertFalse(validators.isCurrentValidator(validator));
        assertEq(_count(validator), 0);
    }
}
