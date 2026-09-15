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

    // Seed an indicator directly: SlashIndicator keeps `validators` at slot 1 and `indicators` at slot 2.
    function _seedIndicator(address validator, uint256 count) internal {
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

    function testCapacityIsCheckedAtTheThresholdMissOnly() public {
        for (uint256 i; i < 4; ++i) {
            _miss(members[i], 40);
        }
        for (uint256 i; i < 3; ++i) {
            assertFalse(validators.isCurrentValidator(members[i]));
        }
        assertTrue(validators.isCurrentValidator(members[3])); // capacity 3
        _exit(members[0]);
        _miss(members[3], 159); // no retry after the threshold miss, even with capacity free
        assertTrue(validators.isCurrentValidator(members[3]));
        assertEq(_count(members[3]), 199);
        _miss(members[3], 1); // the misdemeanor path at 200 remains the next automatic entry
        assertFalse(validators.isCurrentValidator(members[3]));
        _miss(members[0], 1); // once per day
        assertTrue(validators.isCurrentValidator(members[0]));
    }

    function testAutomaticMaintenanceRequiresEnabledMaintenance() public {
        _param(address(validators), "maxNumOfMaintaining", 0);
        _miss(members[0], 40);
        assertTrue(validators.isCurrentValidator(members[0])); // BEP-127: zero disables maintenance
        _param(address(validators), "maxNumOfMaintaining", 3);
        _miss(members[0], 1); // the threshold miss has passed; no retry
        assertTrue(validators.isCurrentValidator(members[0]));
        _miss(members[1], 40);
        assertFalse(validators.isCurrentValidator(members[1]));
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

    /*----------------- BEP-127 settlement is unchanged -----------------*/

    function testMaintenanceKeepsMissedBlockCount() public {
        address validator = members[0];
        uint256 income = _deposit(validator);
        _miss(validator, 40);
        _advanceMaintenance(validator, 199);
        _exit(validator); // 199 < 200: no penalty, the ordinary count is untouched
        assertEq(_count(validator), 40);
        assertEq(validators.getIncoming(validator), income);
        _miss(validator, 1);
        assertEq(_count(validator), 41);
    }

    function testMaintenanceMisdemeanorUsesMaintenanceCountOnly() public {
        address validator = members[0];
        _deposit(validator);
        _miss(validator, 40);
        _advanceMaintenance(validator, 200);
        _exit(validator);
        assertEq(validators.getIncoming(validator), 0);
        assertEq(_count(validator), 40);
    }

    function testMaintenanceFelonyUsesMaintenanceCountOnly() public {
        address validator = members[0];
        _miss(validator, 40);
        _advanceMaintenance(validator, 599);
        _exit(validator); // 40 + 599 would be a felony under a combined rule; 599 alone is not
        assertTrue(validators.isCurrentValidator(validator));
        assertEq(_count(validator), 40);
    }

    function testMaintenanceFelonyEvicts() public {
        address validator = members[0];
        _miss(validator, 40);
        _advanceMaintenance(validator, 600);
        _exit(validator);
        assertFalse(validators.isCurrentValidator(validator));
        vm.expectRevert("only current validators");
        validators.getCurrentValidatorIndex(validator);
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
        assertEq(_count(validator), 200);
        assertEq(validators.getIncoming(validator), income);
        _miss(validator, 1);
        assertEq(_count(validator), 201);
        assertEq(validators.getIncoming(validator), income);
    }

    function testForcedExitThenDecay() public {
        address validator = members[0];
        _deposit(validator);
        _miss(validator, 40);
        _advanceMaintenance(validator, 200);
        _forceDailyUpdate(); // forced exit charges the misdemeanor, then clean() drops the 40
        assertEq(validators.getIncoming(validator), 0);
        assertEq(_count(validator), 0);
        assertTrue(validators.isCurrentValidator(validator));
    }

    function testFelonyShiftKeepsSessionWithValidator() public {
        address maintaining = members[1];
        address felon = members[0];
        _deposit(maintaining);
        _miss(maintaining, 40); // session at index 1
        _param(address(validators), "maxNumOfMaintaining", 0);
        _miss(felon, 600); // felony removes index 0 and shifts the maintaining validator down
        assertFalse(validators.isCurrentValidator(felon));
        assertEq(validators.getCurrentValidatorIndex(maintaining), 0);
        _advanceMaintenance(maintaining, 200);
        _exit(maintaining);
        assertEq(validators.getIncoming(maintaining), 0); // settled against the shifted record
        assertEq(_count(maintaining), 40);
    }

    function testFuzzMaintenanceLeavesCountUnchanged(uint16 missing, uint16 equivalent) public {
        uint256 entry = bound(missing, 0, 39);
        uint256 elapsed = bound(equivalent, 0, 599);
        address validator = members[0];
        _miss(validator, entry);
        vm.prank(validator);
        validators.enterMaintenance();
        _advanceMaintenance(validator, elapsed);
        _exit(validator);
        assertEq(_count(validator), entry);
    }

    /*----------------- governance -----------------*/

    function testGovernanceBoundsAndAuthorization() public {
        assertEq(slash.maintenanceThreshold(), 40);
        vm.expectRevert("the message sender must be slash contract");
        validators.tryEnterMaintenance(members[0]);
        vm.expectRevert("the maintenanceThreshold out of range");
        _param(address(slash), "maintenanceThreshold", 0);
        vm.expectRevert("the maintenanceThreshold out of range");
        _param(address(slash), "maintenanceThreshold", 200);
        vm.expectRevert("the misdemeanorThreshold out of range");
        _param(address(slash), "misdemeanorThreshold", 40);
        _param(address(slash), "maintenanceThreshold", 41);
        assertEq(slash.maintenanceThreshold(), 41);
        _miss(members[0], 40);
        assertTrue(validators.isCurrentValidator(members[0]));
        _miss(members[0], 1);
        assertFalse(validators.isCurrentValidator(members[0]));
    }

    function testThresholdsAreReadAtExit() public {
        address validator = members[0];
        _param(address(slash), "felonyThreshold", 1000);
        _param(address(slash), "misdemeanorThreshold", 333);
        uint256 income = _deposit(validator);
        _miss(validator, 40);
        _advanceMaintenance(validator, 250);
        _param(address(slash), "misdemeanorThreshold", 200);
        _param(address(slash), "felonyThreshold", 600);
        _exit(validator); // 250 >= 200 under the thresholds in force at exit
        assertEq(validators.getIncoming(validator), 0);
        assertGt(income, 0);
        assertEq(_count(validator), 40);
    }

    function testLoweredFelonyThresholdWaitsForNextMultiple() public {
        address validator = members[0];
        _param(address(validators), "maxNumOfMaintaining", 0);
        _param(address(slash), "felonyThreshold", 1000);
        _miss(validator, 650);
        _param(address(slash), "felonyThreshold", 600);
        _miss(validator, 1); // 651: not retroactive, no felony
        assertTrue(validators.isCurrentValidator(validator));
        _miss(validator, 549); // 1200
        assertEq(_count(validator), 0);
        assertFalse(validators.isCurrentValidator(validator));
    }

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

    /*----------------- ordinary slashing is unchanged -----------------*/

    function testChargesFirstBoundaryOnce() public {
        address validator = members[0];
        _param(address(validators), "maxNumOfMaintaining", 0);
        _seedIndicator(validator, 199);
        _deposit(validator);
        _miss(validator, 1);
        assertEq(_count(validator), 200);
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
