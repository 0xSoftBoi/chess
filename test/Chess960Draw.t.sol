// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ChessWager, Currency} from "../ChessWager.sol";
import {Chess960} from "../Chess960.sol";

/// Tests for the fair Chess960 starting-position draw (two-party commit-reveal).
contract Chess960DrawTest is Test {
    ChessWager wager;
    Chess960   validator;

    address white = address(0xA11CE);
    address black = address(0xB0B);

    bytes32 constant SW = keccak256("white-seed");
    bytes32 constant LW = keccak256("white-salt");
    bytes32 constant SB = keccak256("black-seed");
    bytes32 constant LB = keccak256("black-salt");

    function setUp() public {
        validator = new Chess960(); // has checkGameFromStart + checkChess960Game
        wager = new ChessWager(address(validator));
        vm.deal(white, 100 ether);
        vm.deal(black, 100 ether);
    }

    function _commit(bytes32 seed, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(seed, salt));
    }

    function _openAndAccept() internal returns (uint256 gameId) {
        vm.prank(white);
        gameId = wager.createChess960Challenge{value: 1 ether}(
            1 ether, Currency.ETH, black, _commit(SW, LW)
        );
        vm.prank(black);
        wager.acceptChess960Challenge{value: 1 ether}(gameId, _commit(SB, LB));
    }

    function _positionId(uint256 gameId) internal view returns (uint16 pos) {
        (,,,, pos,,,,,) = wager.chess960Draws(gameId);
    }

    function _resolved(uint256 gameId) internal view returns (bool r) {
        (,,, r,,,,,,) = wager.chess960Draws(gameId);
    }

    // The draw is fair, in range, and deterministic from the two committed seeds.
    function test_bothReveal_drawsValidDeterministicPosition() public {
        uint256 gameId = _openAndAccept();
        vm.prank(white); wager.revealChess960Seed(gameId, SW, LW);
        assertFalse(_resolved(gameId)); // not until BOTH reveal
        vm.prank(black); wager.revealChess960Seed(gameId, SB, LB);

        assertTrue(_resolved(gameId));
        uint16 pos = _positionId(gameId);
        assertLt(pos, 960);
        uint16 expected =
            uint16(uint256(keccak256(abi.encode(SW, SB, gameId, address(wager)))) % 960);
        assertEq(pos, expected);
    }

    // A reveal that doesn't match the commitment is rejected — the commit binds each
    // player to a seed chosen before they saw the other's, so neither can bias the draw.
    function test_revealWithWrongSeed_reverts() public {
        uint256 gameId = _openAndAccept();
        vm.prank(white);
        vm.expectRevert(bytes("ChessWager: bad reveal"));
        wager.revealChess960Seed(gameId, keccak256("not-my-seed"), LW);
    }

    function test_doubleReveal_reverts() public {
        uint256 gameId = _openAndAccept();
        vm.prank(white); wager.revealChess960Seed(gameId, SW, LW);
        vm.prank(white);
        vm.expectRevert(bytes("ChessWager: already revealed"));
        wager.revealChess960Seed(gameId, SW, LW);
    }

    function test_nonPlayerCannotReveal() public {
        uint256 gameId = _openAndAccept();
        vm.prank(address(0xDEAD));
        vm.expectRevert(bytes("ChessWager: not a player"));
        wager.revealChess960Seed(gameId, SW, LW);
    }

    // The last-revealer abort: white reveals, black stalls past the window, white claims
    // the forfeit and is paid the pot. A player can't dodge a disliked draw by stalling.
    function test_revealTimeout_forfeitsToTheRevealer() public {
        uint256 gameId = _openAndAccept();
        vm.prank(white); wager.revealChess960Seed(gameId, SW, LW);

        // before the window lapses, no forfeit
        vm.prank(white);
        vm.expectRevert(bytes("ChessWager: reveal window still open"));
        wager.claimChess960RevealTimeout(gameId);

        vm.warp(block.timestamp + 1 days + 1);
        uint256 whiteBefore = white.balance;
        vm.prank(white);
        wager.claimChess960RevealTimeout(gameId);

        // pot = 2 ether - 2.5% fee = 1.95 ether goes to white (its own stake was already out)
        assertEq(white.balance, whiteBefore + 1.95 ether);
        assertTrue(_resolved(gameId));
    }

    function test_cannotForfeit_whenBothRevealed() public {
        uint256 gameId = _openAndAccept();
        vm.prank(white); wager.revealChess960Seed(gameId, SW, LW);
        vm.prank(black); wager.revealChess960Seed(gameId, SB, LB);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(white);
        vm.expectRevert(bytes("ChessWager: draw already resolved"));
        wager.claimChess960RevealTimeout(gameId);
    }

    // submitGame routes a Chess960 game to checkChess960Game from the drawn position —
    // and refuses to validate before the position has been drawn.
    function test_submitGame_requiresDrawnPosition() public {
        uint256 gameId = _openAndAccept();
        uint16[] memory moves = new uint16[](0);
        vm.prank(white);
        vm.expectRevert(bytes("ChessWager: Chess960 position not drawn yet"));
        wager.submitGame(gameId, moves);
    }
}
