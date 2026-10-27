// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Rules} from "../src/Rules.sol";
import {ChessEngineV5} from "../src/ChessEngineV5.sol";
import {Bitboard} from "../src/Bitboard.sol";
import {Chess} from "../src/Chess.sol";
import {Strength} from "../src/Strength.sol";
import {Chessboard} from "./Chessboard.sol";

/// Judges a move after the fact, at full effort. Material: the move's net result (what it took or promoted, minus
/// the worst immediate loss it leaves, by the cheapest attacker against defenders) against the best net result of
/// any legal move. Mates: whether it allows the enemy a mate in one when another move didn't, and whether the mover
/// had a mate in one.
contract Judge is ChessEngineV5 {
    function net(Ctx memory c, uint16 m) internal pure returns (int256) {
        uint8 from = uint8(m >> 6);
        uint8 to = uint8(m & 63);
        int256 gained;
        if (c.opp & (uint64(1) << to) != 0) gained = _value(uint8(c.board >> (uint256(to) << 2)) & 7);
        if (uint8(c.board >> (uint256(from) << 2)) & 7 == 1 && (to >> 3 == 7 || to >> 3 == 0)) gained += 800;
        Bitboard.Pos memory n = Bitboard.makeMove(c.p, m, c.white);
        Maps memory e = _maps(n, !c.white);
        uint64 defended = Bitboard.attacksBy(n, c.white);
        uint64 hit = (c.white ? n.white : n.black) & ~n.pc[6] & e.all;
        int256 worst;
        while (hit != 0) {
            uint8 sq = Bitboard.lsb(hit);
            hit &= hit - 1;
            uint64 bit = uint64(1) << sq;
            int256 loss = _loss(e, _value(Bitboard.pieceAt(n, sq)), bit, defended & bit != 0);
            if (loss > worst) worst = loss;
        }
        return gained - worst;
    }

    function judge(uint256 b, uint32 w, uint32 k, bool white, uint16 m)
        external
        pure
        returns (int256 chosen, int256 best, int256 worstAfter, bool allowsMate, bool hadMate)
    {
        Ctx memory c = _context(b, w, k, white, true);
        hadMate = Bitboard.mateInOne(c.p, white) != 0;
        chosen = net(c, m);
        worstAfter = -chosen;
        uint16[] memory all = Bitboard.legalMoves(c.p, white);
        // the best material result among moves that don't allow a mate in one (if there are any)
        best = type(int256).min;
        bool avoidable;
        for (uint256 i; i < all.length; i++) {
            if (Bitboard.mateInOne(Bitboard.makeMove(c.p, all[i], white), !white) != 0) continue;
            avoidable = true;
            int256 x = net(c, all[i]);
            if (x > best) best = x;
        }
        if (!avoidable) best = chosen;
        allowsMate = avoidable && Bitboard.mateInOne(Bitboard.makeMove(c.p, m, white), !white) != 0;
    }
}

/// Self-play with the hook's rules (repetition in its 16-position memory, Chess.MAX_QUIET_PLY quiet half-moves,
/// Chess.MAX_PLY half-moves), each move at the strength of a trade drawn from a realistic mix of pool shares.
/// Reports how games end, their length, checks and captures, gas per choice by effort, and mistakes by effort
///.
contract EngineV5GamesTest is Chessboard {
    ChessEngineV5 v5 = new ChessEngineV5();
    Judge judge = new Judge();

    uint256 constant GAMES = 40;

    // per effort tier (0: under 40%, 1: 40-70%, 2: 70% and up)
    uint256[3] moves;
    uint256[3] gas;
    uint256[3] maxGas;
    uint256[3] mateChances;
    uint256[3] matesTaken;
    uint256[3] walkedIntoMate;
    uint256[3] gavePiece; // a minor piece or more, net
    uint256[3] gaveRook; // a rook or queen, net
    uint256[8] endings; // 1 White mates, 2 Black mates, 3 stalemate, 4 material, 5 repetition, 6 quiet, 7 cap
    uint256 plies;
    uint256 checks;
    uint256 captures;
    uint256 comebacks;
    uint256 undos; // a piece stepping straight back to where it came from on its side's previous move
    uint256 longestQuiet; // summed per game: the longest stretch without a capture or pawn move
    uint256 longQuietGames; // games with a stretch of 30+ such half-moves
    bytes32 fingerprint; // every move of every game: changes whenever play changes

    /// Update when play is meant to change (engine tuning); pure gas work must leave it as it is.
    bytes32 constant GOLDEN = 0xd8cf2f8bfa2b6511983866ec5be1fddbed4111048ce36347cb13af8a5de4b14a;
    uint256 behindAt40;

    struct G {
        uint256 b;
        uint32 w;
        uint32 k;
        uint16 ply;
        uint16 quiet;
        uint64[16] ring;
        int256 materialAt40;
    }

    /// A trade's strength from its share of the pool (src/Strength.sol): mostly 0.005-0.05%, often up to 0.3%,
    /// sometimes up to 1%, rarely a whale over 1%.
    function accuracy(uint256 r) internal pure returns (uint256) {
        uint256 u = r % 100;
        uint256 v = (r >> 8) % 1000;
        uint256 share; // parts per 1e9 of the pool
        if (u < 45) share = 50_000 + v * 450; // 0.005-0.05%
        else if (u < 80) share = 500_000 + v * 2_500; // 0.05-0.3%
        else if (u < 95) share = 3_000_000 + v * 7_000; // 0.3-1%
        else share = 10_000_000 + v * 40_000; // 1-5%
        return Strength.fromShare(share, 1e9);
    }

    function material(uint256 b) internal pure returns (int256 s) {
        int256[7] memory val = [int256(0), 100, 320, 300, 500, 900, 0];
        for (uint256 sq; sq < 64; sq++) {
            uint256 p = (b >> (sq << 2)) & 0xF;
            if (p != 0) s += (p & 8 == 0 ? int256(1) : -1) * val[p & 7];
        }
    }

    function test_selfPlay() public {
        for (uint256 game; game < GAMES; game++) {
            playGame(game);
        }
        emit log_named_uint("games", GAMES);
        emit log_named_uint("White mates", endings[1]);
        emit log_named_uint("Black mates", endings[2]);
        emit log_named_uint("stalemate", endings[3]);
        emit log_named_uint("too little material", endings[4]);
        emit log_named_uint("repetition", endings[5]);
        emit log_named_uint("quiet half-move limit", endings[6]);
        emit log_named_uint("half-move cap", endings[7]);
        emit log_named_uint("average half-moves per game", plies / GAMES);
        emit log_named_uint("checks per game (x10)", checks * 10 / GAMES);
        emit log_named_uint("captures per game (x10)", captures * 10 / GAMES);
        emit log_named_uint("undo moves per game (x10)", undos * 10 / GAMES);
        emit log_named_uint("longest quiet stretch, average per game", longestQuiet / GAMES);
        emit log_named_uint("games with a quiet stretch of 30+", longQuietGames);
        emit log_named_bytes32("games fingerprint", fingerprint);
        emit log_named_string("comebacks (behind 3+ pawns at half-move 40, then won)",
            string.concat(vm.toString(comebacks), " of ", vm.toString(behindAt40)));
        string[3] memory names = ["effort < 40%", "effort 40-70%", "effort 70%+"];
        for (uint256 t; t < 3; t++) {
            if (moves[t] == 0) continue;
            emit log_named_string(names[t], string.concat(
                vm.toString(moves[t]), " moves, gas avg ", vm.toString(gas[t] / moves[t]), " max ",
                vm.toString(maxGas[t]), "; mates in one taken ", vm.toString(matesTaken[t]), "/",
                vm.toString(mateChances[t]), "; walked into an avoidable mate ", vm.toString(walkedIntoMate[t]),
                "; gave a piece ", vm.toString(gavePiece[t]), ", a rook or queen ", vm.toString(gaveRook[t])));
        }
        if (GOLDEN != bytes32(0)) assertEq(fingerprint, GOLDEN, "self-play games changed");
    }

    function playGame(uint256 game) internal {
        G memory g;
        uint16[2] memory last; // each side's previous move
        uint256 maxQuiet;
        (g.b, g.w, g.k) = (Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK);
        uint8 result;
        while (result == 0) {
            bool black = g.ply % 2 == 1;
            (uint32 mover, uint32 other) = black ? (g.k, g.w) : (g.w, g.k);
            uint256 r = uint256(keccak256(abi.encode(game, g.ply)));
            uint256 acc = accuracy(r);
            uint64[8] memory previous;
            for (uint256 i; i < 8; i++) previous[i] = g.ring[(g.ply + 14 - i * 2) % 16];
            uint256 g0 = gasleft();
            (uint16 m,) = v5.choose(g.b, mover, other, black, acc, r >> 16, previous, uint32(game), g.quiet);
            uint256 used = g0 - gasleft();
            uint256 tier = acc < 4_000 ? 0 : acc < 7_000 ? 1 : 2;
            moves[tier]++;
            gas[tier] += used;
            if (used > maxGas[tier]) maxGas[tier] = used;
            record(g, m, tier, black);
            Rules.Played memory p = rules.move(g.b, mover, other, black, m);
            bool irreversible = (g.b >> (uint256(m & 63) << 2)) & 15 != 0 || (g.b >> (uint256(m >> 6) << 2)) & 7 == 1;
            if ((g.b >> (uint256(m & 63) << 2)) & 15 != 0) captures++;
            if (p.check) checks++;
            g.b = p.board;
            (g.w, g.k) = black ? (p.other, p.mover) : (p.mover, p.other);
            g.quiet = irreversible ? 0 : g.quiet + 1;
            if (g.quiet > maxQuiet) maxQuiet = g.quiet;
            uint16 prev = last[g.ply % 2];
            if (prev != 0 && m >> 6 == prev & 63 && m & 63 == prev >> 6) undos++;
            last[g.ply % 2] = m;
            fingerprint = keccak256(abi.encode(fingerprint, game, m));
            g.ply++;
            if (g.ply == 40) g.materialAt40 = material(g.b);
            uint64 key = Chess.positionKey(g.b, g.w, g.k, g.ply & 1 == 1, uint32(game));
            if (p.status == 2) result = black ? 2 : 1;
            else if (p.status == 1) result = 3;
            else if (p.insufficient) result = 4;
            else if (repeated(g, key)) result = 5;
            else if (g.quiet >= Chess.MAX_QUIET_PLY) result = 6;
            else if (g.ply >= Chess.MAX_PLY) result = 7;
            g.ring[(g.ply - 1) % 16] = key;
        }
        endings[result]++;
        longestQuiet += maxQuiet;
        if (maxQuiet >= 30) longQuietGames++;
        plies += g.ply;
        if (g.ply > 40 && (g.materialAt40 <= -300 || g.materialAt40 >= 300)) {
            behindAt40++;
            if ((g.materialAt40 <= -300 && result == 1) || (g.materialAt40 >= 300 && result == 2)) comebacks++;
        }
        if (game < 3) emit log_named_string(string.concat("game ", vm.toString(game), " result ", vm.toString(result)), "");
    }

    /// A giveaway is a move whose immediate material result is clearly worse than the best available: by a minor
    /// piece or more, or (for a rook or queen) by at least 400 with a rook or more left to be taken.
    function record(G memory g, uint16 m, uint256 tier, bool black) internal {
        (int256 chosen, int256 best,, bool allowsMate, bool hadMate) = judge.judge(g.b, g.w, g.k, !black, m);
        if (hadMate) {
            mateChances[tier]++;
            (uint32 mover, uint32 other) = black ? (g.k, g.w) : (g.w, g.k);
            if (rules.move(g.b, mover, other, black, m).status == 2) matesTaken[tier]++;
        }
        if (allowsMate) walkedIntoMate[tier]++;
        if (best - chosen >= 300) gavePiece[tier]++;
        if (best - chosen >= 400 && -chosen >= 500) {
            gaveRook[tier]++;
            if (tier > 0) emit log_named_string("gave rook/queen", string.concat(vm.toString(g.b), " ", vm.toString(g.w), " ", vm.toString(g.k), " ", black ? "b" : "w", " ", vm.toString(m), " net ", vm.toString(chosen), " best ", vm.toString(best)));
        }
    }

    /// The hook's rule: the position after this move seen twice before among the last 16 (or the start position).
    function repeated(G memory g, uint64 key) internal pure returns (bool) {
        if (g.quiet < 4) return false;
        uint256 seen;
        if (g.b == Chess.START_BOARD && g.w == Chess.START_WHITE && g.k == Chess.START_BLACK && g.ply % 2 == 0) {
            seen = 1;
        }
        for (uint256 i = (g.ply + 1) % 2; i < 16; i += 2) {
            if (g.ring[i] == key && ++seen == 2) return true;
        }
        return false;
    }
}
