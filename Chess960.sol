// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./chess.sol";

/**
 * @title Chess960
 * @notice Extends the Chess validator with Fischer Random Chess (Chess960) support.
 *         All 960 starting positions are generated deterministically on-chain from
 *         a position ID (0–959) using the FIDE Chess960 algorithm.
 *
 *         Rules are identical to standard chess — only the back rank differs.
 *         Position 518 is the standard chess starting position.
 */
contract Chess960 is Chess {

    // ─── Piece constants (inherited from Chess, re-declared for clarity) ──────
    // pawn=1, bishop=2, knight=3, rook=4, queen=5, king=6
    // color_const=0x8 for black

    /**
     * @notice Generate one of 960 Fischer Random starting positions.
     * @param positionId SP number in [0, 959]. SP 518 = standard chess.
     * @return gameState  Packed uint256 board state, ready to pass to checkGame()
     * @return whiteState Initial white player state (king pos, rook positions, en-passant)
     * @return blackState Initial black player state
     */
    function getStartingPosition(uint16 positionId)
        public
        pure
        returns (uint256 gameState, uint32 whiteState, uint32 blackState)
    {
        require(positionId < 960, "Chess960: invalid position ID");

        // ── Step 1: Decode position ID into piece placements ─────────────────
        // Algorithm: FIDE Chess960 SP numbering (Reinhard Scharnagl encoding)

        // Back rank columns for white (rank 1, positions 0–7)
        uint8[8] memory backRank; // 0 = empty

        // n1: dark-squared bishop → columns 1, 3, 5, 7 (dark squares on rank 1)
        uint8 darkBishopCol = uint8((positionId % 4) * 2 + 1);
        backRank[darkBishopCol] = bishop_const;

        // n2: light-squared bishop → columns 0, 2, 4, 6
        uint8 lightBishopCol = uint8(((positionId / 4) % 4) * 2);
        backRank[lightBishopCol] = bishop_const;

        // n3: queen on n3-th empty square (0–5)
        uint8 queenSlot = uint8((positionId / 16) % 6);
        _placeOnNthEmpty(backRank, queenSlot, queen_const);

        // n4: knight positions — 10 combinations on 5 remaining squares
        // Lookup table: each entry is a bitmask of which slots (0–4) get knights
        uint8 knightCode = uint8(positionId / 96); // 0–9
        uint8[2] memory knightSlots = _knightSlots(knightCode);
        _placeOnNthEmpty(backRank, knightSlots[0], knight_const);
        _placeOnNthEmpty(backRank, knightSlots[1], knight_const);

        // Remaining 3 empty squares: rook, king, rook (left to right)
        uint8 queenSideRookCol;
        uint8 kingCol;
        uint8 kingSideRookCol;
        uint8 emptyCount = 0;
        for (uint8 col = 0; col < 8; col++) {
            if (backRank[col] == 0) {
                if (emptyCount == 0)      { backRank[col] = rook_const;   queenSideRookCol = col; }
                else if (emptyCount == 1) { backRank[col] = king_const;   kingCol = col; }
                else                      { backRank[col] = rook_const;   kingSideRookCol = col; }
                unchecked { emptyCount++; }
            }
        }

        // ── Step 2: Build uint256 game state ──────────────────────────────────
        // Start from a fully empty board
        gameState = 0;

        for (uint8 col = 0; col < 8; col++) {
            uint8 whitePiece = backRank[col];
            // White back rank: rank 0 (positions 0–7)
            gameState = setPosition(gameState, col, whitePiece);
            // White pawns: rank 1 (positions 8–15)
            gameState = setPosition(gameState, col + 8, pawn_const);
            // Black pawns: rank 6 (positions 48–55)
            gameState = setPosition(gameState, col + 48, pawn_const | color_const);
            // Black back rank: rank 7 (positions 56–63), mirrored
            gameState = setPosition(gameState, col + 56, whitePiece | color_const);
        }

        // ── Step 3: Build player states ───────────────────────────────────────
        // playerState layout (uint32):
        //   bits 0–7:   en-passant square (0xff = none)
        //   bits 8–15:  king position
        //   bits 16–23: king-side rook position (0x80 = moved/unavailable)
        //   bits 24–31: queen-side rook position (0x80 = moved/unavailable)

        // White: positions on rank 0 (cols 0–7)
        whiteState = uint32(
            uint32(0xff)                          |          // no en-passant
            (uint32(kingCol) << 8)                |          // king position
            (uint32(kingSideRookCol) << 16)       |          // king-side rook
            (uint32(queenSideRookCol) << 24)                 // queen-side rook
        );

        // Black: positions on rank 7 (cols + 56)
        uint8 blackKingPos        = kingCol        + 56;
        uint8 blackKingSideRook   = kingSideRookCol  + 56;
        uint8 blackQueenSideRook  = queenSideRookCol + 56;

        blackState = uint32(
            uint32(0xff)                                |   // no en-passant
            (uint32(blackKingPos) << 8)                 |   // king position
            (uint32(blackKingSideRook) << 16)           |   // king-side rook
            (uint32(blackQueenSideRook) << 24)              // queen-side rook
        );
    }

    /**
     * @notice Validate a complete Chess960 game given a starting position ID.
     * @param positionId SP number in [0, 959]
     * @param moves      Full move sequence (uint16 encoding, same as standard chess)
     * @return outcome   0=inconclusive, 1=draw, 2=white_win, 3=black_win
     */
    function checkChess960Game(uint16 positionId, uint16[] memory moves)
        external
        pure
        returns (
            uint8  outcome,
            uint256 finalGameState,
            uint32  finalWhiteState,
            uint32  finalBlackState
        )
    {
        (uint256 startState, uint32 whiteState, uint32 blackState) = getStartingPosition(positionId);
        return checkGame(startState, whiteState, blackState, false, moves);
    }

    /**
     * @notice Returns the starting position for a given SP number as a human-readable
     *         8-character string using piece letters (PBNRQK for white, lowercase for black).
     *         Useful for off-chain display.
     */
    function getPositionString(uint16 positionId)
        external
        pure
        returns (string memory)
    {
        (uint256 gameState, , ) = getStartingPosition(positionId);

        bytes memory result = new bytes(8);
        bytes memory pieceChars = "PBNRQK";  // index 1-6

        for (uint8 col = 0; col < 8; col++) {
            uint8 piece = pieceAtPosition(gameState, col); // rank 0
            uint8 ptype = piece & type_mask_const;
            result[col] = ptype == 0 ? bytes1("-") : pieceChars[ptype - 1];
        }

        return string(result);
    }

    // ─── Internal Helpers ────────────────────────────────────────────────────

    /**
     * @dev Place a piece on the n-th empty square of backRank (left to right).
     *      Modifies backRank in place.
     */
    function _placeOnNthEmpty(uint8[8] memory backRank, uint8 n, uint8 piece) internal pure {
        uint8 count = 0;
        for (uint8 col = 0; col < 8; col++) {
            if (backRank[col] == 0) {
                if (count == n) {
                    backRank[col] = piece;
                    return;
                }
                unchecked { count++; }
            }
        }
        revert("Chess960: _placeOnNthEmpty out of bounds");
    }

    /**
     * @dev Returns the two slot indices (0–4) for knight placement given code 0–9.
     *      Corresponds to C(5,2)=10 combinations of choosing 2 from 5 remaining squares.
     *
     *      Encoding (left knight slot, right knight slot):
     *      0→(0,1), 1→(0,2), 2→(0,3), 3→(0,4),
     *      4→(1,2), 5→(1,3), 6→(1,4),
     *      7→(2,3), 8→(2,4),
     *      9→(3,4)
     */
    function _knightSlots(uint8 code) internal pure returns (uint8[2] memory slots) {
        if (code == 0) return [uint8(0), uint8(1)];
        if (code == 1) return [uint8(0), uint8(2)];
        if (code == 2) return [uint8(0), uint8(3)];
        if (code == 3) return [uint8(0), uint8(4)];
        if (code == 4) return [uint8(1), uint8(2)];
        if (code == 5) return [uint8(1), uint8(3)];
        if (code == 6) return [uint8(1), uint8(4)];
        if (code == 7) return [uint8(2), uint8(3)];
        if (code == 8) return [uint8(2), uint8(4)];
        /* 9 */        return [uint8(3), uint8(4)];
    }
}
