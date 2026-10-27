// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Chessboard} from "./Chessboard.sol";
import {Chess} from "../src/Chess.sol";
import {Rules} from "../src/Rules.sol";
import {ChessEngineV5} from "../src/ChessEngineV5.sol";

/// Development regressions, not held-out evidence: v5 against a lone king: the v4 conversion cases (four basic endings, sixteen sampled positions and their colour
/// mirrors), the defending king at full effort. Mate within 60 half-moves, no stalemate, no hung piece. v5 is deployed
/// from its own build (200 optimizer runs, foundry.toml).
contract EngineV5ConversionTest is Chessboard {
    ChessEngineV5 v5 = new ChessEngineV5();
    uint256 choices;
    uint256 gasTotal;
    uint256 gasMax;
    uint256 pliesTotal;
    uint256 cases;
    uint256 lastPlies;

    function test_queenDoesNotTrapItsKingOnBackRank() public {
        assertTrue(play(put(put(put(0, "h3", 6), "b5", 5), "c2", 14), side("h3"), side("c2"), 102, false, 40));
    }

    function test_rookKingApproachesDiagonallyInsteadOfRetreating() public {
        assertTrue(play(put(put(put(0, "h4", 6), "g6", 4), "h8", 14), side("h4"), side("h8"),
            0x21ec0a5 + 63, false, 40));
    }

    function test_bareKingConversion() public {
        for (uint256 i; i < 4; i++) {
            uint256 b = put(put(put(0, i % 2 == 0 ? "a1" : "d3", 6), i < 2 ? "b3" : "a4", i % 2 == 0 ? 5 : 4), "h8", 14);
            convert(b, side(i % 2 == 0 ? "a1" : "d3"), side("h8"), i, false);
        }
        report();
    }

    function test_conversionRegressionAndBlackSymmetry() public {
        string memory data = vm.readFile("./test/data/conversion.json");
        for (uint256 i; i < 16; i++) {
            string memory key = string.concat(".[", vm.toString(i), "]");
            uint256 b = uint256(vm.parseJsonBytes32(data, string.concat(key, ".board")));
            uint32 w = uint32(vm.parseJsonUint(data, string.concat(key, ".white")));
            uint32 k = uint32(vm.parseJsonUint(data, string.concat(key, ".black")));
            convert(b, w, k, i + 100, false);
            (uint256 mb, uint32 mw, uint32 mk) = mirror(b, w, k);
            convert(mb, mw, mk, i + 200, true);
        }
        report();
    }

    function test_generatedConversionValidation() public {
        string memory data = vm.readFile("./test/data/conversion-validation.json");
        uint256 in40;
        uint256 in60;
        for (uint256 i; i < 128; i++) {
            string memory key = string.concat(".[", vm.toString(i), "]");
            uint256 b = uint256(vm.parseJsonBytes32(data, string.concat(key, ".board")));
            uint32 w = uint32(vm.parseJsonUint(data, string.concat(key, ".white")));
            uint32 k = uint32(vm.parseJsonUint(data, string.concat(key, ".black")));
            for (uint256 colour; colour < 2; colour++) {
                (uint256 cb, uint32 cw, uint32 ck) = (b, w, k);
                if (colour == 1) (cb, cw, ck) = mirror(b, w, k);
                assertTrue(play(cb, cw, ck, 0x21ec0a5 + i, colour == 1, Chess.MAX_QUIET_PLY),
                    string.concat("generated conversion stalled, case/colour ", vm.toString(i * 2 + colour)));
                in60++;
                if (lastPlies <= 40) in40++;
            }
        }
        emit log_named_uint("generated corpus: mates within 40 of 256", in40);
        emit log_named_uint("generated corpus: mates within 60 of 256", in60);
        assertGe(in40 * 10_000 / 256, 9800, "at least 98% within 40 half-moves");
        report();
    }

    function report() internal {
        emit log_named_uint("cases", cases);
        emit log_named_uint("average half-moves to mate", pliesTotal / cases);
        emit log_named_uint("converting side: gas avg", gasTotal / choices);
        emit log_named_uint("converting side: gas max", gasMax);
    }

    function convert(uint256 b, uint32 w, uint32 k, uint256 seed, bool winningBlack) internal {
        assertTrue(play(b, w, k, seed, winningBlack, Chess.MAX_QUIET_PLY), string.concat("must convert the bare-king ending, case ",
            vm.toString(seed)));
    }

    /// Plays it out; true if the winning side mates within `limit` half-moves (stalemate or a hung piece fails).
    function play(uint256 b, uint32 w, uint32 k, uint256 seed, bool winningBlack, uint256 limit)
        internal
        returns (bool mated)
    {
        uint64[16] memory history;
        for (uint256 ply; ply < limit; ply++) {
            bool black = (ply % 2 == 1) != winningBlack;
            (uint32 mover, uint32 other) = black ? (k, w) : (w, k);
            uint64[8] memory previous;
            for (uint256 i; i < 8; i++) previous[i] = history[(ply + 14 - i * 2) % 16];
            uint256 g0 = gasleft();
            // the winning side at a beginner's accuracy: against a lone king it converts at full effort anyway
            (uint16 m,) = v5.choose(b, mover, other, black, black == winningBlack ? 3333 : 10000, ply + seed,
                previous, 0, uint16(ply));
            uint256 used = g0 - gasleft();
            if (black == winningBlack) {
                choices++;
                gasTotal += used;
                if (used > gasMax) gasMax = used;
            }
            Rules.Played memory p = rules.move(b, mover, other, black, m);
            b = p.board;
            (w, k) = black ? (p.other, p.mover) : (p.mover, p.other);
            uint64 key = Chess.positionKey(b, w, k, !black, 0);
            if (p.status == 2) {
                assertEq(black, winningBlack);
                mated = true;
                lastPlies = ply + 1;
                pliesTotal += lastPlies;
                cases++;
                break;
            }
            assertEq(p.status, 0, "must not stalemate");
            assertFalse(p.insufficient, "must not lose mating material");
            uint256 repeats;
            for (uint256 i; i < 16; i++) if (history[i] == key) repeats++;
            assertLt(repeats, 2, "must not draw by repetition");
            history[ply % 16] = key;
        }
    }

    /// Every case, both colours, eight seeds each, within the hook's quiet rule (Chess.MAX_QUIET_PLY half-moves
    /// without a capture or pawn move: the material just changed, so the count starts at zero), with no third
    /// repetition, stalemate or lost mating material. How many also mate within 40 is reported.
    function test_conversionSweep() public {
        string memory data = vm.readFile("./test/data/conversion.json");
        uint256 runs;
        uint256 ok;
        for (uint256 seed; seed < 8; seed++) {
            for (uint256 i; i < 20; i++) {
                uint256 b;
                uint32 w;
                uint32 k;
                if (i < 4) {
                    b = put(put(put(0, i % 2 == 0 ? "a1" : "d3", 6), i < 2 ? "b3" : "a4", i % 2 == 0 ? 5 : 4), "h8", 14);
                    (w, k) = (side(i % 2 == 0 ? "a1" : "d3"), side("h8"));
                } else {
                    string memory key = string.concat(".[", vm.toString(i - 4), "]");
                    b = uint256(vm.parseJsonBytes32(data, string.concat(key, ".board")));
                    w = uint32(vm.parseJsonUint(data, string.concat(key, ".white")));
                    k = uint32(vm.parseJsonUint(data, string.concat(key, ".black")));
                }
                for (uint256 colour; colour < 2; colour++) {
                    runs++;
                    bool won;
                    if (colour == 0) {
                        won = play(b, w, k, seed * 1000 + i, false, Chess.MAX_QUIET_PLY);
                    } else {
                        (uint256 mb, uint32 mw, uint32 mk) = mirror(b, w, k);
                        won = play(mb, mw, mk, seed * 1000 + i + 500, true, Chess.MAX_QUIET_PLY);
                    }
                    assertTrue(won, string.concat("conversion stalled, case/seed/colour ",
                        vm.toString(i), "/", vm.toString(seed), "/", vm.toString(colour)));
                    if (lastPlies <= 40) ok++;
                }
            }
        }
        emit log_named_string("converted within 40 half-moves", string.concat(vm.toString(ok), " of ", vm.toString(runs)));
        assertGe(ok * 10_000 / runs, 9900, "at least 99% within 40 half-moves");
        report();
        assertLt(gasTotal / choices, 300_000, "average conversion gas budget");
        assertLt(gasMax, 550_000, "sampled worst conversion gas budget");
    }
}
