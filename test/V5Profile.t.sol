// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ChessEngineV5} from "../src/ChessEngineV5.sol";
import {Bitboard} from "../src/Bitboard.sol";
import {Chess} from "../src/Chess.sol";
import {Chessboard} from "./Chessboard.sol";

/// Exposes v5's stages so their cost can be measured separately.
contract V5Probe is ChessEngineV5 {
    function isConversion(uint256 b, uint32 w, uint32 k, bool white) external pure returns (bool) {
        return _context(b, w, k, white, true).conversion;
    }

    function legalCount(uint256 b, uint32 w, uint32 k, bool white) external pure returns (uint256) {
        return Bitboard.legalMoves(Bitboard.fromBoard(b, w, k), white).length;
    }

    function stageContext(uint256 b, uint32 w, uint32 k, bool white) external pure returns (uint256) {
        return _context(b, w, k, white, true).own;
    }

    function stageLegal(uint256 b, uint32 w, uint32 k, bool white) external pure returns (uint256) {
        Ctx memory c = _context(b, w, k, white, true);
        return Bitboard.legalMoves(c.p, white).length;
    }

    function stageCheap(uint256 b, uint32 w, uint32 k, bool white) external pure returns (int256 s) {
        Ctx memory c = _context(b, w, k, white, true);
        _effort(c, 10_000, 0);
        uint16[] memory moves = Bitboard.legalMoves(c.p, white);
        for (uint256 i; i < moves.length; i++) {
            (int256 base, int256 threat,, bool mate,) = _cheap(c, moves[i]);
            if (mate) return MATE;
            s += base - threat;
        }
    }

    function part(uint256 b, uint32 w, uint32 k, bool white, uint256 which) external pure returns (int256 s) {
        Ctx memory c = _context(b, w, k, white, true);
        uint16[] memory moves = Bitboard.legalMoves(c.p, white);
        for (uint256 i; i < moves.length; i++) {
            uint16 m = moves[i];
            uint8 from = uint8(m >> 6);
            uint8 to = uint8(m & 63);
            uint8 t = uint8(c.board >> (uint256(from) << 2)) & 7;
            if (which == 1) s += _gain(c, from, to, t, uint8(c.board >> (uint256(to) << 2)) & 7, false, false);
            else if (which == 2) s += Bitboard.givesCheckAs(c.p, c.checks, c.n, m, white, t) ? int256(1) : int256(0);
            else if (which == 3) s += _zoneHits(c, t, to) - _zoneHits(c, t, from);
            else if (which == 4) s += _loss(c.enemy, _value(t), uint64(1) << to, c.our2 & (uint64(1) << to) != 0);
            else if (which == 5) s += int256(_mix(12345, m) % 251);
        }
    }

    function stageExactOnce(uint256 b, uint32 w, uint32 k, bool white) external pure returns (int256) {
        Ctx memory c = _context(b, w, k, white, true);
        _effort(c, 10_000, 0);
        uint16[] memory moves = Bitboard.legalMoves(c.p, white);
        return _exact(c, moves[0], 0);
    }
}

contract V5ProfileTest is Chessboard {
    function test_stages() public {
        V5Probe v = new V5Probe();
        uint64[8] memory none;
        uint256[11] memory t;
        uint256 n;
        for (uint256 game; game < 8; game++) {
            uint256[] memory moves = gameMoves(game);
            (uint256 b, uint32 w, uint32 k) = (Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK);
            for (uint256 i; i < moves.length && i < 80; i++) {
                bool black = i % 2 == 1;
                (uint32 mover, uint32 other) = black ? (k, w) : (w, k);
                // These stages profile the general path. Conversion has its own measurements/tests.
                if (i % 3 == 0 && v.legalCount(b, w, k, !black) != 0 && !v.isConversion(b, w, k, !black)) {
                    n++;
                    uint256 g0 = gasleft();
                    v.stageContext(b, w, k, !black);
                    t[0] += g0 - gasleft();
                    g0 = gasleft();
                    v.stageLegal(b, w, k, !black);
                    t[1] += g0 - gasleft();
                    g0 = gasleft();
                    v.stageCheap(b, w, k, !black);
                    t[2] += g0 - gasleft();
                    g0 = gasleft();
                    v.stageExactOnce(b, w, k, !black);
                    t[3] += g0 - gasleft();
                    g0 = gasleft();
                    v.choose(b, mover, other, black, 5000, i, none, 0, 0);
                    t[4] += g0 - gasleft();
                    for (uint256 which; which <= 5; which++) {
                        g0 = gasleft();
                        v.part(b, w, k, !black, which);
                        t[5 + which] += g0 - gasleft();
                    }
                }
                (b, w, k,) = step(b, w, k, black, uint16(moves[i]));
            }
        }
        emit log_named_uint("positions", n);
        emit log_named_uint("context", t[0] / n);
        emit log_named_uint("context + legal moves", t[1] / n);
        emit log_named_uint("context + legal + cheap pass", t[2] / n);
        emit log_named_uint("context + legal + one exact re-score", t[3] / n);
        emit log_named_uint("full choice at 50%", t[4] / n);
        emit log_named_uint("per position: loop only", t[5] / n);
        emit log_named_uint("per position: gain", (t[6] - t[5]) / n);
        emit log_named_uint("per position: check test", (t[7] - t[5]) / n);
        emit log_named_uint("per position: zone pressure", (t[8] - t[5]) / n);
        emit log_named_uint("per position: threat", (t[9] - t[5]) / n);
        emit log_named_uint("per position: noise", (t[10] - t[5]) / n);
    }
}
