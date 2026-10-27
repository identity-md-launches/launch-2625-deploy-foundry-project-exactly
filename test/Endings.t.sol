// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Rules} from "../src/Rules.sol";
import {Bitboard} from "../src/Bitboard.sol";
import {Chess} from "../src/Chess.sol";
import {Chessboard} from "./Chessboard.sol";

contract BBStatus {
    function info(uint256 b, uint32 w, uint32 k, bool white)
        external
        pure
        returns (uint256 legal, bool check, uint8 status)
    {
        Bitboard.Pos memory p = Bitboard.fromBoard(b, w, k);
        legal = Bitboard.legalMoves(p, white).length;
        check = Bitboard.inCheck(p, white);
        bool any = Bitboard.hasLegalMove(p, white);
        assert(any == (legal != 0));
        status = any ? 0 : check ? 2 : 1;
    }
}

/// Games played to the end by chess.js (test/data/endings.json, scripts/gen-endings.mjs): at every position the
/// bitboard core must agree with chess.js on the legal move count, check, and checkmate / stalemate, and the hook's
/// rules must report the same ending for the final move.
contract EndingsTest is Chessboard {
    function test_statusAgainstChessJs() public {
        BBStatus bb = new BBStatus();
        string memory data = vm.readFile("./test/data/endings.json");
        uint256[] memory ends = vm.parseJsonUintArray(data, ".end");
        uint256[4] memory wrong; // bitboard: count, check, status; the hook's rules: final status
        uint256 positions;
        uint256[3] memory finals;
        for (uint256 g; g < ends.length; g++) {
            string memory key = vm.toString(g);
            uint256[] memory moves = vm.parseJsonUintArray(data, string.concat(".moves[", key, "]"));
            uint256[] memory counts = vm.parseJsonUintArray(data, string.concat(".counts[", key, "]"));
            uint256[] memory checks = vm.parseJsonUintArray(data, string.concat(".checks[", key, "]"));
            uint256 end = ends[g] == 1 || ends[g] == 2 ? ends[g] : 0; // 1 stalemate, 2 checkmate
            (uint256 b, uint32 w, uint32 k) = (Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK);
            for (uint256 i; i < counts.length; i++) {
                bool black = i % 2 == 1;
                bool last = i == moves.length;
                (uint256 legal, bool check, uint8 status) = bb.info(b, w, k, !black);
                if (legal != counts[i]) wrong[0]++;
                if (check != (checks[i] == 1)) wrong[1]++;
                if (status != (last ? end : 0)) wrong[2]++;
                positions++;
                if (last) {
                    if (end != 0) finals[end]++;
                    break;
                }
                Rules.Played memory p;
                (b, w, k, p) = step(b, w, k, black, uint16(moves[i]));
                if (i + 1 == moves.length && p.status != end) wrong[3]++;
            }
        }
        emit log_named_uint("games", ends.length);
        emit log_named_uint("positions", positions);
        emit log_named_uint("checkmates", finals[2]);
        emit log_named_uint("stalemates", finals[1]);
        assertEq(wrong[0], 0, "bitboard legal move count");
        assertEq(wrong[1], 0, "bitboard check");
        assertEq(wrong[2], 0, "bitboard checkmate / stalemate");
        assertEq(wrong[3], 0, "the hook's rules: checkmate / stalemate");
    }
}
