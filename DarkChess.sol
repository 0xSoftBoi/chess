// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "./chess.sol";

/**
 * @title DarkChess
 * @notice Fog-of-war chess variant ("Dark Chess"). Standard move rules apply,
 *         but each player sees only their own pieces and the squares their pieces
 *         can reach. Win condition: capture the opponent's king (no checkmate —
 *         you may not know you're in check, and moving into check is legal).
 *
 * Architecture
 * ────────────
 * The contract stores the full board state (same uint256 encoding as chess.sol).
 * After every move, it emits a 64-bit visibility mask for each player so that
 * frontends can correctly restrict what each side sees. Full gameState is also
 * emitted for trustless reconstruction and dispute resolution.
 *
 * True trustless fog-of-war would require ZK; this contract targets the
 * cooperative/semi-trusted case where both players run honest clients.
 *
 * Move encoding: same uint16 as chess.sol
 *   bits 12-15 = promotion piece (0 if none)
 *   bits  6-11 = from position (0x00-0x3f)
 *   bits  0-5  = to position   (0x00-0x3f)
 */
contract DarkChess is Chess, Ownable, ReentrancyGuard {

    // =========================================================================
    // Types
    // =========================================================================

    enum DarkGameState { Waiting, Active, Resolved }

    struct DarkGame {
        address  white;
        address  black;
        uint96   stakeAmount;         // Slot 0 end
        uint256  gameState;           // full board (uint256 board encoding)
        uint32   whitePlayerState;    // castling/ep/king pos for white
        uint32   blackPlayerState;    // castling/ep/king pos for black
        uint64   whiteDeadline;       // white must move by this timestamp
        uint64   blackDeadline;       // black must move by this timestamp
        uint64   createdAt;
        DarkGameState state;
        uint8    outcome;             // 0=none, 2=white_win, 3=black_win
        bool     isBlackTurn;
    }

    // =========================================================================
    // Constants
    // =========================================================================

    // Initial board state — standard chess starting position (same as chess.sol)
    uint256 private constant INITIAL_BOARD =
        0xcbaedabc99999999000000000000000000000000000000001111111143265234;

    // Standard initial player states (from chess.sol README)
    uint32 private constant INITIAL_WHITE_STATE = 0x000704ff;
    uint32 private constant INITIAL_BLACK_STATE = 0x383f3cff;

    uint256 public moveTimeoutSeconds = 3 days;
    uint16  public feeBasisPoints     = 25; // 2.5%

    uint256 public accumulatedFees;
    uint256 public gameIdCounter;

    mapping(uint256 => DarkGame) public games;

    // =========================================================================
    // Events
    // =========================================================================

    event GameCreated(
        uint256 indexed gameId,
        address indexed white,
        uint256 stakeAmount
    );

    event GameJoined(
        uint256 indexed gameId,
        address indexed white,
        address indexed black
    );

    event MoveMade(
        uint256 indexed gameId,
        uint16  move,
        uint64  whiteVisibility,  // bitmask: bit i set → white can see square i
        uint64  blackVisibility,  // bitmask: bit i set → black can see square i
        uint256 gameState         // full board (for replay / dispute)
    );

    event GameResolved(
        uint256 indexed gameId,
        address indexed winner,
        uint8   outcome,
        uint256 payout
    );

    event TimeoutClaimed(uint256 indexed gameId, address indexed claimant);

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor() Ownable() {}

    // =========================================================================
    // Core game functions
    // =========================================================================

    /**
     * @notice Create a new dark chess game. Caller plays as white.
     * @return gameId ID of the new game.
     */
    function createGame() external payable nonReentrant returns (uint256 gameId) {
        uint256 stake = msg.value;
        require(stake > 0, "DarkChess: stake must be > 0");
        require(stake <= type(uint96).max, "DarkChess: stake overflow");

        gameIdCounter += 1;
        gameId = gameIdCounter;

        DarkGame storage g = games[gameId];
        g.white        = msg.sender;
        g.stakeAmount  = uint96(stake);
        g.createdAt    = uint64(block.timestamp);
        g.state        = DarkGameState.Waiting;

        emit GameCreated(gameId, msg.sender, stake);
    }

    /**
     * @notice Join an existing game as black. Must match the stake exactly.
     */
    function joinGame(uint256 gameId) external payable nonReentrant {
        DarkGame storage g = games[gameId];
        require(g.state == DarkGameState.Waiting, "DarkChess: game not open");
        require(msg.sender != g.white, "DarkChess: cannot play yourself");
        require(msg.value == uint256(g.stakeAmount), "DarkChess: wrong stake");

        g.black        = msg.sender;
        g.gameState    = INITIAL_BOARD;
        g.whitePlayerState = INITIAL_WHITE_STATE;
        g.blackPlayerState = INITIAL_BLACK_STATE;
        g.isBlackTurn  = false;
        g.state        = DarkGameState.Active;

        uint64 deadline = uint64(block.timestamp + moveTimeoutSeconds);
        g.whiteDeadline = deadline; // white moves first
        g.blackDeadline = 0;

        emit GameJoined(gameId, g.white, msg.sender);
    }

    /**
     * @notice Submit a move for the active game.
     * @param gameId  Game ID.
     * @param move    Encoded uint16 move (same encoding as chess.sol).
     */
    function submitMove(uint256 gameId, uint16 move) external nonReentrant {
        DarkGame storage g = games[gameId];
        require(g.state == DarkGameState.Active, "DarkChess: game not active");

        bool isBlack = g.isBlackTurn;
        address mover = isBlack ? g.black : g.white;
        require(msg.sender == mover, "DarkChess: not your turn");

        uint8 fromPos = uint8((move >> 6) & 0x3F);
        uint8 toPos   = uint8(move & 0x3F);

        // Validate the move against the full board state using chess.sol's engine.
        // In dark chess, moving into check is legal (player may not know),
        // so we call verifyExecuteMove directly rather than enforcing check rules.
        uint8 moveColor = isBlack ? color_const : 0;
        uint8 piece = uint8((g.gameState >> (uint256(fromPos) * piece_bit_size)) & 0xF);
        require(piece != 0, "DarkChess: no piece at from");
        require((piece & color_const) == moveColor, "DarkChess: wrong piece color");

        (uint256 newState, uint32 newPlayer, uint32 newOpponent) = verifyExecuteMove(
            g.gameState,
            move,
            isBlack ? g.blackPlayerState : g.whitePlayerState,
            isBlack ? g.whitePlayerState : g.blackPlayerState,
            isBlack
        );

        // Detect king capture (dark chess win condition)
        uint8 capturedPiece = uint8((g.gameState >> (uint256(toPos) * piece_bit_size)) & 0xF);
        bool kingCaptured = (capturedPiece & type_mask_const) == king_const;

        // Update state
        if (isBlack) {
            g.blackPlayerState = newPlayer;
            g.whitePlayerState = newOpponent;
        } else {
            g.whitePlayerState = newPlayer;
            g.blackPlayerState = newOpponent;
        }
        g.gameState   = newState;
        g.isBlackTurn = !isBlack;

        // Reset move deadline for the player who must move next
        uint64 deadline = uint64(block.timestamp + moveTimeoutSeconds);
        if (isBlack) {
            g.whiteDeadline = deadline;
            g.blackDeadline = 0;
        } else {
            g.blackDeadline = deadline;
            g.whiteDeadline = 0;
        }

        // Compute visibility masks for both sides after the move
        uint64 whiteVis = computeVisibility(newState, g.whitePlayerState, false);
        uint64 blackVis = computeVisibility(newState, g.blackPlayerState, true);

        emit MoveMade(gameId, move, whiteVis, blackVis, newState);

        // Resolve if king was captured
        if (kingCaptured) {
            uint8 outcome = isBlack ? 3 : 2; // black captures white king → black wins; etc.
            // Wait: if black captures white king, black wins = outcome 3. If white captures black king, white wins = 2.
            // Clarification: isBlack=true means it was black's move and captured white king → black wins (outcome 3)
            //                isBlack=false means it was white's move and captured black king → white wins (outcome 2)
            _resolveGame(gameId, outcome);
        }
    }

    /**
     * @notice Claim a timeout win if the opponent has not moved within the deadline.
     */
    function claimTimeout(uint256 gameId) external nonReentrant {
        DarkGame storage g = games[gameId];
        require(g.state == DarkGameState.Active, "DarkChess: game not active");

        bool claimantIsWhite = (msg.sender == g.white);
        bool claimantIsBlack = (msg.sender == g.black);
        require(claimantIsWhite || claimantIsBlack, "DarkChess: not a participant");

        // It's a timeout if the current mover's deadline has passed and claimant is the OTHER player
        bool isBlackTurn = g.isBlackTurn;
        if (isBlackTurn) {
            // Black must move — white can claim if black's deadline passed
            require(claimantIsWhite, "DarkChess: wait for opponent to timeout");
            require(g.blackDeadline > 0 && block.timestamp > g.blackDeadline, "DarkChess: deadline not passed");
            _resolveGame(gameId, 2); // white wins
        } else {
            // White must move — black can claim if white's deadline passed
            require(claimantIsBlack, "DarkChess: wait for opponent to timeout");
            require(g.whiteDeadline > 0 && block.timestamp > g.whiteDeadline, "DarkChess: deadline not passed");
            _resolveGame(gameId, 3); // black wins
        }

        emit TimeoutClaimed(gameId, msg.sender);
    }

    // =========================================================================
    // Visibility computation
    // =========================================================================

    /**
     * @notice Returns a 64-bit bitmask of squares visible to the given player.
     *         Bit i is set if square i is visible.
     *
     *         Rules:
     *         1. Own piece squares are always visible.
     *         2. Squares reachable by any own piece are visible.
     *         3. For sliding pieces (rook, bishop, queen): all squares on the
     *            ray up to and including the first blocker are visible.
     *
     * @param gameState   Current board state.
     * @param playerState Player's uint32 state (for en-passant, king pos).
     * @param isBlack     True for black player, false for white.
     * @return mask       64-bit visibility bitmask.
     */
    function computeVisibility(
        uint256 gameState,
        uint32  playerState,
        bool    isBlack
    ) public pure returns (uint64 mask) {
        uint8 myColor = isBlack ? color_const : 0;

        for (uint8 pos = 0; pos < 64; pos++) {
            uint8 piece = uint8((gameState >> (uint256(pos) * piece_bit_size)) & 0xF);
            if (piece == 0 || (piece & color_const) != myColor) continue;

            // Own piece is always visible
            mask |= uint64(1) << pos;

            uint8 pt = piece & type_mask_const;

            if (pt == pawn_const) {
                mask |= _pawnVisibility(gameState, pos, isBlack, playerState);
            } else if (pt == knight_const) {
                mask |= _knightVisibility(pos);
            } else if (pt == king_const) {
                mask |= _kingVisibility(pos);
            } else if (pt == rook_const) {
                mask |= _rookVisibility(gameState, pos);
            } else if (pt == bishop_const) {
                mask |= _bishopVisibility(gameState, pos);
            } else if (pt == queen_const) {
                mask |= _rookVisibility(gameState, pos) | _bishopVisibility(gameState, pos);
            }
        }
    }

    // ── Visibility helpers ───────────────────────────────────────────────────

    function _pawnVisibility(
        uint256 gameState,
        uint8   pos,
        bool    isBlack,
        uint32  playerState
    ) internal pure returns (uint64 mask) {
        int8 dir      = isBlack ? int8(-1) : int8(1);
        uint8 col     = pos % 8;
        uint8 row     = pos / 8;
        int8  newRow  = int8(uint8(row)) + dir;
        if (newRow < 0 || newRow > 7) return 0;

        uint8 fwd = uint8(int8(uint8(row)) + dir) * 8 + col;

        // Forward square
        uint8 fwdPiece = uint8((gameState >> (uint256(fwd) * piece_bit_size)) & 0xF);
        mask |= uint64(1) << fwd;

        // Two-square push from starting rank
        bool onStartRank = isBlack ? (row == 6) : (row == 1);
        if (onStartRank && fwdPiece == 0) {
            uint8 fwd2 = uint8(int8(uint8(row)) + dir * 2) * 8 + col;
            mask |= uint64(1) << fwd2;
        }

        // Diagonal captures (and en-passant square)
        uint8 epSquare = uint8(playerState & 0xFF);
        if (col > 0) {
            uint8 capL = uint8(int8(uint8(row)) + dir) * 8 + col - 1;
            uint8 capLPiece = uint8((gameState >> (uint256(capL) * piece_bit_size)) & 0xF);
            if (capLPiece != 0 || capL == epSquare) mask |= uint64(1) << capL;
        }
        if (col < 7) {
            uint8 capR = uint8(int8(uint8(row)) + dir) * 8 + col + 1;
            uint8 capRPiece = uint8((gameState >> (uint256(capR) * piece_bit_size)) & 0xF);
            if (capRPiece != 0 || capR == epSquare) mask |= uint64(1) << capR;
        }
    }

    function _knightVisibility(uint8 pos) internal pure returns (uint64 mask) {
        int8 col = int8(uint8(pos % 8));
        int8 row = int8(uint8(pos / 8));
        int8[8] memory dCol = [int8(1), 2, 2, 1, -1, -2, -2, -1];
        int8[8] memory dRow = [int8(2), 1, -1, -2, -2, -1, 1, 2];
        for (uint8 i = 0; i < 8; i++) {
            int8 nc = col + dCol[i];
            int8 nr = row + dRow[i];
            if (nc >= 0 && nc < 8 && nr >= 0 && nr < 8) {
                mask |= uint64(1) << (uint8(nr) * 8 + uint8(nc));
            }
        }
    }

    function _kingVisibility(uint8 pos) internal pure returns (uint64 mask) {
        int8 col = int8(uint8(pos % 8));
        int8 row = int8(uint8(pos / 8));
        for (int8 dc = -1; dc <= 1; dc++) {
            for (int8 dr = -1; dr <= 1; dr++) {
                if (dc == 0 && dr == 0) continue;
                int8 nc = col + dc;
                int8 nr = row + dr;
                if (nc >= 0 && nc < 8 && nr >= 0 && nr < 8) {
                    mask |= uint64(1) << (uint8(nr) * 8 + uint8(nc));
                }
            }
        }
    }

    function _rookVisibility(uint256 gameState, uint8 pos) internal pure returns (uint64 mask) {
        int8 col = int8(uint8(pos % 8));
        int8 row = int8(uint8(pos / 8));
        int8[4] memory dc = [int8(1), -1, 0, 0];
        int8[4] memory dr = [int8(0), 0, 1, -1];
        for (uint8 d = 0; d < 4; d++) {
            int8 nc = col + dc[d];
            int8 nr = row + dr[d];
            while (nc >= 0 && nc < 8 && nr >= 0 && nr < 8) {
                uint8 sq = uint8(nr) * 8 + uint8(nc);
                mask |= uint64(1) << sq;
                if ((uint8((gameState >> (uint256(sq) * piece_bit_size)) & 0xF)) != 0) break; // blocker
                nc += dc[d];
                nr += dr[d];
            }
        }
    }

    function _bishopVisibility(uint256 gameState, uint8 pos) internal pure returns (uint64 mask) {
        int8 col = int8(uint8(pos % 8));
        int8 row = int8(uint8(pos / 8));
        int8[4] memory dc = [int8(1), 1, -1, -1];
        int8[4] memory dr = [int8(1), -1, 1, -1];
        for (uint8 d = 0; d < 4; d++) {
            int8 nc = col + dc[d];
            int8 nr = row + dr[d];
            while (nc >= 0 && nc < 8 && nr >= 0 && nr < 8) {
                uint8 sq = uint8(nr) * 8 + uint8(nc);
                mask |= uint64(1) << sq;
                if ((uint8((gameState >> (uint256(sq) * piece_bit_size)) & 0xF)) != 0) break; // blocker
                nc += dc[d];
                nr += dr[d];
            }
        }
    }

    // =========================================================================
    // Internal resolution
    // =========================================================================

    function _resolveGame(uint256 gameId, uint8 outcome) internal {
        DarkGame storage g = games[gameId];
        g.state   = DarkGameState.Resolved;
        g.outcome = outcome;

        address winner = (outcome == 2) ? g.white : g.black;
        uint256 total  = uint256(g.stakeAmount) * 2;
        uint256 fee    = (total * feeBasisPoints) / 1000;
        uint256 payout = total - fee;

        accumulatedFees += fee;

        (bool ok, ) = payable(winner).call{value: payout}("");
        require(ok, "DarkChess: ETH transfer failed");

        emit GameResolved(gameId, winner, outcome, payout);
    }

    // =========================================================================
    // Admin
    // =========================================================================

    function setMoveTimeout(uint256 timeout) external onlyOwner {
        require(timeout > 0, "DarkChess: timeout must be > 0");
        moveTimeoutSeconds = timeout;
    }

    function setFee(uint16 _feeBasisPoints) external onlyOwner {
        require(_feeBasisPoints <= 100, "DarkChess: fee exceeds 10%");
        feeBasisPoints = _feeBasisPoints;
    }

    function withdrawFees(address payable to) external onlyOwner nonReentrant {
        uint256 amount = accumulatedFees;
        require(amount > 0, "DarkChess: no fees");
        accumulatedFees = 0;
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "DarkChess: fee withdrawal failed");
    }

    receive() external payable {}
}
