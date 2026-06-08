// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ChessWager, Currency} from "../ChessWager.sol";
import {Chess960} from "../Chess960.sol";
import {ChessProofVerifier} from "../ChessProofVerifier.sol";

/// A stand-in for the RISC Zero verifier: `verify` is a view that succeeds unless told
/// to fail. This lets us test the on-chain BINDING (the actual fix) without generating
/// real zkVM proofs — the SNARK soundness is RISC Zero's job, not this contract's.
contract MockVerifier {
    bool public ok = true;
    function setOk(bool v) external { ok = v; }
    function verify(bytes calldata, bytes32, bytes32) external view {
        require(ok, "MockVerifier: bad proof");
    }
}

contract ChessProofSettlementTest is Test {
    ChessWager         wager;
    Chess960           validator;
    ChessProofVerifier pv;
    MockVerifier       mock;

    uint256 constant WPK = 0xA11CE;
    uint256 constant BPK = 0xB0B;
    uint256 constant ATTACKER_PK = 0xBADBAD;
    address white;
    address black;

    bytes32 constant MOVES_HASH = keccak256("the agreed move list");

    function setUp() public {
        white = vm.addr(WPK);
        black = vm.addr(BPK);
        validator = new Chess960();
        wager = new ChessWager(address(validator));
        mock = new MockVerifier();
        pv = new ChessProofVerifier(address(mock), address(wager), bytes32(uint256(1)));
        wager.setTrustedVerifier(address(pv), true);
        vm.deal(white, 100 ether);
        vm.deal(black, 100 ether);
    }

    function _activeGame() internal returns (uint256 gameId) {
        vm.prank(white);
        gameId = wager.createChallenge{value: 1 ether}(1 ether, Currency.ETH, black);
        vm.prank(black);
        wager.acceptChallenge{value: 1 ether}(gameId);
    }

    function _journal(uint256 gameId, address w, address b, uint8 outcome, bytes32 mh)
        internal pure returns (bytes memory)
    {
        return abi.encode(gameId, w, b, outcome, mh);
    }

    // EIP-712 signature over the MOVES commitment (gameId, movesHash).
    function _sign(uint256 pk, uint256 gameId, bytes32 mh) internal view returns (bytes memory) {
        bytes32 typehash   = keccak256("MovesCommit(uint256 gameId,bytes32 movesHash)");
        bytes32 structHash = keccak256(abi.encode(typehash, gameId, mh));
        bytes32 digest     = keccak256(abi.encodePacked("\x19\x01", wager.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // Happy path: a proof bound to the right game + both players' move-commitment sigs.
    function test_boundProof_withBothSigs_settles() public {
        uint256 gameId = _activeGame();
        uint256 whiteBefore = white.balance;

        pv.verifyAndSettle(
            "",                                        // seal (mock ignores it)
            _journal(gameId, white, black, 2, MOVES_HASH), // outcome 2 = white wins
            _sign(WPK, gameId, MOVES_HASH),
            _sign(BPK, gameId, MOVES_HASH)
        );

        // pot = 2 ether - 2.5% = 1.95 ether to white (its stake was already escrowed)
        assertEq(white.balance, whiteBefore + 1.95 ether);
    }

    // THE FORGE ATTACK: an attacker produces a cryptographically valid proof for the
    // victim's gameId + a White-wins game, but cannot produce the victim's (black's)
    // signature over its move hash. The bound settlement rejects it.
    function test_forgedProof_withoutVictimSignature_reverts() public {
        uint256 gameId = _activeGame();
        bytes32 fakeMoves = keccak256("attacker's winning game");
        bytes memory forgedJournal = _journal(gameId, white, black, 2, fakeMoves);
        bytes memory sw = _sign(ATTACKER_PK, gameId, fakeMoves); // not white's key
        bytes memory sb = _sign(ATTACKER_PK, gameId, fakeMoves);

        vm.expectRevert(bytes("ChessWager: invalid white sig"));
        pv.verifyAndSettle("", forgedJournal, sw, sb);
    }

    // A proof whose journal names players other than this game's is rejected.
    function test_journalPlayerMismatch_reverts() public {
        uint256 gameId = _activeGame();
        address notBlack = vm.addr(0xDEAD);
        bytes memory j = _journal(gameId, white, notBlack, 2, MOVES_HASH);
        bytes memory sw = _sign(WPK, gameId, MOVES_HASH);
        bytes memory sb = _sign(BPK, gameId, MOVES_HASH);
        vm.expectRevert(bytes("ChessWager: player mismatch"));
        pv.verifyAndSettle("", j, sw, sb);
    }

    // An invalid proof (the verifier reverts) stops settlement entirely.
    function test_invalidProof_reverts() public {
        uint256 gameId = _activeGame();
        bytes memory j = _journal(gameId, white, black, 2, MOVES_HASH);
        bytes memory sw = _sign(WPK, gameId, MOVES_HASH);
        bytes memory sb = _sign(BPK, gameId, MOVES_HASH);
        mock.setOk(false);
        vm.expectRevert(bytes("MockVerifier: bad proof"));
        pv.verifyAndSettle("", j, sw, sb);
    }

    // Replay: once resolved, the game is no longer Active, so a second settle reverts.
    function test_replay_reverts() public {
        uint256 gameId = _activeGame();
        bytes memory j = _journal(gameId, white, black, 2, MOVES_HASH);
        bytes memory sw = _sign(WPK, gameId, MOVES_HASH);
        bytes memory sb = _sign(BPK, gameId, MOVES_HASH);
        pv.verifyAndSettle("", j, sw, sb);
        vm.expectRevert(); // inState(Active) modifier — game is now Resolved
        pv.verifyAndSettle("", j, sw, sb);
    }
}
