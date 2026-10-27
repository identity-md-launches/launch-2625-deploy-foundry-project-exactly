// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Strength} from "../src/Strength.sol";

/// The share-of-pool strength curve: bounded, never falling as the trade grows or the pool shrinks, on the decided
/// points (+30% per tenfold share: 0% at 0.001%, 30% at 0.01%, 60% at 0.1%, 90% from 1%).
contract StrengthTest is Test {
    function s(uint256 paid, uint256 depth) internal pure returns (uint256) {
        return Strength.fromShare(paid, depth);
    }

    function test_decidedPoints() public pure {
        uint256 d = 1e24;
        assertEq(s(d / 100_000, d), 0, "0.001%");
        assertApproxEqAbs(s(d / 10_000, d), 3_000, 120, "0.01%");
        assertApproxEqAbs(s(d / 1_000, d), 6_000, 120, "0.1%");
        assertApproxEqAbs(s(d / 100, d), 9_000, 30, "1% (the fast log is a hair low there)");
        assertEq(s(d, d), 9_000, "all of it");
        assertEq(s(0, d), 0);
        assertEq(s(1, 0), 0, "no depth: no strength");
    }

    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_boundedAndMonotonic(uint128 paid, uint128 more, uint128 depth, uint128 less) public pure {
        uint256 a = s(paid, depth);
        assertLe(a, 9_000);
        assertGe(s(uint256(paid) + more, depth), a, "a bigger trade is never weaker");
        if (depth > 0) assertGe(s(paid, uint256(depth) - (less % depth)), a, "a shallower pool never makes it weaker");
    }

    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_tenfoldIsAboutThirtyPoints(uint64 paid, uint8 exp) public pure {
        vm.assume(paid > 1e6);
        uint256 depth = uint256(paid) * 10 ** (uint256(exp % 4) + 3); // shares 0.1% .. 0.0001%
        uint256 a = s(paid, depth * 10);
        uint256 b = s(paid, depth);
        if (b > 0 && a > 0 && b < 9_000) assertApproxEqAbs(b - a, 3_000, 150);
    }
}
