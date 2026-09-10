module dao_factory::math {

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
}
