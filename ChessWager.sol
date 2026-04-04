// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

// ============================================================================
// Interfaces
// ============================================================================

interface IChessValidator {
    function checkGameFromStart(uint16[] calldata moves)
        external
        pure
        returns (
            uint8  outcome,
            uint256 gameState,
            uint32 playerState,
            uint32 opponentState
        );
}

interface IChessRating {
    function recordResult(address winner, address loser, bool isDraw) external;
}

interface ITreasure {
    function mint(
        address _player,
        string calldata _tokenURI,
        bytes32 _moveHash,
        uint8   _level,
        uint16  _a1,
        uint16  _a2,
        uint16  _a3,
        bool    _color
    ) external returns (uint256);
}

interface IChessCoin {
    function mint(address to, uint256 amount) external;
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

// ============================================================================
// Enums
// ============================================================================

enum ChallengeState { Open, Active, Submitted, Resolved, Cancelled }
enum Currency       { ETH, CHSC }

/**
 * @title ChessWager
 * @notice Two players stake ETH or ChessCoin on a chess game. Results are
 *         settled trustlessly by submitting the move list to the on-chain
 *         chess validator. A dispute window allows the loser (or anyone) to
 *         submit an alternative move sequence before the game is finalized.
 */
contract ChessWager is Ownable, ReentrancyGuard {
    using ECDSA for bytes32;

    // =========================================================================
    // Game struct — 4 storage slots
    // =========================================================================

    /**
     * Slot 0: white (160 bits) | stakeAmount (96 bits)
     * Slot 1: black (160 bits) | createdAt (64 bits) | acceptDeadline (32 bits)
     * Slot 2: gameDeadline (64) | disputeWindowEnd (64) | state (8) |
     *         currency (8) | whiteOfferedDraw (8) | blackOfferedDraw (8) |
     *         submittedOutcome (8)  → 160 bits used
     * Slot 3: movesHash (256 bits)
     *
     * allowedOpponent lives in a separate storage variable per game (gas cost
     * acceptable given infrequent private challenges), avoiding a 5th slot.
     */
    struct Game {
        // Slot 0
        address white;          // 20 bytes
        uint96  stakeAmount;    // 12 bytes  (max ~79 billion ETH — sufficient)

        // Slot 1
        address black;          // 20 bytes
        uint64  createdAt;      //  8 bytes
        uint32  acceptDeadline; //  4 bytes

        // Slot 2
        uint64          gameDeadline;      //  8 bytes
        uint64          disputeWindowEnd;  //  8 bytes
        ChallengeState  state;             //  1 byte  (enum stored as uint8)
        Currency        currency;          //  1 byte
        bool            whiteOfferedDraw;  //  1 byte
        bool            blackOfferedDraw;  //  1 byte
        uint8           submittedOutcome;  //  1 byte

        // Slot 3
        bytes32 movesHash;
    }

    // =========================================================================
    // State variables
    // =========================================================================

    IChessValidator public immutable chessValidator;
    IChessRating    public           ratingContract;
    ITreasure       public           treasureContract;
    IChessCoin      public           chessCoin;
    address private _trustedForwarder;

    // ── EIP-712 ───────────────────────────────────────────────────────────────
    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 private constant GAME_RESULT_TYPEHASH = keccak256(
        "GameResult(uint256 gameId,bytes32 movesHash,uint8 outcome)"
    );

    uint16  public feeBasisPoints       = 25;     // 2.5% out of 1000
    uint256 public accumulatedFeesETH;
    uint256 public accumulatedFeesCHSC;
    uint256 public gameIdCounter;

    mapping(uint256 => Game)    public games;
    mapping(uint256 => address) public gameAllowedOpponent; // address(0) = open
    mapping(address => uint256) public playerActiveGame;    // 0 = none
    mapping(address => bool)    public trustedVerifiers;    // ZK verifier whitelist

    uint256 public acceptTimeoutSeconds = 3 days;
    uint256 public gameTimeoutSeconds   = 7 days;
    uint256 public disputeWindowSeconds = 1 hours;

    uint256 public constant WIN_REWARD  = 10 ether; // 10 CHSC (18-decimal)
    uint256 public constant DRAW_REWARD =  5 ether; //  5 CHSC

    // =========================================================================
    // Events
    // =========================================================================

    event ChallengeCreated(
        uint256 indexed gameId,
        address indexed creator,
        uint256 stakeAmount,
        Currency currency,
        uint256 acceptDeadline
    );

    event ChallengeAccepted(
        uint256 indexed gameId,
        address indexed white,
        address indexed black,
        uint256 gameDeadline
    );

    event ChallengeCancelled(
        uint256 indexed gameId,
        address indexed cancelledBy,
        string reason
    );

    event GameSubmitted(
        uint256 indexed gameId,
        address indexed submittedBy,
        bytes32 movesHash,
        uint8   outcome,
        uint256 disputeWindowEnd
    );

    event GameResolved(
        uint256 indexed gameId,
        address indexed winner,
        uint8   outcome,
        uint256 winnerPayout,
        uint256 loserPayout
    );

    event TimeoutClaimed(
        uint256 indexed gameId,
        address indexed claimant,
        string  timeoutType
    );

    event GameNFTMinted(
        uint256 indexed gameId,
        uint256 indexed nftId,
        address indexed player,
        bool    asWhite
    );

    event GameSettledByAgreement(
        uint256 indexed gameId,
        bytes32 movesHash,
        uint8   outcome
    );

    event VerifierUpdated(address indexed verifier, bool trusted);

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(address _chessValidator) Ownable() {
        require(_chessValidator != address(0), "ChessWager: zero validator");
        chessValidator = IChessValidator(_chessValidator);
        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("ChessWager"),
            keccak256("1"),
            block.chainid,
            address(this)
        ));
    }

    // =========================================================================
    // ERC-2771 support (matches TreasureMarket.sol pattern exactly)
    // =========================================================================

    function isTrustedForwarder(address forwarder) public view returns (bool) {
        return forwarder == _trustedForwarder;
    }

    function _msgSender() internal view override returns (address sender) {
        if (isTrustedForwarder(msg.sender)) {
            assembly {
                sender := shr(96, calldataload(sub(calldatasize(), 20)))
            }
        } else {
            return super._msgSender();
        }
    }

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier inState(uint256 gameId, ChallengeState expected) {
        require(games[gameId].state == expected, "ChessWager: wrong game state");
        _;
    }

    modifier onlyParticipant(uint256 gameId) {
        address sender = _msgSender();
        require(
            sender == games[gameId].white || sender == games[gameId].black,
            "ChessWager: not a participant"
        );
        _;
    }

    modifier notInActiveGame() {
        require(
            playerActiveGame[_msgSender()] == 0,
            "ChessWager: already in an active game"
        );
        _;
    }

    // =========================================================================
    // Core functions
    // =========================================================================

    /**
     * @notice Create a new wager challenge.
     * @param stakeAmount Amount to stake (in wei for ETH, in token units for CHSC).
     * @param currency    ETH or CHSC.
     * @param opponent    Address of allowed opponent; address(0) for open challenge.
     */
    function createChallenge(
        uint256  stakeAmount,
        Currency currency,
        address  opponent
    )
        external
        payable
        nonReentrant
        notInActiveGame
        returns (uint256 gameId)
    {
        require(stakeAmount > 0, "ChessWager: stake must be > 0");
        require(stakeAmount <= type(uint96).max, "ChessWager: stake overflow");

        address sender = _msgSender();

        if (currency == Currency.ETH) {
            require(msg.value == stakeAmount, "ChessWager: ETH value mismatch");
        } else {
            require(msg.value == 0, "ChessWager: ETH must be 0 for CHSC stake");
            require(
                address(chessCoin) != address(0),
                "ChessWager: chessCoin not set"
            );
            bool ok = chessCoin.transferFrom(sender, address(this), stakeAmount);
            require(ok, "ChessWager: CHSC transfer failed");
        }

        gameIdCounter += 1;
        gameId = gameIdCounter;

        uint32 deadline = uint32(block.timestamp + acceptTimeoutSeconds);

        Game memory g;
        g.white          = sender;
        g.stakeAmount    = uint96(stakeAmount);
        g.createdAt      = uint64(block.timestamp);
        g.acceptDeadline = deadline;
        g.state          = ChallengeState.Open;
        g.currency       = currency;

        games[gameId]                = g;
        gameAllowedOpponent[gameId]  = opponent;
        playerActiveGame[sender]     = gameId;

        emit ChallengeCreated(gameId, sender, stakeAmount, currency, deadline);
    }

    /**
     * @notice Accept an open challenge and begin the game.
     */
    function acceptChallenge(uint256 gameId)
        external
        payable
        nonReentrant
        notInActiveGame
        inState(gameId, ChallengeState.Open)
    {
        Game storage g = games[gameId];
        address sender = _msgSender();

        require(block.timestamp <= g.acceptDeadline, "ChessWager: accept window expired");
        require(sender != g.white, "ChessWager: cannot accept own challenge");

        address allowed = gameAllowedOpponent[gameId];
        if (allowed != address(0)) {
            require(sender == allowed, "ChessWager: not the allowed opponent");
        }

        uint256 stake = uint256(g.stakeAmount);

        if (g.currency == Currency.ETH) {
            require(msg.value == stake, "ChessWager: ETH value mismatch");
        } else {
            require(msg.value == 0, "ChessWager: ETH must be 0 for CHSC stake");
            bool ok = chessCoin.transferFrom(sender, address(this), stake);
            require(ok, "ChessWager: CHSC transfer failed");
        }

        uint64 deadline = uint64(block.timestamp + gameTimeoutSeconds);

        g.black        = sender;
        g.gameDeadline = deadline;
        g.state        = ChallengeState.Active;

        playerActiveGame[sender] = gameId;

        emit ChallengeAccepted(gameId, g.white, sender, deadline);
    }

    /**
     * @notice Cancel an open challenge (creator only). Refunds stake.
     */
    function cancelChallenge(uint256 gameId)
        external
        nonReentrant
        inState(gameId, ChallengeState.Open)
    {
        Game storage g = games[gameId];
        address sender = _msgSender();

        require(sender == g.white, "ChessWager: only creator can cancel");

        g.state = ChallengeState.Cancelled;
        playerActiveGame[g.white] = 0;

        _refundStake(g.white, g.stakeAmount, g.currency);

        emit ChallengeCancelled(gameId, sender, "Creator cancelled");
    }

    /**
     * @notice Claim a refund after the accept window expires without a second player.
     */
    function claimAcceptTimeout(uint256 gameId)
        external
        nonReentrant
        inState(gameId, ChallengeState.Open)
    {
        Game storage g = games[gameId];

        require(block.timestamp > g.acceptDeadline, "ChessWager: accept window still open");

        address white   = g.white;
        uint96  stake   = g.stakeAmount;
        Currency cur    = g.currency;

        g.state = ChallengeState.Cancelled;
        playerActiveGame[white] = 0;

        _refundStake(white, stake, cur);

        emit TimeoutClaimed(gameId, white, "accept");
    }

    /**
     * @notice Submit a completed game's move list for on-chain validation.
     *         Either player (or anyone) may submit.
     * @param gameId Game to resolve.
     * @param moves  Packed uint16 move array consumed by chess.sol.
     */
    function submitGame(uint256 gameId, uint16[] calldata moves)
        external
        nonReentrant
        inState(gameId, ChallengeState.Active)
    {
        require(gasleft() > 500_000, "ChessWager: insufficient gas");

        uint8 outcome;
        try chessValidator.checkGameFromStart(moves) returns (
            uint8 o, uint256, uint32, uint32
        ) {
            outcome = o;
        } catch Error(string memory reason) {
            revert(string(abi.encodePacked("ChessWager: validator error — ", reason)));
        } catch {
            revert("ChessWager: invalid move sequence");
        }

        require(outcome != 0, "ChessWager: game is not conclusive");

        Game storage g   = games[gameId];
        bytes32 mHash    = keccak256(abi.encodePacked(moves));
        uint64  dispEnd  = uint64(block.timestamp + disputeWindowSeconds);

        g.movesHash         = mHash;
        g.submittedOutcome  = outcome;
        g.disputeWindowEnd  = dispEnd;
        g.state             = ChallengeState.Submitted;

        emit GameSubmitted(gameId, _msgSender(), mHash, outcome, dispEnd);
    }

    /**
     * @notice Submit an alternative move sequence during the dispute window.
     *         The new hash must differ from the existing one (no redundant resubmits).
     *         The dispute window is only reset if the outcome changes.
     */
    function resubmitGame(uint256 gameId, uint16[] calldata moves)
        external
        nonReentrant
        inState(gameId, ChallengeState.Submitted)
    {
        Game storage g = games[gameId];

        require(block.timestamp < g.disputeWindowEnd, "ChessWager: dispute window closed");
        require(gasleft() > 500_000, "ChessWager: insufficient gas");

        uint8 outcome;
        try chessValidator.checkGameFromStart(moves) returns (
            uint8 o, uint256, uint32, uint32
        ) {
            outcome = o;
        } catch Error(string memory reason) {
            revert(string(abi.encodePacked("ChessWager: validator error — ", reason)));
        } catch {
            revert("ChessWager: invalid move sequence");
        }

        require(outcome != 0, "ChessWager: game is not conclusive");

        bytes32 newHash = keccak256(abi.encodePacked(moves));
        require(newHash != g.movesHash, "ChessWager: identical move sequence");

        bool outcomeChanged = (outcome != g.submittedOutcome);

        g.movesHash        = newHash;
        g.submittedOutcome = outcome;

        if (outcomeChanged) {
            g.disputeWindowEnd = uint64(block.timestamp + disputeWindowSeconds);
        }

        emit GameSubmitted(gameId, _msgSender(), newHash, outcome, g.disputeWindowEnd);
    }

    /**
     * @notice Settle a game instantly using mutual off-chain signatures.
     *         Both players sign a GameResult struct (EIP-712). No validator call,
     *         no dispute window — ~90% gas savings vs submitGame() for honest games.
     * @param gameId    Active game to resolve.
     * @param outcome   1=draw, 2=white_win, 3=black_win.
     * @param movesHash keccak256 of the move array (for event / NFT minting).
     * @param sigWhite  White's EIP-712 signature over (gameId, movesHash, outcome).
     * @param sigBlack  Black's EIP-712 signature over (gameId, movesHash, outcome).
     */
    function settleWithSignatures(
        uint256 gameId,
        uint8   outcome,
        bytes32 movesHash,
        bytes calldata sigWhite,
        bytes calldata sigBlack
    )
        external
        nonReentrant
        inState(gameId, ChallengeState.Active)
    {
        require(outcome >= 1 && outcome <= 3, "ChessWager: invalid outcome");

        bytes32 structHash = keccak256(abi.encode(GAME_RESULT_TYPEHASH, gameId, movesHash, outcome));
        bytes32 digest     = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));

        address recoveredWhite = digest.recover(sigWhite);
        address recoveredBlack = digest.recover(sigBlack);

        Game storage g = games[gameId];
        require(recoveredWhite == g.white, "ChessWager: invalid white sig");
        require(recoveredBlack == g.black, "ChessWager: invalid black sig");

        // Capture fields before state mutation (CEI)
        address  white    = g.white;
        address  black    = g.black;
        uint256  stake    = uint256(g.stakeAmount);
        Currency currency = g.currency;

        // Record result hash; mark Submitted so _resolveGame's state write is valid
        g.movesHash        = movesHash;
        g.submittedOutcome = outcome;
        g.state            = ChallengeState.Submitted;
        g.disputeWindowEnd = uint64(block.timestamp);

        emit GameSettledByAgreement(gameId, movesHash, outcome);
        emit GameSubmitted(gameId, _msgSender(), movesHash, outcome, block.timestamp);

        // Immediately resolve — no dispute window needed (mutual consent)
        _resolveGame(gameId, outcome, white, black, stake, currency);
    }

    /**
     * @notice Settle a game via a trusted ZK verifier (e.g. RISC Zero).
     *         Called by ChessProofVerifier after on-chain proof verification.
     */
    function settleFromVerifier(
        uint256 gameId,
        uint8   outcome,
        bytes32 movesHash
    )
        external
        nonReentrant
        inState(gameId, ChallengeState.Active)
    {
        require(trustedVerifiers[msg.sender], "ChessWager: untrusted verifier");
        require(outcome >= 1 && outcome <= 3, "ChessWager: bad outcome");

        Game storage g     = games[gameId];
        uint64      dispEnd = uint64(block.timestamp + disputeWindowSeconds);

        g.movesHash        = movesHash;
        g.submittedOutcome = outcome;
        g.disputeWindowEnd = dispEnd;
        g.state            = ChallengeState.Submitted;

        emit GameSubmitted(gameId, msg.sender, movesHash, outcome, dispEnd);
    }

    /**
     * @notice Finalize a submitted game once the dispute window has closed.
     *         Distributes stakes and rewards. Strict CEI ordering.
     */
    function finalizeGame(uint256 gameId)
        external
        nonReentrant
        inState(gameId, ChallengeState.Submitted)
    {
        Game storage g = games[gameId];
        require(block.timestamp >= g.disputeWindowEnd, "ChessWager: dispute window still open");
        _resolveGame(gameId, g.submittedOutcome, g.white, g.black, uint256(g.stakeAmount), g.currency);
    }

    /**
     * @notice Claim a win if the opponent has not submitted the game before the
     *         game deadline. Claimant wins by timeout.
     */
    function claimGameTimeout(uint256 gameId)
        external
        nonReentrant
        onlyParticipant(gameId)
        inState(gameId, ChallengeState.Active)
    {
        Game storage g = games[gameId];

        require(block.timestamp > g.gameDeadline, "ChessWager: game deadline not passed");

        address  claimant  = _msgSender();
        address  white     = g.white;
        address  black     = g.black;
        uint256  stake     = uint256(g.stakeAmount);
        Currency currency  = g.currency;
        uint256  totalStake = stake * 2;
        uint256  fee       = (totalStake * feeBasisPoints) / 1000;
        uint256  payout    = totalStake - fee;

        // Determine who timed out (opponent of claimant)
        address opponent = (claimant == white) ? black : white;
        // outcome: 2 = white win, 3 = black win
        uint8   outcome  = (claimant == white) ? 2 : 3;

        // ---- CEI ----
        g.state = ChallengeState.Resolved;
        playerActiveGame[white] = 0;
        playerActiveGame[black] = 0;

        // ---- Payout ----
        if (currency == Currency.ETH) {
            _sendETH(payable(claimant), payout);
            accumulatedFeesETH += fee;
        } else {
            require(chessCoin.transfer(claimant, payout), "ChessWager: CHSC timeout payout failed");
            accumulatedFeesCHSC += fee;
        }

        // ---- CHSC reward ----
        if (address(chessCoin) != address(0)) {
            chessCoin.mint(claimant, WIN_REWARD);
        }

        // ---- ELO ----
        if (address(ratingContract) != address(0)) {
            ratingContract.recordResult(claimant, opponent, false);
        }

        emit TimeoutClaimed(gameId, claimant, "game");
        emit GameResolved(gameId, claimant, outcome, payout, 0);
    }

    /**
     * @notice Mint a game NFT for a resolved game. Caller claims their color.
     * @param gameId    ID of the resolved game.
     * @param tokenURI  Metadata URI for the NFT.
     * @param asWhite   True if caller played as white, false for black.
     */
    function mintGameNFT(
        uint256 gameId,
        string calldata tokenURI,
        bool asWhite
    )
        external
        nonReentrant
        inState(gameId, ChallengeState.Resolved)
        onlyParticipant(gameId)
    {
        require(address(treasureContract) != address(0), "ChessWager: treasure not set");

        Game storage g = games[gameId];
        address sender = _msgSender();

        if (asWhite) {
            require(sender == g.white, "ChessWager: caller is not white");
        } else {
            require(sender == g.black, "ChessWager: caller is not black");
        }

        // Determine level from outcome (1=draw:1, 2=white_win:2, 3=black_win:2)
        uint8 level = (g.submittedOutcome == 1) ? 1 : 2;

        uint256 nftId = treasureContract.mint(
            sender,
            tokenURI,
            g.movesHash,
            level,
            0, // achievement slots — caller can extend via separate metadata
            0,
            0,
            asWhite
        );

        emit GameNFTMinted(gameId, nftId, sender, asWhite);
    }

    // =========================================================================
    // Admin functions
    // =========================================================================

    /**
     * @notice Set platform fee. Max 10% (100 basis points out of 1000).
     */
    function setFee(uint16 _feeBasisPoints) external onlyOwner {
        require(_feeBasisPoints <= 100, "ChessWager: fee exceeds 10%");
        feeBasisPoints = _feeBasisPoints;
    }

    function withdrawFeesETH(address payable to, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        require(amount <= accumulatedFeesETH, "ChessWager: insufficient ETH fees");
        accumulatedFeesETH -= amount;
        _sendETH(to, amount);
    }

    function withdrawFeesCHSC(address to, uint256 amount) external onlyOwner {
        require(amount <= accumulatedFeesCHSC, "ChessWager: insufficient CHSC fees");
        accumulatedFeesCHSC -= amount;
        require(chessCoin.transfer(to, amount), "ChessWager: CHSC fee withdrawal failed");
    }

    function setRatingContract(address _ratingContract) external onlyOwner {
        ratingContract = IChessRating(_ratingContract);
    }

    function setTreasureContract(address _treasureContract) external onlyOwner {
        treasureContract = ITreasure(_treasureContract);
    }

    function setChessCoin(address _chessCoin) external onlyOwner {
        chessCoin = IChessCoin(_chessCoin);
    }

    function setForwarder(address forwarder) external onlyOwner {
        _trustedForwarder = forwarder;
    }

    function setTimeouts(
        uint256 accept,
        uint256 game,
        uint256 dispute
    ) external onlyOwner {
        require(accept  > 0, "ChessWager: accept timeout must be > 0");
        require(game    > 0, "ChessWager: game timeout must be > 0");
        require(dispute > 0, "ChessWager: dispute timeout must be > 0");
        acceptTimeoutSeconds  = accept;
        gameTimeoutSeconds    = game;
        disputeWindowSeconds  = dispute;
    }

    /**
     * @notice Authorize or revoke a ZK proof verifier contract.
     */
    function setTrustedVerifier(address verifier, bool trusted) external onlyOwner {
        require(verifier != address(0), "ChessWager: zero verifier");
        trustedVerifiers[verifier] = trusted;
        emit VerifierUpdated(verifier, trusted);
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /**
     * @dev Core payout logic shared by finalizeGame and settleWithSignatures.
     *      Must be called with state already set to Resolved (or immediately before
     *      external calls — all state writes happen first inside here).
     */
    function _resolveGame(
        uint256  gameId,
        uint8    outcome,
        address  white,
        address  black,
        uint256  stake,
        Currency currency
    ) internal {
        uint256 totalStake = stake * 2;
        uint256 fee        = (totalStake * feeBasisPoints) / 1000;
        uint256 pot        = totalStake - fee;

        // ---- CEI: state changes first ----
        Game storage g = games[gameId];
        g.state = ChallengeState.Resolved;
        playerActiveGame[white] = 0;
        playerActiveGame[black] = 0;

        // ---- Determine winner and payouts ----
        address winner;
        address loser;
        uint256 winnerPayout;
        uint256 loserPayout;
        bool    isDraw;

        if (outcome == 1) {
            isDraw       = true;
            uint256 half = pot / 2;
            uint256 rem  = pot - half * 2;
            winnerPayout = half + rem; // white gets odd wei
            loserPayout  = half;
            winner       = white;
        } else if (outcome == 2) {
            winner       = white;
            loser        = black;
            winnerPayout = pot;
        } else {
            winner       = black;
            loser        = white;
            winnerPayout = pot;
        }

        // ---- Transfer stakes ----
        if (currency == Currency.ETH) {
            if (isDraw) {
                _sendETH(payable(white), winnerPayout);
                _sendETH(payable(black), loserPayout);
            } else {
                _sendETH(payable(winner), winnerPayout);
            }
            accumulatedFeesETH += fee;
        } else {
            if (isDraw) {
                require(chessCoin.transfer(white, winnerPayout), "ChessWager: CHSC draw transfer failed (white)");
                require(chessCoin.transfer(black, loserPayout),  "ChessWager: CHSC draw transfer failed (black)");
            } else {
                require(chessCoin.transfer(winner, winnerPayout), "ChessWager: CHSC winner transfer failed");
            }
            accumulatedFeesCHSC += fee;
        }

        // ---- Mint CHSC rewards ----
        if (address(chessCoin) != address(0)) {
            if (isDraw) {
                chessCoin.mint(white, DRAW_REWARD);
                chessCoin.mint(black, DRAW_REWARD);
            } else {
                chessCoin.mint(winner, WIN_REWARD);
            }
        }

        // ---- Update rating ----
        if (address(ratingContract) != address(0)) {
            if (isDraw) {
                ratingContract.recordResult(white, black, true);
            } else {
                ratingContract.recordResult(winner, loser, false);
            }
        }

        emit GameResolved(gameId, winner, outcome, winnerPayout, isDraw ? loserPayout : 0);
    }

    /**
     * @dev Send ETH using a low-level call. Reverts on failure.
     */
    function _sendETH(address payable to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "ChessWager: ETH transfer failed");
    }

    /**
     * @dev Refund a player's stake in either currency.
     */
    function _refundStake(address player, uint96 stake, Currency currency) internal {
        if (currency == Currency.ETH) {
            _sendETH(payable(player), uint256(stake));
        } else {
            require(
                chessCoin.transfer(player, uint256(stake)),
                "ChessWager: CHSC refund failed"
            );
        }
    }

    // =========================================================================
    // Receive ETH
    // =========================================================================

    receive() external payable {}
}
