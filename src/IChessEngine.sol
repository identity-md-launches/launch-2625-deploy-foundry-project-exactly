// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Rules} from "./Rules.sol";

/// What the hook asks of the engine: choose a move and play it by the rules, in one call (Rules.sol).
interface IChessEngine {
    /// Chooses the move for the side to move and plays it. `strengthBps` (0-10,000) sets how hard it looks;
    /// `previous` holds the side's last eight finalized positions (Chess.positionKey, most recent first, zero if
    /// unknown) so it can avoid repeating them; `quiet` counts the half-moves since the last capture or pawn move, so
    /// it can push for progress. Reverts if there is no legal move.
    function play(
        uint256 board,
        uint32 mover,
        uint32 other,
        bool black,
        uint256 strengthBps,
        uint256 seed,
        uint64[8] calldata previous,
        uint32 gameNo,
        uint16 quiet
    ) external view returns (uint16 move, Rules.Played memory played);

    /// A legal move picked by `seed`, cheaply, and played: the hook's fallback if `play` fails.
    function playAny(uint256 board, uint32 mover, uint32 other, bool black, uint256 seed)
        external
        view
        returns (uint16 move, Rules.Played memory played);
}
