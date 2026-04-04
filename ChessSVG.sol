// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title ChessSVG
/// @notice Generates fully on-chain SVG chess board images from a packed uint256 game state.
/// @dev Game state encoding: 4 bits per square, 64 squares (bits 0-3 = a1, bits 252-255 = h8).
///      Each nibble: bit3 = color (0=white, 1=black), bits2-0 = piece (0=empty,1=pawn,2=bishop,
///      3=knight,4=rook,5=queen,6=king).
contract ChessSVG {
    using Strings for uint256;

    // Board dimensions
    uint256 private constant BOARD_PX   = 360;
    uint256 private constant SQUARE_PX  = 45;   // 360 / 8
    uint256 private constant FONT_SIZE  = 36;
    uint256 private constant TEXT_X_OFF = 22;   // col*45 + 22  → horizontal centre
    uint256 private constant TEXT_Y_OFF = 38;   // row*45 + 38  → vertical baseline

    // Square fill colours
    string private constant LIGHT_SQ  = "#EEEED2";
    string private constant DARK_SQ   = "#769656";

    // Piece fill colours
    string private constant WHITE_PC  = "#FFFFFF";
    string private constant BLACK_PC  = "#1A1A1A";

    // -----------------------------------------------------------------------
    // Public entry points
    // -----------------------------------------------------------------------

    /// @notice Returns a data-URI ERC-721 tokenURI (JSON + embedded SVG, both base64).
    /// @param gameState  Packed 256-bit board state.
    /// @param tokenId    Token ID used in the JSON name field.
    /// @param flipped    false = white's perspective (rank 1 at bottom),
    ///                   true  = black's perspective (rank 8 at bottom).
    function tokenURIFromGameState(
        uint256 gameState,
        uint256 tokenId,
        bool    flipped
    ) external pure returns (string memory) {
        string memory svg = _buildSVG(gameState, flipped);
        string memory imgURI = string(abi.encodePacked(
            "data:image/svg+xml;base64,",
            Base64.encode(bytes(svg))
        ));

        string memory json = string(abi.encodePacked(
            '{"name":"Chess Game #',
            tokenId.toString(),
            '","description":"Fully on-chain chess \u2014 every move validated on the EVM.","image":"',
            imgURI,
            '"}'
        ));

        return string(abi.encodePacked(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        ));
    }

    /// @notice Returns the raw SVG string for a given board state.
    /// @param gameState  Packed 256-bit board state.
    /// @param flipped    false = white's perspective, true = black's perspective.
    function svgFromGameState(uint256 gameState, bool flipped)
        external pure returns (string memory)
    {
        return _buildSVG(gameState, flipped);
    }

    // -----------------------------------------------------------------------
    // Internal SVG builder
    // -----------------------------------------------------------------------

    function _buildSVG(uint256 gameState, bool flipped)
        internal pure returns (string memory)
    {
        bytes memory buf;

        // Opening tag + dark background (fills entire board; light squares drawn on top)
        buf = abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" width="360" height="360" viewBox="0 0 360 360">',
            '<rect width="360" height="360" fill="', DARK_SQ, '"/>'
        );

        // --- Light squares (32 rects) ---
        for (uint256 row = 0; row < 8; row++) {
            for (uint256 col = 0; col < 8; col++) {
                if ((col + row) % 2 == 0) {
                    buf = abi.encodePacked(
                        buf,
                        '<rect x="', _u(col * SQUARE_PX),
                        '" y="', _u(row * SQUARE_PX),
                        '" width="45" height="45" fill="', LIGHT_SQ, '"/>'
                    );
                }
            }
        }

        // --- Pieces ---
        for (uint256 svgRow = 0; svgRow < 8; svgRow++) {
            for (uint256 svgCol = 0; svgCol < 8; svgCol++) {
                // Map SVG (col, row) → board position index
                uint256 pos;
                if (!flipped) {
                    // White perspective: SVG row 0 = rank 8, SVG row 7 = rank 1
                    // rank = 8 - svgRow  →  rankIndex = 7 - svgRow
                    pos = (7 - svgRow) * 8 + svgCol;
                } else {
                    // Black perspective: SVG row 0 = rank 1, SVG row 7 = rank 8
                    // file is mirrored: svgCol 0 = h-file (col 7)
                    pos = svgRow * 8 + (7 - svgCol);
                }

                // Extract nibble for this position
                uint256 nibble = (gameState >> (pos * 4)) & 0xF;
                uint256 pieceType  = nibble & 0x7;  // bits 2-0
                uint256 pieceColor = (nibble >> 3) & 0x1; // bit 3

                if (pieceType == 0) continue; // empty square

                string memory unicode = _pieceUnicode(pieceType, pieceColor);
                string memory fillColor = pieceColor == 0 ? WHITE_PC : BLACK_PC;

                buf = abi.encodePacked(
                    buf,
                    '<text x="', _u(svgCol * SQUARE_PX + TEXT_X_OFF),
                    '" y="', _u(svgRow * SQUARE_PX + TEXT_Y_OFF),
                    '" text-anchor="middle" font-size="36" fill="', fillColor, '">',
                    unicode,
                    '</text>'
                );
            }
        }

        buf = abi.encodePacked(buf, '</svg>');
        return string(buf);
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    /// @dev Returns the Unicode chess glyph for a given piece type and color.
    ///      pieceType: 1=pawn, 2=bishop, 3=knight, 4=rook, 5=queen, 6=king
    ///      pieceColor: 0=white, 1=black
    function _pieceUnicode(uint256 pieceType, uint256 pieceColor)
        internal pure returns (string memory)
    {
        if (pieceColor == 0) {
            // White pieces
            if (pieceType == 6) return "\u2654"; // King
            if (pieceType == 5) return "\u2655"; // Queen
            if (pieceType == 4) return "\u2656"; // Rook
            if (pieceType == 2) return "\u2657"; // Bishop
            if (pieceType == 3) return "\u2658"; // Knight
            if (pieceType == 1) return "\u2659"; // Pawn
        } else {
            // Black pieces
            if (pieceType == 6) return "\u265A"; // King
            if (pieceType == 5) return "\u265B"; // Queen
            if (pieceType == 4) return "\u265C"; // Rook
            if (pieceType == 2) return "\u265D"; // Bishop
            if (pieceType == 3) return "\u265E"; // Knight
            if (pieceType == 1) return "\u265F"; // Pawn
        }
        return "";
    }

    /// @dev uint256 → decimal string (avoids Strings import overhead for small numbers).
    function _u(uint256 n) internal pure returns (string memory) {
        return n.toString();
    }
}
