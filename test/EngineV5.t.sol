// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Rules} from "../src/Rules.sol";
import {ChessEngineV5} from "../src/ChessEngineV5.sol";
import {Bitboard} from "../src/Bitboard.sol";
import {Chess} from "../src/Chess.sol";
import {Chessboard} from "./Chessboard.sol";

contract MateFinder {
    function mateInOne(uint256 b, uint32 w, uint32 k, bool white) external pure returns (uint16) {
        return Bitboard.mateInOne(Bitboard.fromBoard(b, w, k), white);
    }
}

contract EngineV5Test is Chessboard {
    ChessEngineV5 v5 = new ChessEngineV5();
    MateFinder finder = new MateFinder();

    /// Every choice on positions from the test games is a legal move and play() applies it as the rules do; mate in one is always taken; gas per choice.
    function test_legalChoicesMatesAndGas() public {
        uint64[8] memory none;
        uint256 positions;
        uint256 total;
        uint256 max;
        uint256 mates;
        for (uint256 game; game < 40; game++) {
            uint256[] memory mv = gameMoves(game);
            (uint256 b, uint32 w, uint32 k) = (Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK);
            for (uint256 i; i < mv.length && i < 100; i++) {
                bool black = i % 2 == 1;
                (uint32 mover, uint32 other) = black ? (k, w) : (w, k);
                // every 4th position at full accuracy, where a mate in one must always be taken
                uint256 acc = i % 4 == 0 ? 10_000 : (game * 7919 + i * 104_729) % 10_001;
                uint256 g0 = gasleft();
                (uint16 m, uint256 legal) =
                    v5.choose(b, mover, other, black, acc, uint256(keccak256(abi.encode(game, i))), none, uint32(game), 0);
                uint256 used = g0 - gasleft();
                assertGt(legal, 0);
                Rules.Played memory p = rules.move(b, mover, other, black, m); // reverts if illegal
                // play() skips the legality check for its own choice: it must agree with the checked move
                (uint16 played, Rules.Played memory q) =
                    v5.play(b, mover, other, black, acc, uint256(keccak256(abi.encode(game, i))), none, uint32(game), 0);
                assertEq(played, m);
                assertEq(abi.encode(q), abi.encode(p), "play() equals the checked move");
                if (acc == 10_000 && finder.mateInOne(b, w, k, !black) != 0) {
                    mates++;
                    assertEq(p.status, 2, "mate in one taken at full accuracy");
                }
                total += used;
                if (used > max) max = used;
                positions++;
                (b, w, k,) = step(b, w, k, black, uint16(mv[i]));
            }
        }
        emit log_named_uint("positions", positions);
        emit log_named_uint("mates in one taken at full accuracy", mates);
        emit log_named_uint("average gas per choice", total / positions);
        emit log_named_uint("max gas per choice", max);
        emit log_named_uint("runtime bytes", address(v5).code.length);
    }
}
