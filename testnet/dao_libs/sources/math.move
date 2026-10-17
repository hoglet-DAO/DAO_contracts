module dao_libs::math {
    use std::error;

    const PRECISION: u256 = 1_000_000_000_000_000_000;

    // Calculates the rebase debt given a locked amount and the accumulated rebase per share.
    public fun calculate_rebase_debt(amount: u64, acc_rebase: u128): u128 {
        (((amount as u256) * (acc_rebase as u256) / PRECISION) as u128)
    }

    // Adds `amount` to a Synthetix-style accumulated-per-share accumulator:
    // acc' = acc + amount * PRECISION / total_locked.
    // Callers must guard total_locked > 0 && amount > 0 (same guard as the
    // inline code this replaces in legacy::inject_rebase / inject_bribes).
    public fun add_per_share(amount: u64, total_locked: u64, current_acc: u128): u128 {
        current_acc + (((amount as u256) * PRECISION / (total_locked as u256)) as u128)
    }

    // Computes (a * b) / c in u128 and truncates the result to u64.
    // Replaces the repeated
    // `(((a as u128) * (b as u128)) / (c as u128)) as u64` pattern
    // (legacy voting power, herald quorum, restore bribe share).
    // Aborts on c == 0, exactly like the inline divisions it replaces.
    public fun mul_div_u64(a: u64, b: u64, c: u64): u64 {
        (((a as u128) * (b as u128) / (c as u128)) as u64)
    }

    // Computes (a * b) / c entirely in u128. For truncated u64 results cast
    // at the call site (`as u64`), e.g. bribe shares in restore where vote
    // powers are u128 (zeal::get_user_vote_power / zeal::get_gauge_total_votes).
    // Aborts on c == 0, exactly like the inline divisions it replaces.
    public fun mul_div_u128(a: u128, b: u128, c: u128): u128 {
        a * b / c
    }

    // Pending rebase for a veToken: earned (locked * acc / PRECISION) minus
    // the stored debt, floored at 0. Lives in dao_libs so the math does not
    // count against the core package size (audit10 UI review).
    public fun rebase_pending(locked: u64, acc: u128, debt: u128): u64 {
        let earned = calculate_rebase_debt(locked, acc);
        if (earned > debt) { ((earned - debt) as u64) } else { 0 }
    }

    // Computes the dynamic proposal threshold based on the total supply and the threshold PPM.
    // Clamps the minimum threshold to 1 to prevent rounding errors from bricking DAO creation.
    public fun compute_dynamic_threshold(current_supply: u128, threshold_ppm: u64): u64 {
        let dynamic_threshold = (((current_supply * (threshold_ppm as u128)) / 1000000) as u64);
        if (dynamic_threshold == 0) { 1 } else { dynamic_threshold }
    }

    // Applies a Basis Points (BPS) percentage to an amount. 10000 BPS = 100%.
    public fun apply_bps(amount: u64, bps: u64): u64 {
        (((amount as u128) * (bps as u128) / 10000) as u64)
    }

    // Calculates the weekly emission decay for Jubilee.
    public fun calculate_decayed_emission(weekly_emission: u64, decay_bps: u64, tail_emission: u64): u64 {
        let decay = apply_bps(weekly_emission, decay_bps);
        let next_emission = if (weekly_emission > decay) {
            weekly_emission - decay
        } else {
            0
        };
        if (next_emission < tail_emission) {
            next_emission = tail_emission;
        };
        next_emission
    }

    // Applies a Parts Per Million (PPM) percentage to an amount. 1_000_000 PPM = 100%.
    public fun apply_ppm(amount: u128, ppm: u64): u64 {
        (((amount * (ppm as u128)) / 1000000) as u64)
    }

    // Asserts that a value lies within [min, max] inclusive.
    public fun assert_bounds(value: u64, min: u64, max: u64, err_code: u64) {
        assert!(value >= min && value <= max, error::invalid_argument(err_code));
    }

    // Calculates Curve/Velodrome-style working balance with boost:
    // working = actual * (10000 + boost_bps) / 10000
    public fun calculate_boosted_working_balance(actual_balance: u128, boost_bps: u64): u128 {
        actual_balance * (10000 + (boost_bps as u128)) / 10000
    }

    // Computes the dynamic quorum from recent participations:
    // 50% of average recent participation, clamped to [100%, 200%] of default_quorum.
    // Clamped to at least default_quorum so the quorum can scale up during surges
    // but never falls below the baseline configured quorum (M-01).
    public fun calculate_dynamic_quorum(participations: &vector<u128>, default_quorum: u64): u64 {
        let len = std::vector::length(participations);
        if (len == 0) {
            return default_quorum
        };

        let sum: u128 = 0;
        let i = 0;
        while (i < len) {
            sum = sum + *std::vector::borrow(participations, i);
            i = i + 1;
        };

        let avg = sum / (len as u128);
        let raw_dynamic_quorum = avg / 2;
        
        let max_ceiling = ((default_quorum as u128) * 200) / 100;
        let min_floor = (default_quorum as u128);

        let clamped_quorum = if (raw_dynamic_quorum > max_ceiling) {
            max_ceiling
        } else if (raw_dynamic_quorum < min_floor) {
            min_floor
        } else {
            raw_dynamic_quorum
        };

        (clamped_quorum as u64)
    }

    // Computes Synthetix-style reward per token accumulated over elapsed time:
    // rpt' = stored_rpt + (time_delta * REWARD_SCALE * reward_rate) / working_supply
    public fun calculate_reward_per_token(
        stored_rpt: u128,
        last_update_time: u64,
        period_finish: u64,
        current_time: u64,
        reward_rate: u128,
        working_supply: u128,
        reward_scale: u128,
    ): u128 {
        let last_time_applicable = if (current_time < period_finish) {
            current_time
        } else {
            period_finish
        };

        if (working_supply == 0 || last_time_applicable <= last_update_time) {
            return stored_rpt
        };

        let time_delta = ((last_time_applicable - last_update_time) as u128);
        let reward_increment = mul_div_u128(time_delta * reward_scale, reward_rate, working_supply);
        stored_rpt + reward_increment
    }

    // Computes newly earned rewards for an account:
    // earned = (working_balance * (current_rpt - user_paid_rpt)) / REWARD_SCALE
    public fun calculate_user_earned_rewards(
        current_rpt: u128,
        user_paid_rpt: u128,
        working_balance: u128,
        stored_rewards: u128,
        reward_scale: u128,
    ): u128 {
        if (current_rpt <= user_paid_rpt) {
            return stored_rewards
        };
        let newly_earned = mul_div_u128(working_balance, current_rpt - user_paid_rpt, reward_scale);
        stored_rewards + newly_earned
    }
    // Validates DAO charter genesis parameters.
    public fun validate_charter_genesis(
        voting_delay: u64,
        voting_period: u64,
        timelock_delay: u64,
        quorum_numerator: u64,
        quorum_denominator: u64,
        super_quorum_threshold: u64,
        proposal_threshold: u64,
    ) {
        assert!(voting_delay >= 43200 && voting_delay <= 2592000, error::invalid_argument(1));
        assert!(voting_period >= 86400 && voting_period <= 2592000, error::invalid_argument(2));
        assert!(timelock_delay >= 43200 && timelock_delay <= 2592000, error::invalid_argument(1));
        assert!(quorum_numerator > 0 && quorum_numerator <= quorum_denominator, error::invalid_argument(3));
        assert!(quorum_numerator * 100 / quorum_denominator >= 1, error::invalid_argument(3));
        assert!(super_quorum_threshold > 0 && super_quorum_threshold <= quorum_denominator, error::invalid_argument(3));
        assert!(super_quorum_threshold * 100 / quorum_denominator >= 50, error::invalid_argument(3));
        assert!(proposal_threshold > 0, error::invalid_argument(4));
    }

    // Validates a configuration value for a DAO charter update.
    public fun validate_charter_config(
        config_key: u8,
        config_value: u64,
        quorum_numerator: u64,
        quorum_denominator: u64,
        super_quorum_threshold: u64,
        proposal_threshold: u64,
    ) {
        if (config_key == 0) {
            assert_bounds(config_value, 1, quorum_denominator, 3);
            assert!(config_value * 100 / quorum_denominator >= 50, error::invalid_argument(3));
        } else if (config_key == 1) {
            assert_bounds(config_value, 1, quorum_denominator, 3);
            assert!(config_value * 100 / quorum_denominator >= 1, error::invalid_argument(3));
        } else if (config_key == 2) {
            assert!(config_value >= quorum_numerator && config_value >= super_quorum_threshold, error::invalid_argument(3));
            assert!(quorum_numerator * 100 / config_value >= 1, error::invalid_argument(3));
            assert!(super_quorum_threshold * 100 / config_value >= 50, error::invalid_argument(3));
        } else if (config_key == 3) {
            assert_bounds(config_value, 0, 2592000, 1);
        } else if (config_key == 4 || config_key == 7) {
            assert_bounds(config_value, 43200, 2592000, 1);
        } else if (config_key == 5 || config_key == 8) {
            assert_bounds(config_value, 86400, 2592000, 2);
        } else if (config_key == 6) {
            assert!(config_value > 0, error::invalid_argument(4));
            assert!(config_value <= proposal_threshold * 10, error::invalid_argument(4));
        } else {
            abort error::invalid_argument(1)
        };
    }

    // Validates factory default parameters set by the admin.
    public fun validate_factory_default(
        config_key: u8,
        value: u64,
        quorum_num: u64,
        quorum_den: u64,
        super_quorum: u64,
    ) {
        if (config_key == 0) {
            assert_bounds(value, 1, quorum_den, 21);
            assert!(value * 100 / quorum_den >= 50, error::invalid_argument(21));
        } else if (config_key == 1) {
            assert_bounds(value, 1, quorum_den, 21);
        } else if (config_key == 2) {
            assert!(value >= quorum_num && value >= super_quorum, error::invalid_argument(21));
        } else if (config_key == 3) {
            assert_bounds(value, 0, 2592000, 24);
        } else if (config_key == 4 || config_key == 7) {
            assert_bounds(value, 43200, 2592000, if (config_key == 4) 18 else 22);
        } else if (config_key == 5) {
            assert_bounds(value, 86400, 2592000, 19);
        } else if (config_key == 6) {
            assert_bounds(value, 1, 1_000_000, 20);
        } else if (config_key == 8) {
            assert_bounds(value, 86400, 31536000, 26);
        } else if (config_key == 9) {
            assert_bounds(value, 0, 500, 7);
        } else if (config_key == 10 || config_key == 12) {
            assert_bounds(value, 0, 1_000_000, 23);
        } else if (config_key == 11) {
            assert_bounds(value, 8000, 10000, 8);
        } else {
            abort error::invalid_argument(16)
        };
    }

    // ------------------------------------------------------------------
    // Tests - #[test] functions are stripped from the deploy bytecode.
    // ------------------------------------------------------------------

    #[test]
    fun test_mul_div() {
        assert!(mul_div_u64(10, 3, 2) == 15, 1);
        assert!(mul_div_u64(1, 1, 1) == 1, 2);
        assert!(mul_div_u64(1_000_000, 10, 100) == 100_000, 3);
        assert!(mul_div_u128(10, 3, 2) == 15, 4);
    }

    #[test]
    fun test_apply_bps_and_ppm() {
        assert!(apply_bps(1000, 500) == 50, 1);            // 5%
        assert!(apply_bps(1000, 10000) == 1000, 2);        // 100%
        assert!(apply_ppm(1_000_000, 137) == 137, 3);      // 137 ppm
        assert!(apply_ppm(1_000_000, 1_000_000) == 1_000_000, 4);
    }

    #[test]
    fun test_compute_dynamic_threshold() {
        // 0.0137% of 1,000,000 = 137
        assert!(compute_dynamic_threshold(1_000_000, 137) == 137, 1);
        // rounds down to 0 -> clamped to 1
        assert!(compute_dynamic_threshold(100, 1) == 1, 2);
        // supply 0 -> clamped to 1
        assert!(compute_dynamic_threshold(0, 137) == 1, 3);
    }

    #[test]
    fun test_rebase_debt_and_pending() {
        // PRECISION = 1e18, so acc == 1e18 means debt == locked amount.
        assert!(calculate_rebase_debt(100, 1_000_000_000_000_000_000) == 100, 1);
        assert!(rebase_pending(100, 1_000_000_000_000_000_000, 40) == 60, 2);
        // earned <= debt -> floored at 0
        assert!(rebase_pending(100, 1_000_000_000_000_000_000, 100) == 0, 3);
        assert!(rebase_pending(100, 1_000_000_000_000_000_000, 500) == 0, 4);
    }

    #[test]
    fun test_add_per_share() {
        // 100 * 1e18 / 1000 = 1e17
        assert!(add_per_share(100, 1000, 0) == 100_000_000_000_000_000, 1);
        assert!(add_per_share(0, 1000, 5) == 5, 2);
    }

    #[test]
    fun test_calculate_decayed_emission() {
        assert!(calculate_decayed_emission(1000, 100, 0) == 990, 1);   // 1% decay
        assert!(calculate_decayed_emission(1000, 100, 995) == 995, 2); // floor at tail
        assert!(calculate_decayed_emission(1000, 10000, 0) == 0, 3);   // 100% decay
    }

    #[test]
    fun test_boosted_working_balance() {
        assert!(calculate_boosted_working_balance(1000, 0) == 1000, 1);      // no boost
        assert!(calculate_boosted_working_balance(1000, 5000) == 1500, 2);   // +50%
    }

    #[test]
    fun test_calculate_dynamic_quorum() {
        let empty = std::vector::empty<u128>();
        assert!(calculate_dynamic_quorum(&empty, 100) == 100, 1); // empty -> default

        // avg 2000 -> raw 1000, clamped to ceiling 200 (2x default)
        let high = std::vector::empty<u128>();
        std::vector::push_back(&mut high, 2000);
        assert!(calculate_dynamic_quorum(&high, 100) == 200, 2);

        // avg 50 -> raw 25 < floor 100 -> 100
        let low = std::vector::empty<u128>();
        std::vector::push_back(&mut low, 50);
        assert!(calculate_dynamic_quorum(&low, 100) == 100, 3);

        // avg 300 -> raw 150, within [100, 200]
        let mid = std::vector::empty<u128>();
        std::vector::push_back(&mut mid, 300);
        assert!(calculate_dynamic_quorum(&mid, 100) == 150, 4);
    }

    #[test]
    fun test_reward_math() {
        // working_supply == 0 -> stored unchanged
        assert!(calculate_reward_per_token(7, 0, 100, 50, 1000, 0, 1) == 7, 1);
        // delta 100, rate 10, scale 1, supply 100 -> +10
        assert!(calculate_reward_per_token(0, 0, 1000, 100, 10, 100, 1) == 10, 2);

        // earned = balance * (rpt - paid) / scale = 100 * 5 / 1 = 500, + stored 5
        assert!(calculate_user_earned_rewards(15, 10, 100, 5, 1) == 505, 3);
        // current <= paid -> stored unchanged
        assert!(calculate_user_earned_rewards(10, 10, 100, 5, 1) == 5, 4);
    }

    #[test]
    fun test_assert_bounds_ok() {
        assert_bounds(1, 1, 10, 99);
        assert_bounds(5, 1, 10, 99);
        assert_bounds(10, 1, 10, 99);
    }

    #[test]
    #[expected_failure(abort_code = 0x10063)] // invalid_argument(99)
    fun test_assert_bounds_abort() {
        assert_bounds(11, 1, 10, 99);
    }

    #[test]
    fun test_validate_charter_genesis_ok() {
        validate_charter_genesis(43200, 86400, 43200, 7, 100, 73, 137);
    }

    #[test]
    #[expected_failure(abort_code = 0x10001)] // invalid_argument(1) - voting_delay
    fun test_validate_charter_genesis_bad_delay() {
        validate_charter_genesis(1, 86400, 43200, 7, 100, 73, 137);
    }

    #[test]
    #[expected_failure(abort_code = 0x10004)] // invalid_argument(4) - proposal_threshold
    fun test_validate_charter_genesis_zero_threshold() {
        validate_charter_genesis(43200, 86400, 43200, 7, 100, 73, 0);
    }

    #[test]
    #[expected_failure(abort_code = 0x10010)] // invalid_argument(16) - unknown factory key
    fun test_validate_factory_default_unknown_key() {
        validate_factory_default(99, 1, 7, 100, 73);
    }
}
