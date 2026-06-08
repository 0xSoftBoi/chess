# chess

Fully on-chain chess. Every move validated on the EVM.

A complete chess engine written in Solidity — move validation, checkmate detection, castling, en-passant, pawn promotion, and FIDE draw rules all enforced on-chain with no off-chain oracles. Stake ETH or ChessCoin on your game, earn a portable on-chain Glicko-2 rating, and mint any completed game as an on-chain SVG NFT.

---

## Why this is interesting

Most "on-chain chess" projects store game results in a database and call it decentralized. This contract validates the **entire move sequence** — every legal move, every check, every stalemate — inside a single EVM call.

The trick: the entire board state fits in a `uint256`. Four bits per square, 64 squares, 256 bits. One storage slot holds the whole board.

```
Board encoding (uint256, 4 bits per square):
Bit layout per square:
  [3]   = color  (0 = white, 1 = black)
  [2:0] = piece  (0=empty, 1=pawn, 2=bishop, 3=knight, 4=rook, 5=queen, 6=king)

Positions 0–63: a1=0, b1=1, ..., h1=7, a2=8, ..., h8=63

Initial state: 0xcbaedabc99999999000000000000000000000000000000001111111143265234
                ^^^^^^^^^^^^^^^^                                ^^^^^^^^^^^^^^^^
                black back rank + pawns                         white pawns + back rank
```

---

## Contracts

| Contract | Description |
|----------|-------------|
| `chess.sol` | Core validator — takes a move list, returns the game outcome. Pure function, no state. |
| `Chess960.sol` | Fischer Random variant — generates any of 960 starting positions on-chain, validates using the same engine. |
| `ChessWager.sol` | Stake ETH or ChessCoin on a game. Trustless resolution via the on-chain validator, EIP-712 optimistic settlement, or ZK proof. |
| `ChessRating.sol` | On-chain Glicko-2 rating. Updates automatically after every resolved wager game. |
| `ChessSVG.sol` | Fully on-chain SVG renderer — generates board images and NFT metadata from `uint256 gameState`. No IPFS. |
| `Treasure.sol` | Upgradeable ERC-721 — mint any completed game as an on-chain NFT. |
| `TreasureMarket.sol` | NFT marketplace with native ETH and ERC-20 payments, royalties, and meta-transaction support. |
| `ChessCoin.sol` | ERC-20 reward token. Earned by winning or drawing wager games. |
| `DarkChess.sol` | Fog-of-war chess variant — win by capturing the king. Emits per-move visibility bitmasks. |
| `ChessProofVerifier.sol` | RISC Zero ZK verifier wrapper — verify a chess game proof on-chain for ~3k gas. |
| `chess-guest/` | Rust RISC Zero guest program — validates games off-chain and generates ZK proofs. |

---

## How a wager game works

```
Alice                          ChessWager.sol                    Bob
  |                                 |                              |
  |-- createChallenge(0.1 ETH) ---->| Lock stake, emit event       |
  |                                 |<--- acceptChallenge ---------| (Bob matches 0.1 ETH)
  |                                 |                              |
  |   [game played off-chain, moves exchanged peer-to-peer]        |
  |                                 |                              |
  |  ─── Fast path (EIP-712) ──────────────────────────────────    |
  |-- settleWithSignatures() ------->| Both sigs verified, instant  |
  |                                 | payout — no dispute window   |
  |                                 |                              |
  |  ─── Standard path ────────────────────────────────────────    |
  |-- submitGame(moves[]) --------->| Call chess.sol validator     |
  |                                 | outcome = 2 (white wins)     |
  |                                 | Open 1hr dispute window      |
  |                                 |                              |
  |-- finalizeGame() -------------->| Pay Alice 0.198 ETH          |
  |                                 | Mint 10 CHSC reward          |
  |                                 | Update Glicko-2 ratings      |
  |<-- mintGameNFT() ---------------| Optional: mint game as SVG NFT
  |                                 |                              |
  |  ─── ZK path (~3k gas) ─────────────────────────────────────   |
  |  [Rust guest proves game off-chain via RISC Zero]              |
  |-- verifyAndSettle(proof) ------->| Verify STARK, settle game    |
```

**Three settlement paths:**

| Path | Gas cost | When to use |
|------|----------|-------------|
| `settleWithSignatures()` | ~60k | Both players agree on result |
| `submitGame()` → `finalizeGame()` | ~200k–800k | One party disputes |
| `verifyAndSettle()` (ZK) | ~3k–5k | Anyone can submit proof |

**Key properties:**
- Anyone can submit the move array — it's self-validating. The loser can't block resolution by refusing to submit.
- During the 1-hour dispute window, anyone can re-submit a longer or different game sequence.
- If an opponent goes dark, claim a timeout win after 7 days.
- Private challenges: specify `allowedOpponent` to restrict who can accept.

---

## Chess engine features

- Full legal move validation for all piece types
- Check, checkmate, and stalemate detection
- Castling (both sides), with intermediate-square check validation
- En-passant captures
- Pawn promotion (any piece)
- **50-move rule** — automatic draw after 75 moves with no pawn move or capture (FIDE Art. 9.6)
- **Fivefold repetition** — automatic draw when the same position occurs 5 times
- **Insufficient material** — automatic draw for K vs K, K+B vs K, K+N vs K, K+B vs K+B same color
- **Chess960 variant** via `Chess960.sol`
- **Iterative searchPiece** — flat 64-position loop replaces recursive binary search; ~20× gas reduction on endgame detection

---

## On-chain Glicko-2 rating

Every wager game updates both players' ratings via the full 7-step Glicko-2 algorithm, computed entirely in fixed-point integer arithmetic (no floating point, no oracles). Glicko-2 is the system used by Lichess and Chess.com — it tracks not just your rating but your *rating deviation* (RD), a confidence interval that shrinks as you play more games.

```
Default rating:     1500
Default RD:          350  (high uncertainty = new player)
Rating floor:        100
Volatility (σ):     0.06 (initial)

After 20 games:      RD ≈ 50–100 (established player)
After inactivity:    RD grows back toward 350

Brackets:
  < 1000    Beginner
  1000-1400 Intermediate
  1400-1800 Advanced
  1800-2200 Expert
  2200+     Master
```

Ratings are portable — one address, one rating, usable across any frontend that reads `ChessRating.sol`.

**New views:**
```solidity
(uint16 rating, uint16 rd, uint16 sigma) = chessRating.getFullRating(player);
bool isNewPlayer = chessRating.isProvisional(player); // true if RD > 100
```

---

## On-chain SVG NFTs

Every completed game can be minted as a fully on-chain NFT. The board image is generated entirely in Solidity — no IPFS, no external URLs, no dependencies.

```solidity
// Render the starting position SVG (360×360px, Unicode pieces)
string memory svg = chessSVG.svgFromGameState(INITIAL_BOARD, false);

// Full tokenURI with embedded JSON + base64-encoded SVG
string memory uri = chessSVG.tokenURIFromGameState(gameState, tokenId, false);
// Returns: data:application/json;base64,{...}
//   image field: data:image/svg+xml;base64,{...}
```

Board colors: dark `#769656` / light `#EEEED2` (Lichess palette).
Pieces: Unicode chess symbols (♔♕♖♗♘♙ / ♚♛♜♝♞♟) — no custom fonts needed.

---

## EIP-712 optimistic settlement

For games where both players agree on the result, `settleWithSignatures()` bypasses the on-chain validator entirely. Both players sign a `GameResult` struct off-chain:

```typescript
// TypeScript (ethers.js v6)
const domain = {
    name: "ChessWager",
    version: "1",
    chainId: await provider.getNetwork().then(n => n.chainId),
    verifyingContract: CHESS_WAGER_ADDRESS,
};
const types = {
    GameResult: [
        { name: "gameId",    type: "uint256" },
        { name: "movesHash", type: "bytes32" },
        { name: "outcome",   type: "uint8"   },
    ],
};
const value = { gameId, movesHash, outcome };
const sig = await signer.signTypedData(domain, types, value);
```

Then either player (or any relayer) submits both signatures. If both are valid, payout is immediate — no validator call, no dispute window.

---

## ZK path: RISC Zero

Replace the ~500k gas on-chain validator with a ~3k gas ZK proof verification.

```
1. Build chess-guest: cargo build --target riscv32im-risc0-zkvm-elf (in chess-guest/)
2. Get IMAGE_ID from build output
3. Deploy ChessProofVerifier(risc0Verifier, chessWager, IMAGE_ID)
4. Call ChessWager.setTrustedVerifier(chessProofVerifier, true)

To settle a game via ZK:
  Off-chain: run chess-guest with (gameId, moves[]) → receipt + journal
  On-chain:  chessProofVerifier.verifyAndSettle(seal, journal)
             // ~3,000-5,000 gas total
```

RISC Zero verifier is deployed on Ethereum mainnet, Sepolia, Base, and Arbitrum. The `IMAGE_ID` is deterministic from the compiled guest binary.

---

## Dark Chess (fog of war)

A chess variant where each player sees only their own pieces and the squares those pieces can reach. Win by capturing the king — checkmate is not the goal.

```solidity
// Create a game, staking 0.05 ETH
uint256 gameId = darkChess.createGame{value: 0.05 ether}();

// Opponent joins
darkChess.joinGame{value: 0.05 ether}(gameId);

// Submit moves — same uint16 encoding as chess.sol
darkChess.submitMove(gameId, move);

// Each MoveMade event contains:
//   whiteVisibility: uint64  — bitmask of squares white can see
//   blackVisibility: uint64  — bitmask of squares black can see
//   gameState:       uint256 — full board (for replay)
```

Frontends read `whiteVisibility` / `blackVisibility` from `MoveMade` events and render only visible squares for each player. Full game state is always in the event for trustless reconstruction.

> **The "fog" is cooperative, not cryptographic.** The full board is stored in plaintext
> and emitted in every `MoveMade` event, so anyone reading chain state (or raw storage)
> sees both sides — the visibility bitmasks are a client-rendering convention, not a
> privacy guarantee. Move *legality* is still enforced on-chain (the contract sees the
> whole board), so you can't cheat the rules; you just can't hide. You can't hide mutable
> shared state on a public chain without ZK / FHE / MPC / trusted hardware — the
> canonical cryptographic fog of war is [Dark Forest](https://blog.zkga.me/announcing-darkforest),
> which keeps positions as hash commitments and proves moves in zero-knowledge. The
> trade-offs are in [this write-up](https://0xsoftboi.github.io/blog/what-a-zk-proof-proves/).

---

## Player state encoding

Game-per-player metadata (castling rights, en-passant, king position) is packed into a `uint32`:

```
bits  0-7:  en-passant target square (0xff = none)
bits  8-15: king position
bits 16-23: king-side rook position  (0x80 = rook has moved, castling unavailable)
bits 24-31: queen-side rook position (0x80 = rook has moved, castling unavailable)

Initial white: 0x000704ff  (rooks at a1/h1, king at e1)
Initial black: 0x383f3cff  (rooks at a8/h8, king at e8)
```

---

## Chess960

Fischer Random Chess uses standard rules with a randomly shuffled back rank (960 possible positions). Bishops must be on opposite-color squares; the king must sit between the two rooks.

```solidity
// Get the starting position for SP 518 (the standard chess starting position)
(uint256 gameState, uint32 white, uint32 black) = chess960.getStartingPosition(518);

// Validate a full Chess960 game
(uint8 outcome,,,) = chess960.checkChess960Game(positionId, moves);

// Get position as a readable string (e.g. "RNBQKBNR")
string memory pos = chess960.getPositionString(518);
```

### Fair position selection (the randomness problem)

`getStartingPosition` only *generates* a board from a position id — it doesn't decide
*which* of the 960 you get, and the 960 setups aren't equally advantageous, so whoever
picks (or pre-knows) the position has an edge. EVM has no native randomness, so
`ChessWager` picks it with a **two-party commit-reveal**:

```
createChess960Challenge(stake, currency, opponent, commit)  // white commits keccak(seed, salt)
acceptChess960Challenge(gameId, commit)                     // black commits, reveal window opens
revealChess960Seed(gameId, seed, salt)  x2                  // positionId = keccak(seedW, seedB, gameId, this) % 960
```

Neither player can bias or pre-know the result (each commits before seeing the other's
seed). The one residual risk — a player who dislikes the still-secret draw refusing to
reveal — is handled by `claimChess960RevealTimeout`: if one reveals and the other stalls
past the window, the revealer wins by forfeit. For a *single-party* draw (a lobby), use
an external VRF via [`IRandomnessSource`](IRandomnessSource.sol) instead. The trade-offs
across commit-reveal / VRF / beacon / native RNG are written up
[here](https://0xsoftboi.github.io/blog/the-on-chain-randomness-landscape/).

### Build & test

```bash
forge install OpenZeppelin/openzeppelin-contracts@v4.9.6
forge install foundry-rs/forge-std
forge test        # Chess960 fair-draw suite
```

The `foundry.toml` scopes compilation to the chess core (the Treasure NFT marketplace
and the RISC Zero verifier are excluded from that profile).

---

## Deployment order

```
1. ChessCoin(initialSupply, mintCap)
2. Chess()
3. ChessSVG()
4. Treasure()                          -- UUPS proxy
5. TreasureMarket(treasure, forwarder) -- UUPS proxy
6. ChessRating()
7. ChessWager(chess, chessRating, chessCoin, treasure, forwarder)
8. Chess960()
9. DarkChess()
10. ChessProofVerifier(risc0Verifier, chessWager, imageId)

Post-deploy:
  chessCoin.addMinter(chessWager)
  chessRating.authorizeCaller(chessWager)
  treasure.addAdmin(chessWager)
  treasure.setSvgRenderer(chessSVG)
  chessWager.setTrustedVerifier(chessProofVerifier, true)
```

> **Note:** `ChessRating.sol` uses Glicko-2 fixed-point math with many local variables.
> Compile with `viaIR = true` in `foundry.toml` (or `--via-ir` flag).

---

## Usage

**Validate any game from the standard starting position:**

```solidity
// Moves encoded as uint16:
//   bits 12-15 = promotion piece type (0 if not a promotion)
//   bits  6-11 = from position (0x00-0x3f)
//   bits  0-5  = to position   (0x00-0x3f)

uint16[] memory moves = new uint16[](2);
moves[0] = (uint16(0x0C) << 6) | 0x14; // e2 (pos 12) -> e4 (pos 20)
moves[1] = (uint16(0x34) << 6) | 0x2C; // e7 (pos 52) -> e5 (pos 44)

(uint8 outcome,,,) = chess.checkGameFromStart(moves);
// 0 = ongoing, 1 = draw, 2 = white wins, 3 = black wins
```

**Create a wager:**

```solidity
// Open challenge, stake 0.1 ETH
uint256 gameId = wager.createChallenge{value: 0.1 ether}(
    0.1 ether,
    Currency.ETH,
    address(0)      // address(0) = open to anyone
);

// Bob accepts
wager.acceptChallenge{value: 0.1 ether}(gameId);

// Fast path: both players sign off-chain and submit signatures
bytes32 movesHash = keccak256(abi.encodePacked(moves));
wager.settleWithSignatures(gameId, 2, movesHash, sigWhite, sigBlack);
// → winner receives 0.195 ETH immediately, earns 10 CHSC, Glicko-2 updated

// Standard path: submit move array
wager.submitGame(gameId, moves);
// After the 1-hour dispute window passes:
wager.finalizeGame(gameId);
```

---

## License

`chess.sol` — UNLICENSED  
All other contracts — MIT
