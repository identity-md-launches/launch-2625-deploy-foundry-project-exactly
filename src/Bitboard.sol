// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// Bitboard chess core: the rules the hook plays by (Rules.sol) and the engine's move search. Squares a1 = 0 .. h8 = 63
/// (north = +8). The packed board (64 x 4 bits: 1 pawn 2 bishop 3 knight 4 rook 5 queen 6 king, +8 black) and the
/// 32-bit side states (Chess.sol) are converted once; everything else is bit operations. Promotion is always to a
/// queen. Checked against chess.js (test/RulesRandom.t.sol, test/Bitboard.t.sol).
library Bitboard {
    uint64 internal constant FILE_A = 0x0101010101010101;
    uint64 internal constant FILE_H = 0x8080808080808080;
    uint64 internal constant NOT_A = ~FILE_A;
    uint64 internal constant NOT_H = ~FILE_H;
    uint64 internal constant NOT_AB = ~(FILE_A | (FILE_A << 1));
    uint64 internal constant NOT_GH = ~(FILE_H | (FILE_H >> 1));
    uint64 internal constant RANK_3 = 0x0000000000FF0000;
    uint64 internal constant RANK_6 = 0x0000FF0000000000;
    uint64 internal constant RANK_1 = 0x00000000000000FF;
    uint64 internal constant RANK_8 = 0xFF00000000000000;

    struct Pos {
        uint64[7] pc; // by piece type 1..6, both colours
        uint64 white;
        uint64 black;
        uint32 whiteState; // the verifier's side states (en passant byte, king, rook flags)
        uint32 blackState;
    }

    // ---------------------------------------------------------------- conversion

    uint256 internal constant NIBBLE_LOW = 0x1111111111111111111111111111111111111111111111111111111111111111;

    function fromBoard(uint256 board, uint32 whiteState, uint32 blackState) internal pure returns (Pos memory p) {
        p.whiteState = whiteState;
        p.blackState = blackState;
        uint256 types = board & (NIBBLE_LOW * 7);
        uint256 occupied = (board | (board >> 1) | (board >> 2)) & NIBBLE_LOW; // a piece has a type, 1..6
        uint256 black = (board >> 3) & occupied;
        for (uint256 t = 1; t <= 6; t++) {
            uint256 x = types ^ (NIBBLE_LOW * t); // zero in the nibbles holding type t
            p.pc[t] = _compress(~(x | (x >> 1) | (x >> 2)) & NIBBLE_LOW);
        }
        p.white = _compress(occupied & ~black);
        p.black = _compress(black);
    }

    /// Bit 4 * i of `x` becomes bit i (x has no other bits set).
    function _compress(uint256 x) private pure returns (uint64) {
        x = (x | (x >> 3)) & 0x0303030303030303030303030303030303030303030303030303030303030303;
        x = (x | (x >> 6)) & 0x000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f;
        x = (x | (x >> 12)) & 0x000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff;
        x = (x | (x >> 24)) & 0x000000000000ffff000000000000ffff000000000000ffff000000000000ffff;
        x = (x | (x >> 48)) & 0x000000000000000000000000ffffffff000000000000000000000000ffffffff;
        return uint64(x | (x >> 96));
    }

    // ---------------------------------------------------------------- bit helpers

    /// Index of the lowest set bit (b != 0), by de Bruijn multiplication.
    function lsb(uint64 b) internal pure returns (uint8 r) {
        assembly ("memory-safe") {
            let idx := shr(58, and(mul(and(b, sub(0, b)), 0x03f79d71b4cb0a89), 0xffffffffffffffff))
            switch lt(idx, 32)
            case 1 { r := byte(idx, 0x0001300239311c033d3a322a261d11043e373b2435332b162d27211e18120c05) }
            default { r := byte(sub(idx, 32), 0x3f2f381b3c292510362334152c20170b2e1a280f22141f0a190e13090d080706) }
        }
    }

    function popcount(uint64 b) internal pure returns (uint256 n) {
        assembly ("memory-safe") {
            let x := sub(b, and(shr(1, b), 0x5555555555555555))
            x := add(and(x, 0x3333333333333333), and(shr(2, x), 0x3333333333333333))
            x := and(add(x, shr(4, x)), 0x0f0f0f0f0f0f0f0f)
            n := shr(56, and(mul(x, 0x0101010101010101), 0xffffffffffffffff))
        }
    }

    // ---------------------------------------------------------------- attacks

    function knightAttacks(uint64 b) internal pure returns (uint64) {
        uint64 l1 = (b >> 1) & NOT_H;
        uint64 l2 = (b >> 2) & NOT_GH;
        uint64 r1 = (b << 1) & NOT_A;
        uint64 r2 = (b << 2) & NOT_AB;
        uint64 h1 = l1 | r1;
        uint64 h2 = l2 | r2;
        return (h1 << 16) | (h1 >> 16) | (h2 << 8) | (h2 >> 8);
    }

    function kingAttacks(uint64 b) internal pure returns (uint64) {
        uint64 side = ((b << 1) & NOT_A) | ((b >> 1) & NOT_H);
        uint64 row = b | side;
        return side | (row << 8) | (row >> 8);
    }

    function pawnAttacks(uint64 b, bool white) internal pure returns (uint64) {
        return white ? ((b << 7) & NOT_H) | ((b << 9) & NOT_A) : ((b >> 9) & NOT_H) | ((b >> 7) & NOT_A);
    }

    uint64 internal constant DIAG = 0x8040201008040201; // a1-h8
    uint64 internal constant ANTI = 0x0102040810204080; // h1-a8

    /// Full rook lines and bishop lines through `sq`, without `sq` itself.
    function rays(uint8 sq) internal pure returns (uint64 rook, uint64 bishop) {
        unchecked {
            uint64 bit = uint64(1) << sq;
            uint256 f = sq & 7;
            uint256 r = sq >> 3;
            rook = ((FILE_A << f) | (RANK_1 << (8 * r))) ^ bit;
            uint64 d = f >= r ? DIAG >> (8 * (f - r)) : DIAG << (8 * (r - f));
            uint64 a = f + r <= 7 ? ANTI >> (8 * (7 - f - r)) : ANTI << (8 * (f + r - 7));
            bishop = (d | a) ^ bit;
        }
    }

    /// Sliding attacks for every rook-mover in `g` (occluded fill, Kogge-Stone), the four directions in one block:
    /// north and south by 8, east (dropping wraps onto the a-file) and west (onto the h-file) by 1. Intermediate values
    /// stay within 64 bits because they are masked by `empty`; only each direction's last shift is cut.
    function rookAttacks(uint64 g, uint64 empty) internal pure returns (uint64 r) {
        assembly ("memory-safe") {
            let x := or(g, and(empty, shl(8, g)))
            let e := and(empty, shl(8, empty))
            x := or(x, and(e, shl(16, x)))
            e := and(e, shl(16, e))
            x := or(x, and(e, shl(32, x)))
            r := and(shl(8, x), 0xffffffffffffffff)
            x := or(g, and(empty, shr(8, g)))
            e := and(empty, shr(8, empty))
            x := or(x, and(e, shr(16, x)))
            e := and(e, shr(16, e))
            x := or(x, and(e, shr(32, x)))
            r := or(r, shr(8, x))
            let m := 0xfefefefefefefefe
            let em := and(empty, m)
            x := or(g, and(em, shl(1, g)))
            e := and(em, shl(1, em))
            x := or(x, and(e, shl(2, x)))
            e := and(e, shl(2, e))
            x := or(x, and(e, shl(4, x)))
            r := or(r, and(shl(1, x), m))
            m := 0x7f7f7f7f7f7f7f7f
            em := and(empty, m)
            x := or(g, and(em, shr(1, g)))
            e := and(em, shr(1, em))
            x := or(x, and(e, shr(2, x)))
            e := and(e, shr(2, e))
            x := or(x, and(e, shr(4, x)))
            r := or(r, and(shr(1, x), m))
        }
    }

    /// The four bishop directions in one block: north-east by 9 and south-east by 7 (dropping wraps onto the a-file),
    /// north-west by 7 and south-west by 9 (dropping wraps onto the h-file).
    function bishopAttacks(uint64 g, uint64 empty) internal pure returns (uint64 r) {
        assembly ("memory-safe") {
            let m := 0xfefefefefefefefe
            let em := and(empty, m)
            let x := or(g, and(em, shl(9, g)))
            let e := and(em, shl(9, em))
            x := or(x, and(e, shl(18, x)))
            e := and(e, shl(18, e))
            x := or(x, and(e, shl(36, x)))
            r := and(shl(9, x), m)
            x := or(g, and(em, shr(7, g)))
            e := and(em, shr(7, em))
            x := or(x, and(e, shr(14, x)))
            e := and(e, shr(14, e))
            x := or(x, and(e, shr(28, x)))
            r := or(r, and(shr(7, x), m))
            m := 0x7f7f7f7f7f7f7f7f
            em := and(empty, m)
            x := or(g, and(em, shl(7, g)))
            e := and(em, shl(7, em))
            x := or(x, and(e, shl(14, x)))
            e := and(e, shl(14, e))
            x := or(x, and(e, shl(28, x)))
            r := or(r, and(shl(7, x), m))
            x := or(g, and(em, shr(9, g)))
            e := and(em, shr(9, em))
            x := or(x, and(e, shr(18, x)))
            e := and(e, shr(18, e))
            x := or(x, and(e, shr(36, x)))
            r := or(r, and(shr(9, x), m))
        }
    }

    /// Every square attacked by `white`'s side (pawn diagonals, pieces, sliders up to and including the blocker).
    function attacksBy(Pos memory p, bool white) internal pure returns (uint64) {
        return attacksWith(p, white, ~(p.white | p.black));
    }

    /// The same with sliders running over `empty` (for example with the enemy king lifted off the board).
    function attacksWith(Pos memory p, bool white, uint64 empty) internal pure returns (uint64 a) {
        uint64 own = white ? p.white : p.black;
        a = pawnAttacks(p.pc[1] & own, white) | knightAttacks(p.pc[3] & own) | kingAttacks(p.pc[6] & own);
        a |= rookAttacks((p.pc[4] | p.pc[5]) & own, empty) | bishopAttacks((p.pc[2] | p.pc[5]) & own, empty);
    }

    /// Whether `sq` is attacked by `byWhite`'s side.
    function attacked(Pos memory p, uint8 sq, bool byWhite) internal pure returns (bool) {
        uint64 bit = uint64(1) << sq;
        uint64 them = byWhite ? p.white : p.black;
        uint64 empty = ~(p.white | p.black);
        if (pawnAttacks(bit, !byWhite) & p.pc[1] & them != 0) return true;
        if (knightAttacks(bit) & p.pc[3] & them != 0) return true;
        if (kingAttacks(bit) & p.pc[6] & them != 0) return true;
        (uint64 rr, uint64 br) = rays(sq);
        uint64 rq = (p.pc[4] | p.pc[5]) & them;
        if (rr & rq != 0 && rookAttacks(bit, empty) & rq != 0) return true;
        uint64 bq = (p.pc[2] | p.pc[5]) & them;
        return br & bq != 0 && bishopAttacks(bit, empty) & bq != 0;
    }

    /// Number of `white`'s pieces attacking each square, 4 bits per square (the format the strategy helper reads).
    function attackCounts(Pos memory p, bool white) internal pure returns (uint256 map) {
        uint64 own = white ? p.white : p.black;
        uint64 empty = ~(p.white | p.black);
        uint64 pieces = own;
        while (pieces != 0) {
            uint8 sq = lsb(pieces);
            pieces &= pieces - 1;
            uint64 bit = uint64(1) << sq;
            uint64 a = pieceAttacks(p, bit, empty, white);
            while (a != 0) {
                uint8 t = lsb(a);
                a &= a - 1;
                uint256 shift = uint256(t) << 2;
                if ((map >> shift) & 15 != 15) map += uint256(1) << shift;
            }
        }
    }

    function pieceAttacks(Pos memory p, uint64 bit, uint64 empty, bool white) internal pure returns (uint64) {
        if (p.pc[1] & bit != 0) return pawnAttacks(bit, white);
        if (p.pc[3] & bit != 0) return knightAttacks(bit);
        if (p.pc[6] & bit != 0) return kingAttacks(bit);
        uint64 a;
        if ((p.pc[4] | p.pc[5]) & bit != 0) a = rookAttacks(bit, empty);
        if ((p.pc[2] | p.pc[5]) & bit != 0) a |= bishopAttacks(bit, empty);
        return a;
    }

    /// The piece type on `sq` (0 if empty): each square is in at most one of the piece sets.
    function pieceAt(Pos memory p, uint8 sq) internal pure returns (uint8 t) {
        uint64[7] memory pc = p.pc;
        uint256 r = (uint256(pc[1]) >> sq & 1) | (uint256(pc[2]) >> sq & 1) << 1 | ((uint256(pc[3]) >> sq & 1) * 3)
            | (uint256(pc[4]) >> sq & 1) << 2 | ((uint256(pc[5]) >> sq & 1) * 5) | ((uint256(pc[6]) >> sq & 1) * 6);
        t = uint8(r);
    }

    // ---------------------------------------------------------------- moves

    /// The position after `move` (from << 6 | to): queen promotion, en passant capture, castling rook, and the side
    /// states (king and rook flags, the flag of a rook captured at home, the en passant byte).
    function makeMove(Pos memory p, uint16 move, bool white) internal pure returns (Pos memory n) {
        makeMoveInto(p, n, move, white);
    }

    /// Same as makeMove, but writes into `n` (a scratch position reused across trial moves, so memory doesn't grow).
    function makeMoveInto(Pos memory p, Pos memory n, uint16 move, bool white) internal pure {
        for (uint256 i = 1; i <= 6; i++) n.pc[i] = p.pc[i]; // copy values: `n.pc = p.pc` would alias the array
        n.white = p.white;
        n.black = p.black;
        uint8 from = uint8(move >> 6);
        uint8 to = uint8(move & 63);
        uint8 t = pieceAt(p, from);
        uint8 victim = pieceAt(p, to);
        if (victim != 0) _remove(n, uint64(1) << to, victim, !white);
        _shift(n, from, to, t, white);
        uint32 mover = white ? p.whiteState : p.blackState;
        if (t == 1) mover = _pawnExtras(p, n, from, to, victim == 0, white, mover);
        else if (t == 6) mover = _kingExtras(n, from, to, white, mover);
        else if (t == 4) {
            if (from == uint8(mover >> 16)) mover |= 0x00800000;
            else if (from == uint8(mover >> 24)) mover |= 0x80000000;
        }
        uint32 other = (white ? p.blackState : p.whiteState) | 0xff;
        if (victim != 0) {
            // a rook taken on its home square takes its castling right with it (a flagged byte never equals `to`)
            if (to == uint8(other >> 16)) other |= 0x00800000;
            else if (to == uint8(other >> 24)) other |= 0x80000000;
        }
        (n.whiteState, n.blackState) = white ? (mover, other) : (other, mover);
    }

    function _remove(Pos memory n, uint64 bit, uint8 t, bool ofWhite) private pure {
        n.pc[t] &= ~bit;
        if (ofWhite) n.white &= ~bit;
        else n.black &= ~bit;
    }

    function _shift(Pos memory n, uint8 from, uint8 to, uint8 t, bool white) private pure {
        uint64 fb = uint64(1) << from;
        uint64 tb = uint64(1) << to;
        n.pc[t] = (n.pc[t] & ~fb) | tb;
        if (white) n.white = (n.white & ~fb) | tb;
        else n.black = (n.black & ~fb) | tb;
    }

    /// En passant capture, queen promotion and the double-step en passant byte, as the verifier applies them.
    function _pawnExtras(Pos memory p, Pos memory n, uint8 from, uint8 to, bool quiet, bool white, uint32 mover)
        private
        pure
        returns (uint32)
    {
        uint32 other = white ? p.blackState : p.whiteState;
        if (quiet && to == uint8(other & 0xff) && (from & 7) != (to & 7)) {
            _remove(n, white ? (uint64(1) << to) >> 8 : (uint64(1) << to) << 8, 1, !white);
        }
        if (to >> 3 == 7 || to >> 3 == 0) {
            n.pc[1] &= ~(uint64(1) << to);
            n.pc[5] |= uint64(1) << to;
        }
        uint8 diff = to > from ? to - from : from - to;
        if (diff == 16) mover = (mover & ~uint32(0xff)) | uint32(to > from ? from + 8 : to + 8);
        return mover;
    }

    /// Castling moves the rook next to the king; any king move sets both rook flags and the king square.
    function _kingExtras(Pos memory n, uint8 from, uint8 to, bool white, uint32 mover) private pure returns (uint32) {
        if (to == from + 2 || from == to + 2) {
            uint8 rookFrom = to > from ? uint8(mover >> 16) : uint8(mover >> 24);
            _shift(n, rookFrom & 63, to > from ? from + 1 : from - 1, 4, white);
        }
        return ((mover | 0x80800000) & 0xffff00ff) | (uint32(to) << 8);
    }

    function kingSquare(Pos memory p, bool white) internal pure returns (uint8) {
        return uint8((white ? p.whiteState : p.blackState) >> 8);
    }

    /// Whether `white`'s king is attacked.
    function inCheck(Pos memory p, bool white) internal pure returns (bool) {
        uint64 k = p.pc[6] & (white ? p.white : p.black);
        if (k == 0) return false;
        return attacked(p, lsb(k), !white);
    }

    /// What legality needs to know about the side to move, computed once per position.
    struct Gen {
        uint64 own;
        uint64 opp;
        uint64 empty;
        uint64 checkMask; // where a non-king move must land: everything, or the checker and the squares between
        uint64 pinned; // our pieces that shield the king from an enemy slider
        uint64 danger; // squares the enemy attacks with our king lifted off the board
        uint8 king; // 64 if there is no king
    }

    function _prepare(Pos memory p, bool white) private pure returns (Gen memory g) {
        g.own = white ? p.white : p.black;
        g.opp = white ? p.black : p.white;
        g.empty = ~(p.white | p.black);
        g.checkMask = type(uint64).max;
        uint64 k = p.pc[6] & g.own;
        if (k == 0) {
            g.king = 64;
            return g;
        }
        g.king = lsb(k);
        uint64 rq = (p.pc[4] | p.pc[5]) & g.opp;
        uint64 bq = (p.pc[2] | p.pc[5]) & g.opp;
        uint64 rk = rookAttacks(k, g.empty);
        uint64 bk = bishopAttacks(k, g.empty);
        uint64 checkers = (rk & rq) | (bk & bq) | (knightAttacks(k) & p.pc[3] & g.opp)
            | (pawnAttacks(k, white) & p.pc[1] & g.opp);
        if (checkers != 0) {
            if (checkers & (checkers - 1) != 0) g.checkMask = 0; // double check: only the king may move
            // a slider's rays and the king's meet only on the squares between them
            else if (checkers & rk & rq != 0) g.checkMask = checkers | (rk & rookAttacks(checkers, g.empty));
            else if (checkers & bk & bq != 0) g.checkMask = checkers | (bk & bishopAttacks(checkers, g.empty));
            else g.checkMask = checkers;
        }
        // a pinner stands behind the first piece on a line from the king, when that piece is ours
        uint64 pinners = rookAttacks(k, g.empty | (rk & g.own)) & ~rk & rq;
        while (pinners != 0) {
            uint64 one = pinners & (~pinners + 1);
            pinners ^= one;
            g.pinned |= rookAttacks(one, g.empty) & rk & g.own;
        }
        pinners = bishopAttacks(k, g.empty | (bk & g.own)) & ~bk & bq;
        while (pinners != 0) {
            uint64 one = pinners & (~pinners + 1);
            pinners ^= one;
            g.pinned |= bishopAttacks(one, g.empty) & bk & g.own;
        }
        g.danger = attacksWith(p, !white, g.empty | k);
    }

    /// The legal destinations of our piece on `from`. Only en passant is tried on a copy of the position (it removes
    /// two pieces from a line); everything else follows from the check mask, the pins and the danger map.
    function _legalTargets(Pos memory p, Gen memory g, Pos memory scratch, uint8 from, bool white)
        private
        pure
        returns (uint64 t)
    {
        t = _targets(p, g, from, white);
        if (from == g.king) return t & ~g.danger;
        if (g.checkMask == 0) return 0;
        uint64 bit = uint64(1) << from;
        uint64 ep;
        if (p.pc[1] & bit != 0) {
            ep = t & pawnAttacks(bit, white) & ~g.opp; // a diagonal step onto an empty square
            t ^= ep;
        }
        t &= g.checkMask;
        if (g.pinned & bit != 0) t &= _line(g.king, from);
        if (ep != 0) {
            makeMoveInto(p, scratch, (uint16(from) << 6) | lsb(ep), white);
            if (!inCheck(scratch, white)) t |= ep;
        }
    }

    /// The squares on the line through two aligned squares, without the two squares themselves.
    function _line(uint8 a, uint8 b) private pure returns (uint64) {
        (uint64 ra, uint64 ba) = rays(a);
        (uint64 rb, uint64 bb) = rays(b);
        return ra & (uint64(1) << b) != 0 ? ra & rb : ba & bb;
    }

    /// Whether `move` (from << 6 | to) is legal for `white`'s side.
    function isLegal(Pos memory p, uint16 move, bool white) internal pure returns (bool) {
        if (move >= 4096) return false;
        uint8 from = uint8(move >> 6);
        if ((white ? p.white : p.black) & (uint64(1) << from) == 0) return false;
        Pos memory scratch;
        return _legalTargets(p, _prepare(p, white), scratch, from, white) & (uint64(1) << (move & 63)) != 0;
    }

    /// All legal moves for `white`'s side, in from-square order (up to 256).
    function legalMoves(Pos memory p, bool white) internal pure returns (uint16[] memory moves) {
        (moves,) = legalMovesAndCheck(p, white);
    }

    /// legalMoves, and whether `white`'s king is in check (as inCheck says; found while preparing the moves).
    function legalMovesAndCheck(Pos memory p, bool white) internal pure returns (uint16[] memory moves, bool check) {
        moves = new uint16[](256);
        uint256 n;
        Pos memory scratch;
        Gen memory g = _prepare(p, white);
        check = g.checkMask != type(uint64).max;
        uint64 pieces = g.own;
        unchecked {
            while (pieces != 0) {
                uint8 from = lsb(pieces);
                pieces &= pieces - 1;
                uint64 targets = _legalTargets(p, g, scratch, from, white);
                while (targets != 0) {
                    moves[n++] = (uint16(from) << 6) | lsb(targets);
                    targets &= targets - 1;
                }
            }
        }
        assembly ("memory-safe") {
            mstore(moves, n)
            mstore(0x40, add(moves, shl(5, add(n, 1)))) // give back the unused slots
        }
    }

    /// Whether `white`'s side has any legal move (the king's moves are tried first).
    function hasLegalMove(Pos memory p, bool white) internal pure returns (bool any) {
        (, any) = status(p, white);
    }

    /// Whether `white`'s king is in check (as inCheck says) and whether `white` has any legal move, from one map of the
    /// enemy's attacks with our king lifted: the king's own square is attacked exactly when it is in that map.
    function status(Pos memory p, bool white) internal pure returns (bool check, bool any) {
        uint64 own = white ? p.white : p.black;
        uint64 k = p.pc[6] & own;
        if (k != 0) {
            // usually the king can step somewhere: that needs only the enemy's attacks, not pins or checkers
            uint64 danger = attacksWith(p, !white, ~(p.white | p.black) | k);
            check = danger & k != 0;
            if (kingAttacks(k) & ~own & ~danger != 0) return (check, true);
        }
        any = _anyLegal(p, white);
    }

    /// hasLegalMove past its king-step shortcut: every piece's legal targets, the king's first.
    function _anyLegal(Pos memory p, bool white) private pure returns (bool) {
        Pos memory scratch;
        Gen memory g = _prepare(p, white);
        if (g.king < 64 && _legalTargets(p, g, scratch, g.king, white) != 0) return true;
        uint64 pieces = g.own;
        unchecked {
            while (pieces != 0) {
                uint8 from = lsb(pieces);
                pieces &= pieces - 1;
                if (from != g.king && _legalTargets(p, g, scratch, from, white) != 0) return true;
            }
        }
        return false;
    }

    /// Where `white`'s moves give check, computed once per position: sq[t] holds the squares from which a piece of
    /// type t attacks the enemy king; disc holds our pieces that alone block one of our sliders from it.
    struct Checks {
        uint64[7] sq;
        uint64 disc;
        uint8 king; // the enemy king's square, 64 if there is none
    }

    function checkInfo(Pos memory p, bool white) internal pure returns (Checks memory c) {
        uint64 ek = p.pc[6] & (white ? p.black : p.white);
        if (ek == 0) {
            c.king = 64;
            return c;
        }
        c.king = lsb(ek);
        uint64 empty = ~(p.white | p.black);
        uint64 own = white ? p.white : p.black;
        uint64 r = rookAttacks(ek, empty);
        uint64 b = bishopAttacks(ek, empty);
        c.sq[1] = pawnAttacks(ek, !white);
        c.sq[2] = b;
        c.sq[3] = knightAttacks(ek);
        c.sq[4] = r;
        c.sq[5] = r | b;
        uint64 behind = rookAttacks(ek, empty | (r & own)) & ~r & (p.pc[4] | p.pc[5]) & own;
        while (behind != 0) {
            uint64 one = behind & (~behind + 1);
            behind ^= one;
            c.disc |= rookAttacks(one, empty) & r & own;
        }
        behind = bishopAttacks(ek, empty | (b & own)) & ~b & (p.pc[2] | p.pc[5]) & own;
        while (behind != 0) {
            uint64 one = behind & (~behind + 1);
            behind ^= one;
            c.disc |= bishopAttacks(one, empty) & b & own;
        }
    }

    /// Whether a legal `move` by `white` checks the enemy king.
    function givesCheck(Pos memory p, Pos memory scratch, uint16 move, bool white) internal pure returns (bool) {
        return givesCheckWith(p, checkInfo(p, white), scratch, move, white);
    }

    /// The same from a precomputed check table. A direct check is a lookup (the moved piece can't open its own line:
    /// it would already have been checking); a discovered check is a blocker leaving its line. Castling, en passant
    /// and promotions are confirmed on the moved position.
    function givesCheckWith(Pos memory p, Checks memory c, Pos memory scratch, uint16 move, bool white)
        internal
        pure
        returns (bool)
    {
        return givesCheckAs(p, c, scratch, move, white, pieceAt(p, uint8(move >> 6)));
    }

    /// givesCheckWith when the moving piece's type `t` is already known.
    function givesCheckAs(Pos memory p, Checks memory c, Pos memory scratch, uint16 move, bool white, uint8 t)
        internal
        pure
        returns (bool)
    {
        if (c.king == 64) return false;
        uint8 from = uint8(move >> 6);
        uint8 to = uint8(move & 63);
        uint64 tb = uint64(1) << to;
        bool special = (t == 6 && (to == from + 2 || from == to + 2))
            || (t == 1 && ((from & 7) != (to & 7) && (p.white | p.black) & tb == 0 || to >> 3 == 7 || to >> 3 == 0));
        if (special) {
            makeMoveInto(p, scratch, move, white);
            return inCheck(scratch, !white);
        }
        if (c.sq[t] & tb != 0) return true;
        return c.disc & (uint64(1) << from) != 0 && _line(c.king, from) & tb == 0;
    }

    /// A move by `white` that checkmates, or 0 if there is none. Only checking moves are tried.
    function mateInOne(Pos memory p, bool white) internal pure returns (uint16) {
        return mateInOne(p, white, type(uint256).max);
    }

    /// The same, giving up after `tries` checking moves (a bounded search for engines; it may miss a mate).
    function mateInOne(Pos memory p, bool white, uint256 tries) internal pure returns (uint16) {
        Checks memory c = checkInfo(p, white);
        if (c.king == 64) return 0;
        uint64 kinds = _checkingKinds(p, c, white);
        if (kinds == 0 && c.disc == 0) return 0;
        Gen memory g = _prepare(p, white);
        Pos memory scratch;
        uint64 pieces = g.own;
        while (pieces != 0) {
            uint8 from = lsb(pieces);
            pieces &= pieces - 1;
            uint64 fb = uint64(1) << from;
            uint8 kind = pieceAt(p, from);
            if (kinds & (uint64(1) << kind) == 0 && c.disc & fb == 0) continue; // can't check: skip its legal moves
            uint64 t = _legalTargets(p, g, scratch, from, white);
            if (t == 0) continue;
            // a move onto a square that attacks the king is a check (givesCheckAs); the others are confirmed below
            uint64 direct = t & c.sq[kind];
            uint64 cand = direct;
            if (c.disc & fb != 0) cand |= t & ~_line(c.king, from);
            if (kind == 6) cand |= t & ~kingAttacks(fb); // castling
            else if (kind == 1) cand |= t & (RANK_1 | RANK_8 | ~(p.white | p.black) & pawnAttacks(fb, white));
            while (cand != 0) {
                uint8 to = lsb(cand);
                uint16 m = (uint16(from) << 6) | to;
                cand &= cand - 1;
                makeMoveInto(p, scratch, m, white);
                if (direct & (uint64(1) << to) == 0 && !inCheck(scratch, !white)) continue;
                if (!hasLegalMove(scratch, !white)) return m;
                if (--tries == 0) return 0;
            }
        }
        return 0;
    }

    /// Bit t set when some piece of type t could give a direct check (a superset: own king safety is ignored). Pawns
    /// are also flagged for a promotion or en passant, the king for castling; discovered checks are left to the
    /// caller (Checks.disc).
    function _checkingKinds(Pos memory p, Checks memory c, bool white) private pure returns (uint64 kinds) {
        uint64 own = white ? p.white : p.black;
        uint64 empty = ~(p.white | p.black);
        uint64 open = ~own;
        uint64 pawns = p.pc[1] & own;
        uint32 state = white ? p.whiteState : p.blackState;
        uint8 ep = uint8((white ? p.blackState : p.whiteState) & 0xff);
        if (pawns & (white ? RANK_8 >> 8 : RANK_1 << 8) != 0 || ep < 64) kinds |= 2;
        if (state & 0x80800000 != 0x80800000) kinds |= 64;
        uint64 pushes = white ? (pawns << 8) & empty : (pawns >> 8) & empty;
        pushes |= white ? ((pushes & RANK_3) << 8) & empty : ((pushes & RANK_6) >> 8) & empty;
        uint64 opp = white ? p.black : p.white;
        if ((pushes | (pawnAttacks(pawns, white) & opp)) & c.sq[1] != 0) kinds |= 2;
        if (bishopAttacks(p.pc[2] & own, empty) & open & c.sq[2] != 0) kinds |= 4;
        if (knightAttacks(p.pc[3] & own) & open & c.sq[3] != 0) kinds |= 8;
        if (rookAttacks(p.pc[4] & own, empty) & open & c.sq[4] != 0) kinds |= 16;
        uint64 q = p.pc[5] & own;
        if ((rookAttacks(q, empty) | bishopAttacks(q, empty)) & open & c.sq[5] != 0) kinds |= 32;
    }

    /// Pseudo-legal destinations of the piece on `from` (own king safety is checked by the caller).
    function _targets(Pos memory p, Gen memory g, uint8 from, bool white) private pure returns (uint64 t) {
        (uint64 own, uint64 opp, uint64 empty) = (g.own, g.opp, g.empty);
        uint64 bit = uint64(1) << from;
        if (p.pc[1] & bit != 0) {
            uint64 one = white ? (bit << 8) & empty : (bit >> 8) & empty;
            t = one;
            if (one != 0) {
                uint64 two = white ? ((one & RANK_3) << 8) & empty : ((one & RANK_6) >> 8) & empty;
                t |= two;
            }
            uint64 ep;
            uint8 epSq = uint8((white ? p.blackState : p.whiteState) & 0xff);
            if (epSq < 64) ep = uint64(1) << epSq;
            t |= pawnAttacks(bit, white) & (opp | ep);
            return t;
        }
        if (p.pc[3] & bit != 0) return knightAttacks(bit) & ~own;
        if (p.pc[6] & bit != 0) return (kingAttacks(bit) & ~own) | _castling(p, g, white);
        if ((p.pc[4] | p.pc[5]) & bit != 0) t = rookAttacks(bit, empty);
        if ((p.pc[2] | p.pc[5]) & bit != 0) t |= bishopAttacks(bit, empty);
        return t & ~own;
    }

    /// Castling squares allowed by the verifier's rules: flags clear, rook on its square, the squares between empty,
    /// the king not in check and not crossing an attacked square (the destination is checked with the other moves).
    /// Attacks come from the danger map (enemy attacks with our king lifted): it differs from the board's attacks only
    /// along a line through the king, and a piece on such a line already gives check.
    function _castling(Pos memory p, Gen memory g, bool white) private pure returns (uint64 t) {
        uint32 state = white ? p.whiteState : p.blackState;
        uint8 king = g.king;
        uint8 ks = uint8(state >> 16);
        uint8 qs = uint8(state >> 24);
        bool kingSide = ks < 64 && ks == king + 3;
        bool queenSide = qs < 64 && qs + 4 == king;
        if (!(kingSide || queenSide) || g.danger & (uint64(1) << king) != 0) return 0;
        uint64 rooks = p.pc[4] & g.own;
        uint64 blocked = ~g.empty | g.danger;
        if (kingSide && rooks & (uint64(1) << ks) != 0) {
            uint64 between = (uint64(1) << (king + 1)) | (uint64(1) << (king + 2));
            if (between & ~g.empty == 0 && blocked & (uint64(1) << (king + 1)) == 0) t |= uint64(1) << (king + 2);
        }
        if (queenSide && rooks & (uint64(1) << qs) != 0) {
            uint64 between = (uint64(1) << (king - 1)) | (uint64(1) << (king - 2)) | (uint64(1) << (king - 3));
            if (between & ~g.empty == 0 && blocked & (uint64(1) << (king - 1)) == 0) t |= uint64(1) << (king - 2);
        }
    }

    // ---------------------------------------------------------------- back to the packed board

    /// The packed board after a legal `move` by `white` on `board` (the position `p` describes), equal to
    /// toBoard(makeMove(p, move, white)) but made by editing only the nibbles the move changes: the mover (a queen
    /// if promoted), what it takes (en passant: the pawn behind the target), and the rook of a castle.
    function boardAfter(uint256 board, Pos memory p, uint16 move, bool white) internal pure returns (uint256 b) {
        unchecked {
            uint256 from = uint256(move >> 6) << 2;
            uint256 to = uint256(move & 63) << 2;
            uint256 piece = (board >> from) & 15;
            b = board & ~(uint256(15) << from) & ~(uint256(15) << to);
            if (piece & 7 == 1) {
                if (to >> 5 == 7 || to >> 5 == 0) piece = (piece & 8) | 5;
                else if ((from >> 2) & 7 != (to >> 2) & 7 && (board >> to) & 15 == 0) b &= ~(uint256(15) << (white ? to - 32 : to + 32));
            } else if (piece & 7 == 6 && (to == from + 8 || from == to + 8)) {
                uint32 state = white ? p.whiteState : p.blackState;
                uint256 rookFrom = (uint256(to > from ? state >> 16 : state >> 24) & 63) << 2;
                uint256 rookTo = to > from ? from + 4 : from - 4;
                b = (b & ~(uint256(15) << rookFrom)) | (((board >> rookFrom) & 15) << rookTo);
            }
            b |= piece << to;
        }
    }

    function toBoard(Pos memory p) internal pure returns (uint256 board) {
        for (uint256 t = 1; t <= 6; t++) board |= _spread(p.pc[t]) * t;
        board |= _spread(p.black) << 3;
    }

    /// Bit i of `x` becomes bit 4 * i (the inverse of _compress).
    function _spread(uint64 b) private pure returns (uint256 x) {
        x = b;
        x = (x | (x << 96)) & 0x000000000000000000000000ffffffff000000000000000000000000ffffffff;
        x = (x | (x << 48)) & 0x000000000000ffff000000000000ffff000000000000ffff000000000000ffff;
        x = (x | (x << 24)) & 0x000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff;
        x = (x | (x << 12)) & 0x000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f;
        x = (x | (x << 6)) & 0x0303030303030303030303030303030303030303030303030303030303030303;
        x = (x | (x << 3)) & 0x1111111111111111111111111111111111111111111111111111111111111111;
    }
}
