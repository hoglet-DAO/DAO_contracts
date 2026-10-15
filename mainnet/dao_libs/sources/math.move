module dao_libs::math {
    use std::error;

    const PRECISION: u256 = 1_000_000_000_000_000_000;

    /// Calculates the rebase debt given a locked amount and the accumulated rebase per share.
    public fun calculate_rebase_debt(amount: u64, acc_rebase: u128): u128 {
        (((amount as u256) * (acc_rebase as u256) / PRECISION) as u128)
    }

    /// Adds `amount` to a Synthetix-style accumulated-per-share accumulator:
    /// acc' = acc + amount * PRECISION / total_locked.
    /// Callers must guard total_locked > 0 && amount > 0 (same guard as the
    /// inline code this replaces in legacy::inject_rebase / inject_bribes).
    public fun add_per_share(amount: u64, total_locked: u64, current_acc: u128): u128 {
        current_acc + (((amount as u256) * PRECISION / (total_locked as u256)) as u128)
    }

    /// Computes (a * b) / c in u128 and truncates the result to u64.
    /// Replaces the repeated
    /// `(((a as u128) * (b as u128)) / (c as u128)) as u64` pattern
    /// (legacy voting power, herald quorum, restore bribe share).
    /// Aborts on c == 0, exactly like the inline divisions it replaces.
    public fun mul_div_u64(a: u64, b: u64, c: u64): u64 {
        (((a as u128) * (b as u128) / (c as u128)) as u64)
    }

    /// Computes (a * b) / c entirely in u128. For truncated u64 results cast
    /// at the call site (`as u64`), e.g. bribe shares in restore where vote
    /// powers are u128 (zeal::get_user_vote_power / zeal::get_gauge_total_votes).
    /// Aborts on c == 0, exactly like the inline divisions it replaces.
    public fun mul_div_u128(a: u128, b: u128, c: u128): u128 {
        a * b / c
    }

    /// Pending rebase for a veToken: earned (locked * acc / PRECISION) minus
    /// the stored debt, floored at 0. Lives in dao_libs so the math does not
    /// count against the core package size (audit10 UI review).
    public fun rebase_pending(locked: u64, acc: u128, debt: u128): u64 {
        let earned = calculate_rebase_debt(locked, acc);
        if (earned > debt) { ((earned - debt) as u64) } else { 0 }
    }

    /// Computes the dynamic proposal threshold based on the total supply and the threshold PPM.
    /// Clamps the minimum threshold to 1 to prevent rounding errors from bricking DAO creation.
    public fun compute_dynamic_threshold(current_supply: u128, threshold_ppm: u64): u64 {
        let dynamic_threshold = (((current_supply * (threshold_ppm as u128)) / 1000000) as u64);
        if (dynamic_threshold == 0) { 1 } else { dynamic_threshold }
    }

    /// Applies a Basis Points (BPS) percentage to an amount. 10000 BPS = 100%.
    public fun apply_bps(amount: u64, bps: u64): u64 {
        (((amount as u128) * (bps as u128) / 10000) as u64)
    }

    /// Applies a Parts Per Million (PPM) percentage to an amount. 1_000_000 PPM = 100%.
    public fun apply_ppm(amount: u128, ppm: u64): u64 {
        (((amount * (ppm as u128)) / 1000000) as u64)
    }

    /// Asserts that a value lies within [min, max] inclusive.
    public fun assert_bounds(value: u64, min: u64, max: u64, err_code: u64) {
        assert!(value >= min && value <= max, error::invalid_argument(err_code));
    }

    /// Calculates Curve/Velodrome-style working balance with boost:
    /// working = actual * (10000 + boost_bps) / 10000
    public fun calculate_boosted_working_balance(actual_balance: u128, boost_bps: u64): u128 {
        actual_balance * (10000 + (boost_bps as u128)) / 10000
    }

    /// Computes the dynamic quorum from recent participations:
    /// 50% of average recent participation, clamped to [100%, 200%] of default_quorum.
    /// Clamped to at least default_quorum so the quorum can scale up during surges
    /// but never falls below the baseline configured quorum (M-01).
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

    // ============================ TESTS ============================

    #[test]
    fun test_mul_div() {
        assert!(mul_div_u64(2, 3, 6) == 1, 1);
        assert!(mul_div_u64(10, 10, 4) == 25, 2);
        assert!(mul_div_u128(100, 3, 7) == 42, 3);
    }

    #[test]
    #[expected_failure]
    fun test_mul_div_div_by_zero() {
        mul_div_u64(1, 1, 0);
    }

    #[test]
    fun test_bps_ppm() {
        assert!(apply_bps(1000, 500) == 50, 11);
        assert!(apply_bps(1000, 10000) == 1000, 12);
        assert!(apply_ppm(1_000_000, 1_000_000) == 1_000_000, 13);
    }

    #[test]
    fun test_threshold_min_one() {
        assert!(compute_dynamic_threshold(0, 1000) == 1, 21); // clamps to 1
        assert!(compute_dynamic_threshold(1_000_000, 10000) == 10_000, 22); // 1%
    }

    #[test]
    fun test_assert_bounds_ok() {
        assert_bounds(5, 1, 10, 99);
    }

    #[test]
    #[expected_failure]
    fun test_assert_bounds_out_of_range() {
        assert_bounds(11, 1, 10, 99);
    }

    #[test]
    fun test_rebase_pending() {
        assert!(rebase_pending(100, 1_000_000_000_000_000_000, 40) == 60, 31);
        assert!(rebase_pending(100, 1_000_000_000_000_000_000, 200) == 0, 32);
    }

    #[test]
    fun test_add_per_share() {
        assert!(add_per_share(100, 1000, 0) == 100_000_000_000_000_000, 41);
    }

    #[test]
    fun test_boosted_working_balance() {
        assert!(calculate_boosted_working_balance(1000, 500) == 1050, 51);
        assert!(calculate_boosted_working_balance(1000, 0) == 1000, 52);
    }

    #[test]
    fun test_dynamic_quorum() {
        let empty = std::vector::empty<u128>();
        assert!(calculate_dynamic_quorum(&empty, 1000) == 1000, 61); // no data -> default

        let p = std::vector::empty<u128>();
        std::vector::push_back(&mut p, 1000); // avg 1000 -> raw 500 (below floor 1000) -> clamped to floor 1000
        assert!(calculate_dynamic_quorum(&p, 1000) == 1000, 62);

        let p2 = std::vector::empty<u128>();
        std::vector::push_back(&mut p2, 3000); // avg 3000 -> raw 1500 (within [1000, 2000]) -> 1500
        assert!(calculate_dynamic_quorum(&p2, 1000) == 1500, 63);

        let q = std::vector::empty<u128>();
        std::vector::push_back(&mut q, 100_000); // huge -> clamped to ceiling 2000
        assert!(calculate_dynamic_quorum(&q, 1000) == 2000, 64);
    }
}

