// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IRandomnessSource
/// @notice The seam for swapping how a Chess960 starting position (0-959) is chosen.
///
/// `ChessWager` ships a **two-party commit-reveal** draw, which is the right tool for a
/// 1v1 wager: it needs no oracle, no token, and no trusted third party — the position is
/// a function of two seeds each player committed before seeing the other's, so neither
/// can bias or pre-know it. Its one residual risk (a player refusing to reveal a draw
/// they dislike) is handled on-chain by a reveal deadline + forfeit.
///
/// Commit-reveal does NOT generalize to a *single-party* draw — e.g. a matchmaking lobby
/// that seats one player against a fresh random position, where there is no counterparty
/// to commit against. There, the correct tool is an external **VRF** (e.g. Chainlink
/// VRF): request randomness, and in the async callback derive `positionId = rand % 960`.
/// A `VrfRandomnessSource` implementing this interface can drop into such a flow.
///
/// The cross-cutting rule either way: the party who can abort the transaction must be
/// committed to acting *before* the random value is revealed. See RANDOMNESS notes in
/// the companion write-up.
interface IRandomnessSource {
    /// Request a fair position id for `gameId`. For an async source (VRF) this kicks off
    /// the request; the result arrives via the source's own callback. For a synchronous
    /// source it may return immediately. Returns whether a position is already available.
    function requestPosition(uint256 gameId) external returns (bool ready, uint16 positionId);

    /// The drawn position for `gameId`, once available. Reverts if not yet drawn.
    function positionOf(uint256 gameId) external view returns (uint16 positionId);
}
