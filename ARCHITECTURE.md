# Architecture

This document describes the full design of the on-chain chess system — data encodings, contract roles, settlement flows, rating math, and the ZK path.

---

## System map

```
┌─────────────────────────────────────────────────────────────────────┐
│                        chess.sol  (core engine)                     │
│  Pure functions only. No storage. Validates any move sequence.      │
│  Imported by: Chess960, ChessWager, DarkChess                       │
└───────────────────────┬─────────────────────────────────────────────┘
                        │ inherits / calls
          ┌─────────────┼────────────────────┐
          │             │                    │
    ┌─────▼──────┐ ┌────▼──────────┐ ┌──────▼─────┐
    │ Chess960   │ │  ChessWager   │ │ DarkChess  │
    │ (variant)  │ │  (wager hub)  │ │ (fog-of-war│
    └────────────┘ └──┬──┬──┬──┬──┘ └────────────┘
                      │  │  │  │
          ┌───────────┘  │  │  └────────────────┐
          │              │  └──────────┐         │
    ┌─────▼──────┐  ┌────▼───────┐  ┌─▼───────┐ │
    │ ChessRating│  │  Treasure  │  │ChessCoin│ │
    │ (Glicko-2) │  │  (ERC-721) │  │(ERC-20) │ │
    └────────────┘  └─────┬──────┘  └─────────┘ │
                          │                      │
                    ┌─────▼──────┐               │
                    │ ChessSVG   │         ┌──────▼──────────┐
                    │ (SVG gen)  │         │ChessProofVerify │
                    └────────────┘         │ (RISC Zero ZK)  │
                                           └─────────────────┘
                                                    ▲
                                           chess-guest/ (Rust)
                                           off-chain prover
```

**Dependency rules:**
- `chess.sol` depends on nothing (pure functions, no imports)
- `Chess960` and `DarkChess` inherit `Chess` to reuse move validation
- `ChessWager` calls: validator, `ChessRating`, `Treasure`, `ChessCoin`
- `Treasure` delegates tokenURI to `ChessSVG` when renderer is set
- `ChessProofVerifier` is a thin wrapper — it verifies then calls `ChessWager.settleFromVerifier`

---

## Data encodings

### Board state — `uint256`

The entire 8×8 board fits in one 256-bit word: 4 bits per square × 64 squares = 256 bits.

```
Bit layout of each 4-bit nibble:
  bit 3   = color   (0 = white,  1 = black)
  bits 2-0 = piece  (0 = empty, 1 = pawn, 2 = bishop, 3 = knight,
                     4 = rook,  5 = queen, 6 = king)

Square index: a1=0, b1=1, …, h1=7, a2=8, …, h8=63
Nibble position in uint256: bits [ (sq*4)+3 : (sq*4) ]

Initial position:
  0xcbaedabc99999999000000000000000000000000000000001111111143265234
    ╰──────────────╯                                ╰──────────────╯
    black (rank 7,6)                                white (rank 0,1)
```

Reading square `sq` from `gameState`:
```solidity
uint8 piece = uint8((gameState >> (uint256(sq) * 4)) & 0xF);
bool  isBlack = (piece & 0x8) != 0;
uint8 pieceType = piece & 0x7;
```

This encoding means the full board is one cold SLOAD (2100 gas) or one warm SLOAD (100 gas). There is no cheaper representation for a validator that needs per-square random access.

---

### Player state — `uint32`

Each player's castling rights, king position, and en-passant target are packed into a 32-bit word:

```
bits  0- 7:  en-passant target square  (0xFF = none)
bits  8-15:  king position             (0x00–0x3F)
bits 16-23:  king-side rook position   (0x80 = has moved / castling unavailable)
bits 24-31:  queen-side rook position  (0x80 = has moved / castling unavailable)

White initial: 0x000704FF  (king=e1=4, K-rook=h1=7, Q-rook=a1=0)
Black initial: 0x383F3CFF  (king=e8=60, K-rook=h8=63, Q-rook=a8=56)
```

Chess960 games use different initial rook/king positions but the same encoding. After any castling or rook move, the relevant field is set to `0x80` to permanently disable that side.

---

### Move encoding — `uint16`

```
bits 15-12:  promotion piece type (0 = no promotion; 1=pawn,2=bishop,3=knight,
                                   4=rook,5=queen,6=king)
bits 11- 6:  from position (0x00–0x3F)
bits  5- 0:  to position   (0x00–0x3F)

Special moves (consumed by verifyExecuteMove before piece validation):
  0x1000 = request draw
  0x2000 = accept draw
  0x3000 = resign
```

Encoding e2→e4:  `(12 << 6) | 20 = 0x0314`  
Encoding e7→e8=Q: `(5 << 12) | (52 << 6) | 60 = 0x5D3C`

---

## chess.sol — the engine

**Design:** Pure Solidity chess validator. No storage reads or writes. Every function is `pure` or `view`. The contract is designed to be called once per move submission — not as a real-time move generator.

**Core loop** (`checkGame`):
```
for each move in moves[]:
  1. verifyExecuteMove(gameState, move, playerState, opponentState, isBlack)
     ├─ validates piece ownership, move legality
     ├─ handles castling, en-passant, promotion
     └─ returns (newGameState, newPlayerState, newOpponentState)
  2. check 50-move rule (halfmoveClock >= 150 → draw)
  3. check fivefold repetition (keccak256 of position hash → draw)
  4. swap player/opponent for next turn
  5. checkEndgame(newState, ...)
     ├─ checkInsufficientMaterial → draw
     ├─ searchPiece → any legal moves exist?
     └─ checkForCheck → if in check AND no legal moves → checkmate (return 2/3)
                     → if not in check AND no legal moves → stalemate (return 1)
```

**`searchPiece()` — flat loop (iterative)**

Replaced a recursive binary search tree with a flat 64-iteration loop. The recursive version used ~60 gas/frame × 8 recursion levels = ~480 gas of overhead before any actual piece checking. The flat loop iterates all 64 positions with a single `continue` for empty/wrong-color squares:

```solidity
for (uint8 pos = 0; pos < 64; pos++) {
    uint8 piece = uint8((gameState >> (uint256(pos) * 4)) & 0xF);
    if (piece == 0 || (piece & color_const) != color) continue;
    // dispatch by piece type ...
    if (pt == king_const && checkKingValidMoves(...)) return true;
    ...
}
return false;
```

Gas reduction: ~3840 gas (recursive) → ~192 gas (iterative) per full board scan. ~20× improvement.

**Draw detection:**

| Rule | Implementation |
|------|----------------|
| 50-move rule | `halfmoveClock` incremented each half-move; resets on pawn move or capture; draw at 150 (FIDE 75-move article 9.6) |
| Fivefold repetition | `keccak256(abi.encodePacked(gameState, whiteState, blackState, isBlack))` stored per position; draw on 5th occurrence |
| Insufficient material | K vs K; K+minor vs K; K+B vs K+B same-color squares |

**Why keccak256 for repetition, not Zobrist hashing?**

Zobrist uses XOR of random values — fast in C++ chess engines but unsafe on-chain. An adversary who knows the Zobrist keys can craft a position with a deliberate hash collision to falsely claim repetition. `keccak256` is collision-resistant by construction; the preimage attack cost exceeds any conceivable reward.

---

## Chess960.sol

Inherits `Chess`. Adds deterministic back-rank generation from SP number (0–959) using the FIDE Scharnagl encoding:

```
n1 = positionId % 4          → dark-squared bishop column (1,3,5,7)
n2 = (positionId / 4) % 4    → light-squared bishop column (0,2,4,6)
n3 = (positionId / 16) % 6   → queen on n3-th empty square
n4 = positionId / 96 (0–9)   → knight pair (10 combinations of C(5,2))
Remaining 3 empty squares:   → queen-side rook, king, king-side rook
```

SP 518 produces the standard chess starting position. Black's back rank is white's mirrored to rank 7. Player states encode the actual rook/king positions for the random placement.

---

## ChessWager.sol

The hub contract. Manages staking (ETH or CHSC), coordinates the three settlement paths, distributes payouts, mints rewards, updates ratings, and optionally mints NFTs.

### Game struct packing (4 storage slots)

```
Slot 0: white (160 bits) | stakeAmount (96 bits)
Slot 1: black (160 bits) | createdAt (64 bits) | acceptDeadline (32 bits)
Slot 2: gameDeadline (64) | disputeWindowEnd (64) | state (8) | currency (8) |
        whiteOfferedDraw (8) | blackOfferedDraw (8) | submittedOutcome (8)
Slot 3: movesHash (256 bits)
```

Accessing any game field only costs 4 SLOADs max. `allowedOpponent` lives in a separate mapping to avoid a 5th slot for the rare private-challenge case.

### Settlement paths

```
Active
  │
  ├─── settleWithSignatures() ──────────────────────────→ Resolved
  │    Both players sign GameResult off-chain (EIP-712)    ~60k gas
  │    No validator call. No dispute window.
  │
  ├─── settleFromVerifier() ──────────────────────→ Submitted
  │    Called by ChessProofVerifier after ZK proof          ~30k gas
  │    → finalizeGame() after dispute window               ~20k gas
  │
  ├─── submitGame(moves[]) ─────────────────────→ Submitted
  │    On-chain validator. Full move array.                 ~200k–800k gas
  │    │                                                    (move count dependent)
  │    ├─── resubmitGame() during dispute window → Submitted (outcome may change)
  │    └─── finalizeGame() after dispute window  → Resolved
  │
  └─── claimGameTimeout() ──────────────────────────────→ Resolved
       After 7 days with no submission.
```

### EIP-712 optimistic settlement

Both players sign a `GameResult` struct off-chain:

```
DOMAIN_SEPARATOR = keccak256(
    EIP712Domain(name="ChessWager", version="1", chainId, verifyingContract)
)

GameResult(uint256 gameId, bytes32 movesHash, uint8 outcome)

digest = keccak256("\x19\x01" || DOMAIN_SEPARATOR || structHash)
```

`settleWithSignatures()` recovers both signers via `ECDSA.recover(digest, sig)` and requires they match `game.white` and `game.black`. If valid: immediate payout, no validator, no dispute window. The `movesHash` in the struct lets the game be minted as an NFT with a verifiable move record even without on-chain validation.

**Gas breakdown (60-move game):**
| Path | Approx. gas |
|------|-------------|
| `settleWithSignatures` | ~60,000 |
| `finalizeGame` (after ZK) | ~30,000 |
| `submitGame` (60 moves) | ~350,000 |
| `submitGame` (120 moves) | ~650,000 |

### `_resolveGame()` — shared payout logic

All three settlement paths converge into the same internal function:

```
1. Mark state = Resolved                   ← CEI: state changes first
2. Clear playerActiveGame for both players ← prevents reentrancy lock-in
3. Calculate fee (feeBasisPoints / 1000)
4. Distribute pot (ETH low-level call or CHSC.transfer)
5. Mint CHSC rewards (WIN_REWARD=10, DRAW_REWARD=5)
6. Call ChessRating.recordResult()
```

ETH transfers use `call{value}("")` not `transfer` to avoid the 2300 gas stipend breaking with smart contract wallets.

---

## ChessRating.sol — Glicko-2

### Why Glicko-2 over ELO

ELO assumes rating uncertainty is constant — a 5-game player and a 500-game player get the same K-factor adjustment. Glicko-2 adds:
- **Rating Deviation (RD)** — confidence interval. New player: RD=350. Established: RD≈50.
- **Volatility (σ)** — how consistently the player performs. Adjusts after every game.

Used by Lichess, Chess.com, CS2, and Dota 2.

### PlayerRecord — one 256-bit storage slot

```
uint16 rating      (display rating, default 1500)
uint16 rd          (RD×10, default 3500 = RD 350.0)
uint16 sigma       (σ×10000, default 600 = σ 0.06)
uint16 gamesPlayed
uint16 wins
uint16 losses
uint16 draws
uint16 peakRating
─────────────────
128 bits used, 128 bits free
```

All 8 fields fit in one storage slot → a `recordResult()` call costs exactly 2 SLOADs and 2 SSTOREs (one per player), regardless of game history length.

### 7-Step Glicko-2 algorithm (integer fixed-point, SCALE = 1e6)

```
Step 1: Convert to Glicko-2 scale
  μ  = (r - 1500) / 173.7178
  φ  = RD / 173.7178

Step 2: g(φ) = 1 / sqrt(1 + 3φ²/π²)
  Babylonian sqrt, π² = 9.8696 (scaled)

Step 3: E(μ, μⱼ, φⱼ) = 1 / (1 + exp(-g(φⱼ)(μ - μⱼ)))
  7-term Taylor series for exp()

Step 4: v = 1 / Σ[ g(φⱼ)² · E·(1-E) ]

Step 5: Δ = v · Σ[ g(φⱼ) · (sⱼ - E) ]

Step 6: σ' = Illinois algorithm (bisection, 10 iterations)
  Finds root of f(x) = 0 where:
  f(x) = [exp(x)(Δ²-φ²-v-exp(x))] / [2(φ²+v+exp(x))²] - (x-ln(σ²))/τ²

Step 7: φ* = sqrt(φ²+σ'²)   (pre-rating RD)
  φ' = 1 / sqrt(1/φ*² + 1/v)
  μ' = μ + φ'² · Σ[g(φⱼ)(sⱼ-E)]
  Convert back: r' = 173.7178·μ' + 1500,  RD' = 173.7178·φ'
```

**Compilation note:** The Glicko-2 update function has many local variables. Compile with:
```toml
# foundry.toml
[profile.default]
via_ir = true
```

---

## ChessSVG.sol — on-chain SVG renderer

Generates a complete ERC-721 `tokenURI` entirely in Solidity — no IPFS, no external URLs.

### Output format
```
tokenURI = data:application/json;base64,{base64(json)}

json = {
  "name": "Chess Game #N",
  "description": "...",
  "image": "data:image/svg+xml;base64,{base64(svg)}"
}
```

### SVG structure (360×360px)
```xml
<svg viewBox="0 0 360 360">
  <!-- 64 <rect> elements: alternating #769656 / #EEEED2 -->
  <!-- Up to 32 <text> elements: Unicode chess symbols -->
  <!-- Rank/file labels: a-h, 1-8 -->
</svg>
```

**Piece symbols:**
| Type | White | Black |
|------|-------|-------|
| King | ♔ U+2654 | ♚ U+265A |
| Queen | ♕ U+2655 | ♛ U+265B |
| Rook | ♖ U+2656 | ♜ U+265C |
| Bishop | ♗ U+2657 | ♝ U+265D |
| Knight | ♘ U+2658 | ♞ U+265E |
| Pawn | ♙ U+2659 | ♟ U+265F |

Unicode chess symbols are in the Basic Multilingual Plane — supported by all modern browsers and SVG renderers without custom fonts.

**Square extraction from gameState:**
```solidity
uint8 nibble = uint8((gameState >> (pos * 4)) & 0xF);
// bit 3 = color, bits 2-0 = piece type
```

`flipped = true` renders from black's perspective (rank 8 at bottom).

### Treasure.sol integration

```solidity
function tokenURI(uint256 tokenId) public view override returns (string memory) {
    if (svgRenderer != address(0) && games[tokenId].gameState != 0) {
        return IChessSVG(svgRenderer).tokenURIFromGameState(
            games[tokenId].gameState, tokenId, games[tokenId].color
        );
    }
    return super.tokenURI(tokenId); // fallback to stored URI string
}
```

Backwards compatible — NFTs minted before `setSvgRenderer()` fall back to their stored URI.

---

## DarkChess.sol — fog of war

### Rules
- Standard chess move validation (reuses `chess.sol` engine)
- Win condition: **capture the opponent's king** — not checkmate
- Moving into check is legal (you may not know you're in check)
- You see only: your own pieces + all squares any of your pieces can reach

### Visibility algorithm

`computeVisibility(gameState, playerState, isBlack) → uint64 bitmask`

```
For each own piece at position pos:
  set bit pos in mask (own piece is always visible)
  
  pawn:   forward square(s), diagonal captures if occupied or en-passant
  knight: all 8 jump targets within board
  king:   all 8 adjacent squares
  rook:   4 rays — extend until hitting any piece (blocker visible, beyond invisible)
  bishop: 4 diagonal rays — same as rook
  queen:  rook rays ∪ bishop rays
```

### Event-driven fog enforcement

After every move, `MoveMade` emits:
```solidity
event MoveMade(
    uint256 indexed gameId,
    uint16  move,
    uint64  whiteVisibility,  // bitmask: which 64 squares white can see
    uint64  blackVisibility,  // bitmask: which 64 squares black can see
    uint256 gameState         // full board (for replay / dispute)
);
```

Frontends use their own visibility mask to filter what to render. The full `gameState` in the event enables trustless reconstruction and dispute resolution by any third party.

**True trustless fog** (hiding gameState from the chain entirely) requires ZK — a player proves "my move is legal given my hidden board" without revealing the full state. That is a future extension leveraging the ZK infrastructure already built (see below).

### Win detection

After executing a move, the contract checks if the piece on the destination square was a king before the move:
```solidity
uint8 capturedPiece = uint8((gameState >> (toPos * 4)) & 0xF);
bool kingCaptured = (capturedPiece & 0x7) == 6; // king_const
```

If captured: game immediately resolved — no checkmate detection needed.

---

## ChessProofVerifier.sol + chess-guest/ — ZK path

### Architecture

```
Off-chain                              On-chain
─────────────────────────────────      ──────────────────────────────────
chess-guest/src/main.rs               ChessProofVerifier.sol
  Input (private):                      verifyAndSettle(seal, journal)
    - gameId: u64                         │
    - moves: Vec<u16>                     ├─ IRiscZeroVerifier.verify(
  Logic:                                  │    seal, IMAGE_ID, sha256(journal))
    - Replay via shakmaty                 │    → revert if proof invalid
    - Determine outcome                   │
  Journal (public):                       ├─ decode(journal)
    - ABI.encode(gameId, outcome,         │    → (gameId, outcome, movesHash)
        movesHash)                        │
                                          └─ ChessWager.settleFromVerifier(
  Proving via RISC Zero Bonsai                 gameId, outcome, movesHash)
  (cloud) or self-hosted prover
```

### Journal ABI encoding

```solidity
// Solidity decoder (in ChessProofVerifier):
(uint256 gameId, uint8 outcome, bytes32 movesHash) =
    abi.decode(journal, (uint256, uint8, bytes32));

// Rust encoder (in chess-guest/src/main.rs):
let mut journal = [0u8; 96];
journal[24..32].copy_from_slice(&game_id.to_be_bytes()); // uint256 = 32 bytes, game_id fits in last 8
journal[63] = outcome_code;                               // uint8 right-padded in 32 bytes
journal[64..96].copy_from_slice(&moves_hash);            // bytes32 exact
env::commit_slice(&journal);
```

### IMAGE_ID

The `IMAGE_ID` is a deterministic 32-byte hash of the compiled guest binary (ELF). It is set immutably at `ChessProofVerifier` deployment. If the guest program is changed (even one byte), the `IMAGE_ID` changes and old receipts become invalid against the new verifier.

### RISC Zero verifier addresses

| Network | Address |
|---------|---------|
| Mainnet | `0x8EaB2D97Dfce405A1692a21b3ff3A172d593D319` |
| Sepolia | `0x925d8331ddc0a1F0d96E68CF073DFE1d92b69187` |
| Base | `0x0b144e07A0826182176AB3e27021fA07F9EDE7Aa` |
| Arbitrum | `0x0b144e07A0826182176AB3e27021fA07F9EDE7Aa` |

### Build

```bash
cd chess-guest
cargo build --target riscv32im-risc0-zkvm-elf --release
# IMAGE_ID printed in build output or via: cargo run --bin compute-image-id
```

---

## ChessCoin.sol — ERC-20

Simple reward token with controlled minting:

```
mintCap    — immutable. No address can ever mint beyond this total.
totalMinted — tracks cumulative minted supply (not just current balance).
minters    — mapping(address → bool). Only ChessWager is authorized.

addMinter() / removeMinter() — owner-only.
```

Rewards:
- Win a wager game → `10 CHSC` (`WIN_REWARD` in ChessWager)
- Draw a wager game → `5 CHSC` (`DRAW_REWARD` in ChessWager, both players)

---

## TreasureMarket.sol — NFT marketplace

Thin marketplace wrapping the Treasure ERC-721:

- List by token ID at fixed price (ETH or any ERC-20)
- Instant buy: `tokenInstantBuy()` — protected by `nonReentrant`
- Royalty payment to original minter (`originalPlayers[id]`)
- ERC-2771 meta-transaction support (same forwarder pattern as ChessWager)

**CEI fix applied:** `seller[_id]` is captured before zeroing, and `emit` precedes external calls to prevent reentrancy and event-ordering bugs.

---

## Security properties

| Property | Mechanism |
|----------|-----------|
| Trustless settlement | Move array is self-validating — loser cannot block by withholding |
| Reentrancy | `nonReentrant` on all value-transferring functions; CEI ordering throughout |
| No fund lock | If both players disappear: accept timeout (3 days), game timeout (7 days) |
| EIP-712 replay protection | `DOMAIN_SEPARATOR` includes `chainId` and `verifyingContract` — sigs non-portable across chains or contract upgrades |
| ZK trust model | `trustedVerifiers` mapping — owner explicitly whitelists verifier contracts; no implicit trust |
| Mint inflation | `ChessCoin.mintCap` is immutable — enforced even if a minter contract is compromised |
| ETH transfer | `call{value}("")` not `transfer` — compatible with smart contract wallets and future gas repricing |
| Dispute window | 1-hour window after any submission — anyone can resubmit a different (correct) move sequence |

---

## Deployment

```
1.  ChessCoin(initialSupply, mintCap)
2.  Chess()
3.  ChessSVG()
4.  Treasure()                              -- UUPS proxy
5.  TreasureMarket(treasure, forwarder)     -- UUPS proxy
6.  ChessRating()
7.  ChessWager(chess, chessRating, chessCoin, treasure, forwarder)
8.  Chess960()
9.  DarkChess()
10. ChessProofVerifier(risc0Verifier, chessWager, imageId)

Post-deploy authorizations:
  chessCoin.addMinter(chessWager)
  chessRating.authorizeCaller(chessWager)
  treasure.addAdmin(chessWager)
  treasure.setSvgRenderer(chessSVG)
  chessWager.setTrustedVerifier(chessProofVerifier, true)
```

Each contract is independently deployable. `ChessWager` is the only contract that requires all others to be set — the setters are owner-callable post-deploy, so partial deployments are safe.

---

## Gas reference

| Operation | Gas (approx.) |
|-----------|---------------|
| `checkGameFromStart` (20 moves) | ~80,000 |
| `checkGameFromStart` (60 moves) | ~300,000 |
| `checkGameFromStart` (120 moves) | ~600,000 |
| `searchPiece` (full board, iterative) | ~200 |
| `searchPiece` (full board, old recursive) | ~3,840 |
| `settleWithSignatures` | ~60,000 |
| `submitGame` (60 moves) + `finalizeGame` | ~350,000 |
| `verifyAndSettle` (ZK proof) | ~3,000–5,000 |
| `ChessRating.recordResult` (Glicko-2, 2 players) | ~50,000 |
| `ChessSVG.tokenURIFromGameState` (view) | ~800,000 (off-chain only) |
| `DarkChess.computeVisibility` (view) | ~15,000 |
