// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Bitboard} from "./Bitboard.sol";

/// The rules the hook plays by, on the bitboard core: play a move and say how the game stands (encoding: Chess.sol).
/// Checked against chess.js on every position of test/data/legal.json and test/data/endings.json.
library Rules {
    struct Played {
        uint256 board;
        uint32 mover; // the mover's new state
        uint32 other; // the other side's new state
        bool check; // the side now to move is in check
        uint8 status; // 0 the game goes on, 1 stalemate, 2 checkmate
        bool insufficient; // only two kings and at most one knight or bishop are left
    }

    error Illegal();

    /// Plays `m` for the side to move (Black if `black`); reverts if it is illegal.
    function move(uint256 board, uint32 mover, uint32 other, bool black, uint16 m)
        internal
        pure
        returns (Played memory)
    {
        Bitboard.Pos memory p = Bitboard.fromBoard(board, black ? other : mover, black ? mover : other);
        if (!Bitboard.isLegal(p, m, !black)) revert Illegal();
        return playLegal(board, p, m, black);
    }

    /// Plays `m`, already known to be legal (taken from Bitboard.legalMoves of `p`, the position of `board`), and says
    /// how the game stands.
    function playLegal(uint256 board, Bitboard.Pos memory p, uint16 m, bool black) internal pure returns (Played memory r) {
        Bitboard.Pos memory n = Bitboard.makeMove(p, m, !black);
        r.board = Bitboard.boardAfter(board, p, m, !black);
        (r.mover, r.other) = black ? (n.blackState, n.whiteState) : (n.whiteState, n.blackState);
        bool any;
        (r.check, any) = Bitboard.status(n, black);
        r.status = any ? 0 : r.check ? 2 : 1;
        uint64 kings = n.pc[6];
        uint64 others = (n.white | n.black) & ~kings;
        r.insufficient = Bitboard.popcount(kings & n.white) == 1 && Bitboard.popcount(kings & n.black) == 1
            && (others == 0 || (others & (others - 1) == 0 && others & (n.pc[2] | n.pc[3]) != 0));
    }
}
