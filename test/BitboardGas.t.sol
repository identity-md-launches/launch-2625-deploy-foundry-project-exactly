// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Bitboard} from "../src/Bitboard.sol";
import {Chess} from "../src/Chess.sol";
import {Chessboard} from "./Chessboard.sol";

contract BBGas {
    using Bitboard for Bitboard.Pos;

    /// Legal moves plus, for each, whether it gives check and whether it mates (what v4 spends ~557k gas on).
    function legalChecksMates(uint256 b, uint32 w, uint32 k, bool white) external pure returns (uint256 checks, uint256 mates) {
        Bitboard.Pos memory p = Bitboard.fromBoard(b, w, k);
        uint16[] memory ms = Bitboard.legalMoves(p, white);
        Bitboard.Pos memory n;
        Bitboard.Checks memory c = Bitboard.checkInfo(p, white);
        for (uint256 i; i < ms.length; i++) {
            if (Bitboard.givesCheckWith(p, c, n, ms[i], white)) {
                Bitboard.makeMoveInto(p, n, ms[i], white);
                checks++;
                if (!Bitboard.hasLegalMove(n, !white)) mates++;
            }
        }
    }

    function mateInOne(uint256 b, uint32 w, uint32 k, bool white) external pure returns (uint16) {
        return Bitboard.mateInOne(Bitboard.fromBoard(b, w, k), white);
    }

    function legalOnly(uint256 b, uint32 w, uint32 k, bool white) external pure returns (uint256) {
        return Bitboard.legalMoves(Bitboard.fromBoard(b, w, k), white).length;
    }

    function maps(uint256 b, uint32 w, uint32 k) external pure returns (uint256, uint256) {
        Bitboard.Pos memory p = Bitboard.fromBoard(b, w, k);
        return (Bitboard.attackCounts(p, true), Bitboard.attackCounts(p, false));
    }
}

contract BitboardGasTest is Chessboard {
    function test_costs() public {
        BBGas g = new BBGas();
        uint256[4] memory t;
        uint256 n;
        for (uint256 game; game < 4; game++) {
            uint256[] memory moves = gameMoves(game);
            (uint256 b, uint32 w, uint32 k) = (Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK);
            for (uint256 i; i < moves.length && i < 60; i++) {
                bool black = i % 2 == 1;
                if (i % 5 == 0) {
                    n++;
                    uint256 g0 = gasleft();
                    g.legalOnly(b, w, k, !black);
                    t[0] += g0 - gasleft();
                    g0 = gasleft();
                    g.legalChecksMates(b, w, k, !black);
                    t[1] += g0 - gasleft();
                    g0 = gasleft();
                    g.maps(b, w, k);
                    t[2] += g0 - gasleft();
                    g0 = gasleft();
                    g.mateInOne(b, w, k, !black);
                    t[3] += g0 - gasleft();
                }
                (b, w, k,) = step(b, w, k, black, uint16(moves[i]));
            }
        }
        emit log_named_uint("legal moves (bitboards)", t[0] / n);
        emit log_named_uint("legal moves + check + mate tests (bitboards)", t[1] / n);
        emit log_named_uint("attack count maps, both sides", t[2] / n);
        emit log_named_uint("mate in one search", t[3] / n);
    }
}
