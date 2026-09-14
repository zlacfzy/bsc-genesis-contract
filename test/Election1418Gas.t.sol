pragma solidity ^0.8.10;

import "./utils/Deployer.sol";

// Empirically measures the gas of StakeHub.getValidatorElectionInfo(0,0) — the
// call Parlia makes every breathe block — as a function of validator count and
// per-validator description size. Validators are created in setUp so the read
// in the test runs against COLD storage, matching the real per-call eth_call.
contract Election1418Gas is Deployer {
    uint256 constant N = 6;      // registered validators
    uint256 constant B = 40000;  // 120KB per validator, 720KB total

    function setUp() public {
        vm.mockCall(address(0x66), bytes(""), hex"01");
        for (uint256 i; i < N; ++i) {
            _bigValidator(i, B);
        }
    }

    function _bigValidator(uint256 seed, uint256 b) internal {
        address op = address(uint160(0x100000 + seed));
        vm.deal(op, 3000 ether);
        StakeHub.Commission memory c = StakeHub.Commission({ rate: 10, maxRate: 100, maxChangeRate: 5 });
        StakeHub.Description memory d = StakeHub.Description({
            moniker: string.concat("Val", vm.toString(seed)),
            identity: string(new bytes(b)),
            website: string(new bytes(b)),
            details: string(new bytes(b))
        });
        bytes memory vote = bytes.concat(
            hex"00000000000000000000000000000000000000000000000000000000", abi.encodePacked(op)
        );
        bytes memory proof = new bytes(96);
        address cons = address(uint160(uint256(keccak256(vote))));
        vm.prank(op);
        stakeHub.createValidator{ value: 2001 ether }(cons, vote, proof, c, d);
    }

    function testMeasureElectionGas() public {
        uint256 g0 = gasleft();
        stakeHub.getValidatorElectionInfo(0, 0);
        uint256 used = g0 - gasleft();
        emit log_named_uint("validators                 ", N);
        emit log_named_uint("bytes per free field       ", B);
        emit log_named_uint("total free-form bytes      ", N * 3 * B);
        emit log_named_uint("ELECTION READ GAS          ", used);
        emit log_named_uint("gas per validator          ", used / N);
        emit log_named_uint("gas per free-form byte(x1e3)", (used * 1000) / (N * 3 * B));
    }
}
