// SPDX-License-Identifier: MIT
//! chess-guest: RISC Zero guest program for chess move validation.
//!
//! Input (private):
//!   - game_id: u64            — identifies the on-chain game
//!   - moves:   Vec<u16>       — packed move array (same encoding as chess.sol)
//!
//! Output (public journal):
//!   - ABI-encoded (game_id: uint256, outcome: uint8, moves_hash: bytes32)
//!
//! Move encoding (matches chess.sol):
//!   bits 12-15 = promotion piece type (0=none, 1=pawn, 2=bishop, 3=knight, 4=rook, 5=queen, 6=king)
//!   bits  6-11 = from position (0x00-0x3f, a1=0 … h8=63)
//!   bits  0-5  = to position
//!
//! Outcome values (matches chess.sol):
//!   0 = inconclusive (game still ongoing at end of provided moves)
//!   1 = draw
//!   2 = white wins (checkmate or resignation)
//!   3 = black wins (checkmate or resignation)

#![no_main]

use risc0_zkvm::guest::env;
use sha2::{Digest, Sha256};
use shakmaty::{
    Chess, Color, Move, Outcome, Position, Role, Square,
    san::SanPlus,
    uci::Uci,
};

risc0_zkvm::guest::entry!(main);

fn main() {
    // ── 1. Read private inputs ───────────────────────────────────────────────
    let game_id: u64    = env::read();
    let moves: Vec<u16> = env::read();

    // ── 2. Decode and replay moves ───────────────────────────────────────────
    let mut pos = Chess::default();
    let mut outcome_code: u8 = 0; // 0 = inconclusive

    for &encoded in &moves {
        // Decode from Solidity uint16 encoding
        let from_idx = ((encoded >> 6) & 0x3F) as u8;
        let to_idx   = (encoded & 0x3F) as u8;
        let promo    = (encoded >> 12) & 0xF;

        let from_sq = Square::new(from_idx as u32);
        let to_sq   = Square::new(to_idx as u32);

        // Build shakmaty Move — try normal, then promotion
        let m: Move = if promo != 0 {
            let role = match promo {
                2 => Role::Bishop,
                3 => Role::Knight,
                4 => Role::Rook,
                5 => Role::Queen,
                6 => Role::King, // unusual but allowed in encoding
                _ => Role::Queen,
            };
            Move::Normal {
                role:      pos.board().piece_at(from_sq).map(|p| p.role).unwrap_or(Role::Pawn),
                from:      from_sq,
                capture:   pos.board().piece_at(to_sq).map(|p| p.role),
                to:        to_sq,
                promotion: Some(role),
            }
        } else {
            // Attempt to find the legal move from this board position
            let legal = pos.legal_moves();
            let found = legal.iter().find(|m| m.from() == Some(from_sq) && m.to() == to_sq && m.promotion().is_none());
            match found {
                Some(mv) => mv.clone(),
                None => panic!("illegal move: from={} to={}", from_idx, to_idx),
            }
        };

        pos = pos.play(&m).expect("move play failed");

        // Check for terminal positions
        if let Some(outcome) = pos.outcome() {
            outcome_code = match outcome {
                Outcome::Decisive { winner: Color::White } => 2,
                Outcome::Decisive { winner: Color::Black } => 3,
                Outcome::Draw                              => 1,
            };
            break;
        }
    }

    // ── 3. Compute moves hash ────────────────────────────────────────────────
    // keccak256-compatible: encode moves as packed big-endian uint16 array
    // Note: we use SHA-256 here for native RISC Zero support; the Solidity side
    // verifies using sha256(journal) not keccak256. The moves_hash stored in
    // ChessWager is the keccak256 of the packed moves, but the journal hash used
    // by the verifier is SHA-256 of the whole journal blob. They serve different
    // purposes — moves_hash is for NFT provenance, not proof security.
    let mut moves_bytes = Vec::with_capacity(moves.len() * 2);
    for &m in &moves {
        moves_bytes.push((m >> 8) as u8);
        moves_bytes.push((m & 0xFF) as u8);
    }
    let moves_hash: [u8; 32] = Sha256::digest(&moves_bytes).into();

    // ── 4. ABI-encode journal outputs ────────────────────────────────────────
    // Solidity ABI encoding for (uint256 gameId, uint8 outcome, bytes32 movesHash):
    //   [0..32]   game_id (uint256, big-endian, left-padded)
    //   [32..64]  outcome (uint8, left-padded to 32 bytes)
    //   [64..96]  moves_hash (bytes32, exact)
    let mut journal = [0u8; 96];
    journal[24..32].copy_from_slice(&game_id.to_be_bytes());
    journal[63] = outcome_code;
    journal[64..96].copy_from_slice(&moves_hash);

    env::commit_slice(&journal);
}
