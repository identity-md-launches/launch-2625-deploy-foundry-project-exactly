// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Bitboard} from "../src/Bitboard.sol";
import {Chessboard} from "./Chessboard.sol";
import {Chess} from "../src/Chess.sol";

contract BB {
    function legal(uint256 b, uint32 w, uint32 k, bool white) external pure returns (uint16[] memory) {
        return Bitboard.legalMoves(Bitboard.fromBoard(b, w, k), white);
    }

    function inCheck(uint256 b, uint32 w, uint32 k, bool white) external pure returns (bool) {
        return Bitboard.inCheck(Bitboard.fromBoard(b, w, k), white);
    }

    function hasMove(uint256 b, uint32 w, uint32 k, bool white) external pure returns (bool) {
        return Bitboard.hasLegalMove(Bitboard.fromBoard(b, w, k), white);
    }

    function givesCheck(uint256 b, uint32 w, uint32 k, uint16 m, bool white) external pure returns (bool fast, bool full) {
        Bitboard.Pos memory p = Bitboard.fromBoard(b, w, k);
        Bitboard.Pos memory s;
        fast = Bitboard.givesCheck(p, s, m, white);
        full = Bitboard.inCheck(Bitboard.makeMove(p, m, white), !white);
    }

    /// Mate in one by the fast search, and by trying every legal move in full.
    function mates(uint256 b, uint32 w, uint32 k, bool white) external pure returns (bool fast, bool full) {
        Bitboard.Pos memory p = Bitboard.fromBoard(b, w, k);
        fast = Bitboard.mateInOne(p, white) != 0;
        uint16[] memory ms = Bitboard.legalMoves(p, white);
        for (uint256 i; i < ms.length && !full; i++) {
            Bitboard.Pos memory n = Bitboard.makeMove(p, ms[i], white);
            full = Bitboard.inCheck(n, !white) && !Bitboard.hasLegalMove(n, !white);
        }
    }

    /// The board after `m` edited in place (boardAfter) against the board rebuilt from the moved position.
    function boardAfter(uint256 b, uint32 w, uint32 k, uint16 m, bool white) external pure returns (bool same) {
        Bitboard.Pos memory p = Bitboard.fromBoard(b, w, k);
        same = Bitboard.boardAfter(b, p, m, white) == Bitboard.toBoard(Bitboard.makeMove(p, m, white));
    }

    function lsb(uint64 x) external pure returns (uint8) {
        return Bitboard.lsb(x);
    }
}

/// The bitboard core against chess.js (legal move sets, check, mate/stalemate) on 2,689 positions from the test
/// games, and its fast check and mate-in-one tests against playing every move out. (Boards and side states after
/// every legal move were cross-checked against the ChessFish verifier.)
contract BitboardTest is Chessboard {
    BB bb = new BB();
    string data;
    uint256[] games;
    uint256[] plies;
    uint256[] checks;
    uint256[] statuses;
    uint256 p;
    uint256 movesChecked;
    uint256 setMismatch;
    uint256 checkMismatch;
    uint256 statusMismatch;
    uint256 checkFlagMismatch;
    uint256 mateMismatch;
    uint256 boardMismatch;
    uint256 matesFound;

    function setUp() public {
        data = vm.readFile("./test/data/legal.json");
        games = vm.parseJsonUintArray(data, ".game");
        plies = vm.parseJsonUintArray(data, ".ply");
        checks = vm.parseJsonUintArray(data, ".inCheck");
        statuses = vm.parseJsonUintArray(data, ".status");
    }

    function test_lsb() public view {
        for (uint8 i; i < 64; i++) assertEq(bb.lsb(uint64(1) << i), i);
        assertEq(bb.lsb(0x8000000000000100), 8);
    }

    function _check(uint256 b, uint32 w, uint32 k, bool black) internal {
        bool white = !black;
        uint256[] memory want = vm.parseJsonUintArray(data, string.concat(".legal[", vm.toString(p), "]"));
        uint16[] memory got = bb.legal(b, w, k, white);
        bool same = got.length == want.length;
        for (uint256 i; same && i < got.length; i++) if (got[i] != want[i]) same = false;
        if (!same) {
            setMismatch++;
            emit log_named_string("legal set differs", string.concat("game ", vm.toString(games[p]), " ply ", vm.toString(plies[p]), " got ", vm.toString(got.length), " want ", vm.toString(want.length)));
        }
        if (bb.inCheck(b, w, k, white) != (checks[p] == 1)) checkMismatch++;
        uint256 status = bb.hasMove(b, w, k, white) ? 0 : (bb.inCheck(b, w, k, white) ? 2 : 1);
        if (status != statuses[p]) statusMismatch++;
        (bool fastMate, bool fullMate) = bb.mates(b, w, k, white);
        if (fastMate != fullMate) mateMismatch++;
        if (fullMate) matesFound++;
        for (uint256 i; i < got.length; i++) {
            (bool fast, bool full) = bb.givesCheck(b, w, k, got[i], white);
            if (fast != full) checkFlagMismatch++;
            if (!bb.boardAfter(b, w, k, got[i], white)) boardMismatch++;
            movesChecked++;
        }
    }

    function test_againstChessJs() public {
        uint256 lastGame = type(uint256).max;
        uint256[] memory moves;
        uint256 b;
        uint32 w;
        uint32 k;
        uint256 ply;
        for (p = 0; p < games.length; p++) {
            if (games[p] != lastGame) {
                lastGame = games[p];
                moves = gameMoves(lastGame);
                (b, w, k) = replay(lastGame, 0);
                ply = 0;
            }
            for (; ply < plies[p]; ply++) (b, w, k,) = step(b, w, k, ply % 2 == 1, uint16(moves[ply]));
            _check(b, w, k, ply % 2 == 1);
        }
        emit log_named_uint("positions", games.length);
        emit log_named_uint("moves applied and compared", movesChecked);
        assertEq(setMismatch, 0, "legal move sets");
        assertEq(checkMismatch, 0, "in check");
        assertEq(statusMismatch, 0, "mate / stalemate");
        assertEq(checkFlagMismatch, 0, "gives check");
        assertEq(boardMismatch, 0, "board after a move, edited in place");
        emit log_named_uint("positions with a mate in one", matesFound);
        assertEq(mateMismatch, 0, "mate in one");
    }
}

/// A rook taken on its home square takes its castling right with it: another rook later standing there doesn't give
/// it back (lines from chess.js, where the castle is illegal at the end; self-audit 2026-10-22).
contract CastlingRightsTest is Chessboard {
    BB bb = new BB();

    function castles(uint16[17] memory line, uint256 plies, uint16 castle) internal returns (bool found) {
        (uint256 b, uint32 w, uint32 k) = (Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK);
        for (uint256 i; i < plies; i++) (b, w, k,) = step(b, w, k, i % 2 == 1, line[i]); // reverts if illegal
        uint16[] memory moves = bb.legal(b, w, k, plies % 2 == 0);
        for (uint256 i; i < moves.length; i++) if (moves[i] == castle) found = true;
    }

    function test_aCapturedRookTakesItsCastlingRight() public {
        // 1. g4 b6 2. Bh3 Bb7 3. a4 Bxh1 4. Ra3 Bb7 5. Rg3 e6 6. Nf3 d6 7. Rg1 a6 8. Rh1 c6: no O-O for White
        uint16[17] memory white = [uint16(926), 3177, 343, 3761, 536, 3143, 16, 497, 1046, 3372, 405, 3307, 1414, 3112,
            391, 3242, 0];
        assertFalse(castles(white, 16, 4 << 6 | 6), "White O-O");
        // the same for Black: its h8 rook taken by Bxh8, a rook back on h8: no O-O for Black
        uint16[17] memory black = [uint16(80), 3494, 593, 3951, 137, 3104, 639, 3624, 4041, 2606, 788, 4013, 723, 3006,
            983, 4031, 658];
        assertFalse(castles(black, 17, 60 << 6 | 62), "Black O-O");
    }
}
