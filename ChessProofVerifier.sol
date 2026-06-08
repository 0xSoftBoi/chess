// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice RISC Zero on-chain verifier interface (risc0-ethereum). `verify` reverts on
///         failure. Use the canonical deployed verifier / router for your chain.
interface IRiscZeroVerifier {
    function verify(bytes calldata seal, bytes32 imageId, bytes32 journalDigest) external view;
}

/// @notice ChessWager settlement entry for the ZK path.
interface IChessWager {
    function settleFromProof(
        uint256 gameId,
        address white,
        address black,
        uint8   outcome,
        bytes32 movesHash,
        bytes calldata sigWhite,
        bytes calldata sigBlack
    ) external;
}

/**
 * @title ChessProofVerifier
 * @notice On-chain wrapper for RISC Zero ZK proof verification of chess games.
 *
 *         Off-chain (chess-guest, Rust): replay the moves, and commit the journal
 *           abi.encode(uint256 gameId, address white, address black, uint8 outcome, bytes32 movesHash)
 *         where movesHash = keccak256(packed uint16 moves).
 *
 *         On-chain (this contract): verify the proof against the pinned IMAGE_ID, decode
 *         the journal, and hand it to ChessWager.settleFromProof — which BINDS it to the
 *         game (players must match) and to a moves commitment (both players' signatures
 *         over (gameId, movesHash)). The proof alone proves only "these moves yield this
 *         outcome"; the binding is what stops a valid proof being forged onto another
 *         game. See ChessWager.settleFromProof and the write-up on journal binding.
 *
 * @dev IMAGE_ID is the chess-guest image id, pinned at deploy. `verifier` should be the
 *      canonical RISC Zero verifier/router for the chain (immutable here).
 */
contract ChessProofVerifier is Ownable, ReentrancyGuard {
    IRiscZeroVerifier public immutable verifier;
    IChessWager       public immutable wager;
    bytes32           public immutable IMAGE_ID;

    event ProofVerified(uint256 indexed gameId, uint8 outcome, bytes32 movesHash);

    constructor(address _verifier, address _wager, bytes32 _imageId) Ownable() {
        require(_verifier != address(0), "ChessProofVerifier: zero verifier");
        require(_wager    != address(0), "ChessProofVerifier: zero wager");
        require(_imageId  != bytes32(0), "ChessProofVerifier: zero imageId");
        verifier = IRiscZeroVerifier(_verifier);
        wager    = IChessWager(_wager);
        IMAGE_ID = _imageId;
    }

    /**
     * @notice Verify a ZK proof of game validity and settle the wager.
     * @param seal     RISC Zero proof seal.
     * @param journal  abi.encode(gameId, white, black, outcome, movesHash) — the guest's
     *                 public output.
     * @param sigWhite White's EIP-712 signature over (gameId, movesHash) (moves commitment).
     * @param sigBlack Black's EIP-712 signature over (gameId, movesHash).
     */
    function verifyAndSettle(
        bytes calldata seal,
        bytes calldata journal,
        bytes calldata sigWhite,
        bytes calldata sigBlack
    ) external nonReentrant {
        // 1. The proof must be of the pinned guest program over exactly this journal.
        verifier.verify(seal, IMAGE_ID, sha256(journal));

        // 2. Decode the (bound) public outputs.
        (uint256 gameId, address white, address black, uint8 outcome, bytes32 movesHash) =
            abi.decode(journal, (uint256, address, address, uint8, bytes32));

        require(outcome >= 1 && outcome <= 3, "ChessProofVerifier: invalid outcome in journal");
        emit ProofVerified(gameId, outcome, movesHash);

        // 3. Settle — the wager binds the journal to the game's players and the players'
        //    signed moves commitment.
        wager.settleFromProof(gameId, white, black, outcome, movesHash, sigWhite, sigBlack);
    }
}
