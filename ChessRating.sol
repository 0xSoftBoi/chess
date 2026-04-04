// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title ChessRating
 * @notice On-chain Glicko-2 rating system for the chess wagering ecosystem.
 *         Only authorized callers (e.g. ChessWager) may record results.
 *
 * Glicko-2 scale: μ = (r - 1500) / 173.7178, φ = RD / 173.7178
 * All internal scaled values use SCALE = 1e6.
 *
 * PlayerRecord packs into a single 256-bit storage slot (128 bits used):
 *   rating(16) + rd(16) + sigma(16) + gamesPlayed(16) +
 *   wins(16) + losses(16) + draws(16) + peakRating(16)
 */
contract ChessRating is Ownable {

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint16 public constant DEFAULT_RATING = 1500;
    uint16 public constant DEFAULT_RD     = 350;  // stored as 3500 in rd field
    uint16 public constant MIN_RD         = 30;   // stored as 300 in rd field
    uint16 public constant DEFAULT_SIGMA  = 6;    // stored as 600 (σ = 0.06)
    uint16 public constant MIN_RATING     = 100;

    // Glicko-2 system constant τ = 0.5 → τ² = 0.25 → scaled by 1e6
    uint256 private constant TAU_SQ_SCALED = 250000;

    // 173.7178 × 1e6
    uint256 private constant GLICKO2_SCALE = 173717800;

    // π² × 1e6
    uint256 private constant PI_SQ_SCALED = 9869604;

    // Fixed-point scale
    uint256 private constant SCALE = 1000000; // 1e6

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    struct PlayerRecord {
        uint16 rating;      // display rating (default 1500)
        uint16 rd;          // RD * 10 (default 3500 = RD 350.0)
        uint16 sigma;       // volatility * 10000 (default 600 = σ 0.06)
        uint16 gamesPlayed;
        uint16 wins;
        uint16 losses;
        uint16 draws;
        uint16 peakRating;  // all-time high display rating
        // 128 bits used — fits in one 256-bit slot
    }

    mapping(address => PlayerRecord) private _records;
    mapping(address => bool) public authorizedCallers;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event RatingUpdated(
        address indexed player,
        uint16 oldRating,
        uint16 newRating,
        int16  delta,
        uint16 gamesPlayed
    );
    event RDUpdated(address indexed player, uint16 oldRD, uint16 newRD);
    event CallerAuthorized(address indexed caller);
    event CallerRevoked(address indexed caller);

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyAuthorized() {
        require(authorizedCallers[msg.sender], "ChessRating: not authorized");
        _;
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor() Ownable() {}

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function authorizeCaller(address caller) external onlyOwner {
        authorizedCallers[caller] = true;
        emit CallerAuthorized(caller);
    }

    function revokeCaller(address caller) external onlyOwner {
        authorizedCallers[caller] = false;
        emit CallerRevoked(caller);
    }

    // -------------------------------------------------------------------------
    // Core: record a game result
    // -------------------------------------------------------------------------

    /**
     * @notice Record the result of a completed game.
     * @param winner  Address of the winning player (or player A in a draw).
     * @param loser   Address of the losing player (or player B in a draw).
     * @param isDraw  True if the game ended in a draw.
     */
    function recordResult(
        address winner,
        address loser,
        bool isDraw
    ) external onlyAuthorized {
        PlayerRecord storage recW = _records[winner];
        PlayerRecord storage recL = _records[loser];

        // Lazy-initialize defaults
        _ensureInit(recW);
        _ensureInit(recL);

        // Read pre-game state for both players (snapshot before any mutation)
        // Display ratings
        uint256 rW = recW.rating;
        uint256 rL = recL.rating;

        // RD: stored as RD * 10, so divide by 10 to get display RD
        uint256 rdW = recW.rd;   // stored * 10
        uint256 rdL = recL.rd;   // stored * 10

        // σ: stored as σ * 10000
        uint256 sigmaW = recW.sigma; // stored * 10000
        uint256 sigmaL = recL.sigma; // stored * 10000

        // Scores: 1e6 = win, 5e5 = draw, 0 = loss (internal SCALE units)
        uint256 scoreW = isDraw ? 500000 : 1000000;
        uint256 scoreL = isDraw ? 500000 : 0;

        // Run full Glicko-2 update for winner treating loser as opponent
        (uint256 newRW, uint256 newRdW, uint256 newSigmaW) =
            _glicko2Update(rW, rdW, sigmaW, rL, rdL, scoreW);

        // Run full Glicko-2 update for loser treating winner as opponent
        (uint256 newRL, uint256 newRdL, uint256 newSigmaL) =
            _glicko2Update(rL, rdL, sigmaL, rW, rdW, scoreL);

        // Persist winner
        _persistRecord(recW, winner, rW, rdW, newRW, newRdW, newSigmaW, scoreW);
        // Persist loser
        _persistRecord(recL, loser, rL, rdL, newRL, newRdL, newSigmaL, scoreL);
    }

    // -------------------------------------------------------------------------
    // Internal: Glicko-2 update (single player, single opponent)
    // -------------------------------------------------------------------------

    /**
     * @dev Full 7-step Glicko-2 update for one player.
     * @param r       Player display rating
     * @param rdStored  Player RD * 10 (stored form)
     * @param sigmaStored  Player σ * 10000 (stored form)
     * @param rj      Opponent display rating
     * @param rdjStored Opponent RD * 10 (stored form)
     * @param score   Score scaled by 1e6 (1000000=win, 500000=draw, 0=loss)
     * @return newR   New display rating
     * @return newRdStored  New RD * 10
     * @return newSigmaStored New σ * 10000
     */
    function _glicko2Update(
        uint256 r,
        uint256 rdStored,
        uint256 sigmaStored,
        uint256 rj,
        uint256 rdjStored,
        uint256 score
    ) internal pure returns (uint256 newR, uint256 newRdStored, uint256 newSigmaStored) {
        // ----- Step 1: Convert to Glicko-2 internal scale (all × SCALE = 1e6) -----
        // μ = (r - 1500) / 173.7178  →  μ_scaled = (r - 1500) * 1e6 / 173.7178
        // We work signed for μ since it can be negative

        // rdStored is RD * 10, so real RD = rdStored / 10
        // φ_scaled = (rdStored / 10) * 1e6 / 173.7178 = rdStored * 1e5 / 173.7178
        // = rdStored * 1e6 / 1737.178  ≈ rdStored * 1e6 / 1737178 * 1000
        // Use: rdStored * 100000 / 173718  (where 173718 ≈ 173.7178 * 1000)

        int256 mu;
        {
            int256 rInt = int256(r);
            // μ_scaled = (r - 1500) * SCALE / 173.7178
            // = (r - 1500) * 1000000 / 173.7178
            // Multiply by 1e6 then divide by GLICKO2_SCALE/1e6 = 173.7178
            // GLICKO2_SCALE = 173717800 = 173.7178 * 1e6
            // so (r-1500)*1e6 / 173.7178 = (r-1500)*1e12 / GLICKO2_SCALE
            mu = (rInt - 1500) * int256(SCALE) * 1000000 / int256(GLICKO2_SCALE);
        }

        uint256 phi; // φ in SCALE units (1e6), always positive
        {
            // rdStored is RD*10, real RD = rdStored/10
            // φ_scaled = RD * 1e6 / 173.7178 = (rdStored/10) * 1e6 / 173.7178
            // = rdStored * 1e5 / 173.7178
            // = rdStored * 1e11 / GLICKO2_SCALE
            phi = rdStored * 100000000000 / GLICKO2_SCALE;
        }

        // φ for opponent
        int256 muj;
        {
            int256 rjInt = int256(rj);
            muj = (rjInt - 1500) * int256(SCALE) * 1000000 / int256(GLICKO2_SCALE);
        }

        uint256 phij;
        {
            phij = rdjStored * 100000000000 / GLICKO2_SCALE;
        }

        // Volatility σ: stored as σ * 10000, so real σ = sigmaStored / 10000
        // σ_scaled = sigmaStored * SCALE / 10000 = sigmaStored * 100
        uint256 sigma_s = sigmaStored * 100; // σ in SCALE units

        // ----- Step 2: Compute g(φⱼ) and E(μ, μⱼ, φⱼ) -----
        uint256 g_phij = _g(phij);
        int256 E_val = int256(_E(mu, muj, g_phij));

        // ----- Step 3: Estimated variance v -----
        // v = 1 / (g² * E * (1 - E))
        // All in SCALE units. g_phij, E_val are in SCALE.
        // numerator terms: g²/SCALE * E/SCALE * (SCALE-E)/SCALE  → divide by SCALE³
        uint256 g_sq = g_phij * g_phij / SCALE;             // g² scaled
        uint256 E_pos = uint256(E_val);
        uint256 one_minus_E = SCALE - E_pos;
        // inner = g_sq * E * (1 - E) / SCALE^2
        uint256 inner = g_sq * E_pos / SCALE * one_minus_E / SCALE;
        // v = SCALE / inner  (both in SCALE, so v is in SCALE)
        uint256 v;
        if (inner == 0) {
            // Degenerate case: no information, keep large v
            v = 100 * SCALE;
        } else {
            v = SCALE * SCALE / inner;
        }

        // ----- Step 4: Delta -----
        // Δ = v * g(φⱼ) * (s - E)  (in SCALE units)
        // score is in SCALE (1e6 = 1.0), E_val is in SCALE
        int256 score_s = int256(score);
        int256 delta;
        {
            // g_phij in SCALE, v in SCALE, (score_s - E_val) in SCALE
            // Δ_scaled = v/SCALE * g/SCALE * diff * SCALE  →  v * g * diff / SCALE^2
            int256 diff = score_s - E_val;
            delta = int256(v) * int256(g_phij) / int256(SCALE) * diff / int256(SCALE);
        }

        // ----- Step 5: Update volatility σ' (Illinois bisection, 10 iters) -----
        uint256 sigma_new = _updateVolatility(phi, sigma_s, v, delta);

        // ----- Step 6: Update RD -----
        // φ* = sqrt(φ² + σ'²)
        // φ' = 1 / sqrt(1/φ*² + 1/v)
        uint256 phi_star;
        {
            uint256 phi_sq   = phi * phi / SCALE;           // φ² in SCALE
            uint256 sigma_sq = sigma_new * sigma_new / SCALE; // σ'² in SCALE
            phi_star = _sqrt((phi_sq + sigma_sq) * SCALE);  // sqrt returns in SCALE
        }

        uint256 phi_new;
        {
            // 1/φ*² + 1/v  → (v + φ*²) / (φ*² * v)   all in SCALE
            uint256 phi_star_sq = phi_star * phi_star / SCALE;
            // denominator: φ*² * v / SCALE
            uint256 denom = phi_star_sq * v / SCALE;
            uint256 numer = v + phi_star_sq;  // both SCALE
            if (denom == 0 || numer == 0) {
                phi_new = phi_star;
            } else {
                // 1/φ'² = numer/denom  →  φ'² = denom/numer * SCALE
                // φ' = sqrt(denom * SCALE / numer)  →  sqrt(arg * SCALE)
                uint256 phi_new_sq = denom * SCALE / numer; // φ'² in SCALE
                phi_new = _sqrt(phi_new_sq * SCALE);
            }
        }

        // ----- Step 7: Update rating -----
        // μ' = μ + φ'² * g(φⱼ) * (s - E)   all in SCALE
        int256 mu_new;
        {
            uint256 phi_new_sq = phi_new * phi_new / SCALE;
            int256 adj = int256(phi_new_sq) * int256(g_phij) / int256(SCALE)
                         * (score_s - E_val) / int256(SCALE);
            mu_new = mu + adj;
        }

        // ----- Convert back to display scale -----
        // r' = μ' * 173.7178 + 1500
        // μ' is in SCALE (1e6 units), GLICKO2_SCALE = 173.7178 * 1e6
        // r' = μ'_scaled * GLICKO2_SCALE / 1e12 + 1500
        int256 newR_int = mu_new * int256(GLICKO2_SCALE) / int256(SCALE) / 1000000 + 1500;
        if (newR_int < int256(uint256(MIN_RATING))) newR_int = int256(uint256(MIN_RATING));
        if (newR_int > 65535) newR_int = 65535;
        newR = uint256(newR_int);

        // RD back: real RD = φ'_scaled * 173.7178 / 1e6
        //                   = phi_new * GLICKO2_SCALE / 1e12
        // stored as RD * 10
        uint256 newRD_display = phi_new * GLICKO2_SCALE / SCALE / 1000000;
        if (newRD_display < uint256(MIN_RD)) newRD_display = uint256(MIN_RD);
        if (newRD_display > 6553) newRD_display = 6553; // max for uint16 stored*10
        newRdStored = newRD_display * 10;

        // σ back: stored as σ * 10000
        // sigma_new is in SCALE → real σ = sigma_new / SCALE
        // stored = σ * 10000 = sigma_new * 10000 / SCALE = sigma_new / 100
        newSigmaStored = sigma_new / 100;
        if (newSigmaStored == 0) newSigmaStored = 1;
        if (newSigmaStored > 65535) newSigmaStored = 65535;
    }

    // -------------------------------------------------------------------------
    // Internal: Volatility update via Illinois bisection (Step 5)
    // -------------------------------------------------------------------------

    /**
     * @dev Solve f(x) = 0 for x where:
     *   f(x) = exp(x)(Δ² - φ² - v - exp(x)) / (2(φ² + v + exp(x))²) - (x - ln(σ²)) / τ²
     * Uses the Illinois variant of the bisection/secant method, 10 iterations.
     * All inputs and internal values are in SCALE (1e6) units.
     * @param phi     φ in SCALE
     * @param sigma_s σ in SCALE
     * @param v       v in SCALE
     * @param delta   Δ in SCALE (signed)
     * @return sigma_new  New σ in SCALE
     */
    function _updateVolatility(
        uint256 phi,
        uint256 sigma_s,
        uint256 v,
        int256 delta
    ) internal pure returns (uint256 sigma_new) {
        // Working variables (all in SCALE = 1e6)
        // φ² and Δ² in SCALE
        uint256 phi_sq   = phi * phi / SCALE;
        int256  delta_sq = delta * delta / int256(SCALE);

        // ln(σ²) = 2 * ln(σ)
        // We need ln(σ) with σ in SCALE. Use _ln which takes SCALE-scaled input.
        int256 ln_sigma_sq = 2 * _ln(sigma_s);  // in SCALE

        // Initial bracketing
        // A = ln(σ²) = ln_sigma_sq
        // B = initial upper bound:
        //   If Δ² > φ² + v: B = ln(Δ² - φ² - v)
        //   Else: iterate B = A - τ² until f(B) < 0
        int256 A = ln_sigma_sq;
        int256 B;

        int256 phi_sq_s  = int256(phi_sq);
        int256 v_s       = int256(v);

        if (delta_sq > phi_sq_s + v_s) {
            // Δ² - φ² - v > 0, can take ln
            int256 arg = delta_sq - phi_sq_s - v_s; // positive, SCALE
            B = _ln(uint256(arg));
        } else {
            // Find B by iterating down until f(B) < 0
            B = A - int256(TAU_SQ_SCALED);
            // Iterate up to 20 steps to find sign change
            for (uint256 k = 0; k < 20; k++) {
                int256 fB_inner = _fVol(B, phi_sq_s, v_s, delta_sq, ln_sigma_sq);
                if (fB_inner < 0) break;
                B = B - int256(TAU_SQ_SCALED);
            }
        }

        // Evaluate f at brackets
        int256 fA = _fVol(A, phi_sq_s, v_s, delta_sq, ln_sigma_sq);
        int256 fB = _fVol(B, phi_sq_s, v_s, delta_sq, ln_sigma_sq);

        // Illinois bisection — 10 iterations
        for (uint256 iter = 0; iter < 10; iter++) {
            // C = B - fB * (B - A) / (fB - fA)
            int256 denom = fB - fA;
            if (denom == 0) break;
            int256 C = B - fB * (B - A) / denom;
            int256 fC = _fVol(C, phi_sq_s, v_s, delta_sq, ln_sigma_sq);

            if ((fC < 0) == (fB < 0)) {
                // Illinois step: halve fA weight
                fA = fA / 2;
                B  = C;
                fB = fC;
            } else {
                A  = B;
                fA = fB;
                B  = C;
                fB = fC;
            }
        }

        // σ' = exp(A/2) in SCALE
        // A is ln(σ²) (SCALE), so A/2 = ln(σ), exp(A/2) = σ in SCALE
        int256 half_A = (A + B) / 4; // midpoint / 2 as final estimate of ln(σ)
        // exp returns SCALE-scaled result
        sigma_new = _expSigned(half_A);
        if (sigma_new == 0) sigma_new = sigma_s; // fallback
    }

    /**
     * @dev The volatility update function f(x).
     * f(x) = exp(x)*(Δ² - φ² - v - exp(x)) / (2*(φ² + v + exp(x))²) - (x - ln(σ²)) / τ²
     * All values SCALE-scaled. Returns SCALE-scaled result (signed).
     */
    function _fVol(
        int256 x,
        int256 phi_sq,
        int256 v,
        int256 delta_sq,
        int256 ln_sigma_sq
    ) internal pure returns (int256) {
        int256 ex = int256(_expSigned(x));     // e^x in SCALE
        int256 ex_scaled = ex;

        // numerator: ex * (Δ² - φ² - v - ex)
        int256 inner = delta_sq - phi_sq - v - ex_scaled;  // SCALE
        // ex * inner / SCALE to stay in SCALE
        int256 num = ex_scaled * inner / int256(SCALE);

        // denominator: 2 * (φ² + v + ex)²
        int256 base = phi_sq + v + ex_scaled;      // SCALE
        int256 base_sq = base * base / int256(SCALE); // SCALE
        int256 den = 2 * base_sq;                  // SCALE

        // term1 = num / (2 * base²) = num * SCALE / den  → SCALE
        int256 term1;
        if (den == 0) {
            term1 = 0;
        } else {
            term1 = num * int256(SCALE) / den;
        }

        // term2 = (x - ln(σ²)) / τ²
        // τ² = TAU_SQ_SCALED in SCALE units
        int256 term2 = (x - ln_sigma_sq) * int256(SCALE) / int256(TAU_SQ_SCALED);

        return term1 - term2;
    }

    // -------------------------------------------------------------------------
    // Internal: persist record after update
    // -------------------------------------------------------------------------

    function _persistRecord(
        PlayerRecord storage rec,
        address player,
        uint256 oldR,
        uint256 oldRdStored,
        uint256 newR,
        uint256 newRdStored,
        uint256 newSigmaStored,
        uint256 score
    ) internal {
        uint16 oldRating = uint16(oldR);
        uint16 newRating = uint16(newR);

        rec.rating      = newRating;
        rec.rd          = uint16(newRdStored);
        rec.sigma       = uint16(newSigmaStored);
        rec.gamesPlayed = uint16(rec.gamesPlayed + 1);

        if (score == 1000000) {
            rec.wins   = uint16(rec.wins + 1);
        } else if (score == 0) {
            rec.losses = uint16(rec.losses + 1);
        } else {
            rec.draws  = uint16(rec.draws + 1);
        }

        if (newRating > rec.peakRating) {
            rec.peakRating = newRating;
        }

        // Clamp delta to int16 for event
        int256 deltaFull = int256(newR) - int256(oldR);
        int16 emitDelta;
        if (deltaFull > int256(32767)) {
            emitDelta = type(int16).max;
        } else if (deltaFull < int256(-32768)) {
            emitDelta = type(int16).min;
        } else {
            emitDelta = int16(deltaFull);
        }

        emit RatingUpdated(player, oldRating, newRating, emitDelta, rec.gamesPlayed);

        uint16 oldRD  = uint16(oldRdStored);
        uint16 newRD  = uint16(newRdStored);
        if (oldRD != newRD) {
            emit RDUpdated(player, oldRD, newRD);
        }
    }

    // -------------------------------------------------------------------------
    // Internal: lazy-initialize a player record
    // -------------------------------------------------------------------------

    function _ensureInit(PlayerRecord storage rec) internal {
        if (rec.rating == 0) {
            rec.rating    = DEFAULT_RATING;
            rec.rd        = uint16(DEFAULT_RD) * 10;  // 3500
            rec.sigma     = uint16(DEFAULT_SIGMA) * 100; // 600
            rec.peakRating = DEFAULT_RATING;
        }
    }

    // -------------------------------------------------------------------------
    // Math helpers
    // -------------------------------------------------------------------------

    /**
     * @dev g(φ) = 1 / sqrt(1 + 3φ²/π²), all SCALE-scaled.
     * @param phi_scaled φ in SCALE (1e6)
     * @return result in SCALE (1e6)
     */
    function _g(uint256 phi_scaled) internal pure returns (uint256) {
        // 3 * φ² / π²
        // phi² in SCALE: phi_scaled * phi_scaled / SCALE
        uint256 phi_sq = phi_scaled * phi_scaled / SCALE;
        // 3 * phi_sq / (PI_SQ_SCALED / SCALE) = 3 * phi_sq * SCALE / PI_SQ_SCALED
        uint256 three_phi_sq_over_pi_sq = 3 * phi_sq * SCALE / PI_SQ_SCALED;
        // 1 + 3φ²/π²  in SCALE
        uint256 one_plus = SCALE + three_phi_sq_over_pi_sq;
        // sqrt(one_plus): one_plus is in SCALE, so sqrt(one_plus * SCALE) / SCALE
        uint256 sq = _sqrt(one_plus * SCALE); // result in SCALE
        if (sq == 0) return SCALE;
        // g = SCALE / sq (since g = 1/sqrt(...) and sqrt output is SCALE-scaled)
        return SCALE * SCALE / sq;
    }

    /**
     * @dev E(μ, μⱼ, g_phij) = 1 / (1 + exp(-g(φⱼ)(μ - μⱼ)))
     * @param mu      μ in SCALE (signed)
     * @param muj     μⱼ in SCALE (signed)
     * @param g_phij  g(φⱼ) in SCALE
     * @return result in SCALE (1e6), clamped to [1, SCALE-1]
     */
    function _E(int256 mu, int256 muj, uint256 g_phij) internal pure returns (uint256) {
        // exponent = -g(φⱼ)(μ - μⱼ) in SCALE
        int256 diff = mu - muj;   // SCALE
        // g_phij * diff / SCALE → SCALE
        int256 exponent = -int256(g_phij) * diff / int256(SCALE);
        uint256 ex = _expSigned(exponent);  // in SCALE
        // E = 1 / (1 + ex) = SCALE / (SCALE + ex) * SCALE
        uint256 denom = SCALE + ex;
        if (denom == 0) return SCALE / 2;
        uint256 result = SCALE * SCALE / denom;
        if (result == 0) result = 1;
        if (result >= SCALE) result = SCALE - 1;
        return result;
    }

    /**
     * @dev Integer square root (Babylonian method).
     * @param x  Input — should be passed as value * SCALE when result needs SCALE scaling.
     * @return y  Floor sqrt of x (not SCALE-scaled on its own; caller controls scaling).
     */
    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    /**
     * @dev 7-term Taylor series exp(x) for x in SCALE units.
     * Accurate for |x| < 2e6 (covers all realistic Glicko-2 exponents).
     * @param x  Exponent in SCALE (1e6), signed.
     * @return   exp(x) in SCALE (1e6). Clamped to [1, 20 * SCALE].
     */
    function _expSigned(int256 x) internal pure returns (uint256) {
        // Clamp to prevent overflow in Taylor series
        if (x > 3000000) return 20 * SCALE;   // e^3 ≈ 20.09
        if (x < -3000000) return 1;            // e^-3 ≈ 0.05, rounds to 0 in 1e6

        // We need non-negative base for Taylor; handle sign by inversion
        bool negative = x < 0;
        uint256 ax = negative ? uint256(-x) : uint256(x);

        // exp(ax) via Taylor: 1 + x + x²/2 + x³/6 + x⁴/24 + x⁵/120 + x⁶/720
        // Each term computed in SCALE units
        uint256 S   = SCALE;              // 1 in SCALE
        uint256 xp  = ax;                 // x in SCALE (term 1 numerator)
        uint256 t   = xp;                 // x^1 / 1!
        S += t;

        t = t * ax / SCALE / 2;           // x^2 / 2!
        S += t;

        t = t * ax / SCALE / 3;           // x^3 / 3!
        S += t;

        t = t * ax / SCALE / 4;           // x^4 / 4!
        S += t;

        t = t * ax / SCALE / 5;           // x^5 / 5!
        S += t;

        t = t * ax / SCALE / 6;           // x^6 / 6!
        S += t;

        if (negative) {
            // exp(-|x|) = 1 / exp(|x|) = SCALE^2 / S (result in SCALE)
            if (S == 0) return 1;
            return SCALE * SCALE / S;
        }
        return S;
    }

    /**
     * @dev Natural logarithm via series: ln(x) for x in SCALE (1e6).
     * Uses the identity ln(x) = ln(m * 2^k) = k*ln2 + ln(m) where m ∈ [1, 2).
     * Then ln(m) via Padé approximant: ln(m) ≈ 2*(t + t³/3 + t⁵/5) where t = (m-1)/(m+1).
     * @param x  Input in SCALE (must be > 0)
     * @return   ln(x) in SCALE (signed, returned as int256)
     */
    function _ln(uint256 x) internal pure returns (int256) {
        require(x > 0, "ln(0)");

        // ln2 * SCALE = 693147
        int256 LN2 = 693147;

        // Normalize x into [SCALE, 2*SCALE) by tracking power of 2
        // (equivalent to extracting integer part of log2)
        int256 k = 0;
        uint256 m = x; // m will be in SCALE once normalized

        // Scale up if m < SCALE
        while (m < SCALE) {
            m = m * 2;
            k--;
        }
        // Scale down if m >= 2*SCALE
        while (m >= 2 * SCALE) {
            m = m / 2;
            k++;
        }
        // Now m ∈ [SCALE, 2*SCALE), i.e. m/SCALE ∈ [1, 2)

        // Padé: ln(m/SCALE) = 2*(t + t³/3 + t⁵/5) where t = (m - SCALE) / (m + SCALE)
        // t is in SCALE
        int256 ms = int256(m);
        int256 S  = int256(SCALE);
        int256 t  = (ms - S) * S / (ms + S); // SCALE

        int256 t2  = t  * t  / S;    // t² in SCALE
        int256 t3  = t2 * t  / S;    // t³
        int256 t5  = t3 * t2 / S;    // t⁵

        int256 series = t + t3 / 3 + t5 / 5;  // in SCALE

        int256 ln_m = 2 * series;  // ln(m/SCALE) in SCALE

        return k * LN2 + ln_m;
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function getRating(address player) external view returns (uint16) {
        PlayerRecord storage rec = _records[player];
        return rec.rating == 0 ? DEFAULT_RATING : rec.rating;
    }

    /**
     * @notice Returns the player's Rating Deviation (display value, not stored*10).
     */
    function getRD(address player) external view returns (uint16) {
        PlayerRecord storage rec = _records[player];
        uint16 stored = rec.rd == 0 ? uint16(DEFAULT_RD * 10) : rec.rd;
        return stored / 10;
    }

    /**
     * @notice Returns the player's volatility stored value (σ * 10000).
     */
    function getSigma(address player) external view returns (uint16) {
        PlayerRecord storage rec = _records[player];
        return rec.sigma == 0 ? uint16(DEFAULT_SIGMA * 100) : rec.sigma;
    }

    function getRecord(address player)
        external
        view
        returns (
            uint16 rating,
            uint16 rd,
            uint16 gamesPlayed,
            uint16 wins,
            uint16 losses,
            uint16 draws,
            uint16 peakRating
        )
    {
        PlayerRecord storage rec = _records[player];
        rating      = rec.rating == 0 ? DEFAULT_RATING : rec.rating;
        uint16 rdStored = rec.rd == 0 ? uint16(DEFAULT_RD * 10) : rec.rd;
        rd          = rdStored / 10;
        gamesPlayed = rec.gamesPlayed;
        wins        = rec.wins;
        losses      = rec.losses;
        draws       = rec.draws;
        peakRating  = rec.peakRating == 0 ? rating : rec.peakRating;
    }

    /**
     * @notice Return a human-readable rank tier based on current rating.
     *         Beginner < 1000, Intermediate 1000-1399, Advanced 1400-1799,
     *         Expert 1800-2199, Master >= 2200.
     */
    function getRank(address player) external view returns (string memory) {
        PlayerRecord storage rec = _records[player];
        uint16 r = rec.rating == 0 ? DEFAULT_RATING : rec.rating;

        if (r < 1000) return "Beginner";
        if (r < 1400) return "Intermediate";
        if (r < 1800) return "Advanced";
        if (r < 2200) return "Expert";
        return "Master";
    }

    /**
     * @notice Returns true if the player's RD is above 100 (rating is provisional).
     *         Stored rd > 1000 means display RD > 100.
     */
    function isProvisional(address player) external view returns (bool) {
        PlayerRecord storage rec = _records[player];
        uint16 stored = rec.rd == 0 ? uint16(DEFAULT_RD * 10) : rec.rd;
        return stored > 1000;
    }
}
