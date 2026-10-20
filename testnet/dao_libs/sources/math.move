module dao_libs::math {
    use std::error;
    use std::vector;
    use std::option;
    use std::bcs;
    use supra_framework::account;
    use supra_framework::object;

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
        (((a as u256) * (b as u256) / (c as u256)) as u128)
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

    // --- Governance & Protocol Optimization Helpers ---

    // Validates gauge voting inputs and allocates vote powers proportionally
    public fun compute_gauge_vote_allocations(
        power: u128,
        gauge_ids: &vector<u64>,
        weights: &vector<u64>,
        err_invalid_weights: u64,
        err_invalid_gauge: u64,
    ): (vector<u128>, u128) {
        let len = vector::length(gauge_ids);
        assert!(len == vector::length(weights) && len > 0, error::invalid_argument(err_invalid_weights));

        let total_weight: u128 = 0;
        let seen = vector::empty<u64>();
        let i = 0;
        while (i < len) {
            let gid = *vector::borrow(gauge_ids, i);
            let w = *vector::borrow(weights, i);
            assert!(w > 0, error::invalid_argument(err_invalid_weights));
            assert!(!vector::contains(&seen, &gid), error::invalid_argument(err_invalid_gauge));
            vector::push_back(&mut seen, gid);
            total_weight = total_weight + (w as u128);
            i = i + 1;
        };
        assert!(total_weight > 0, error::invalid_argument(err_invalid_weights));

        let powers = vector::empty<u128>();
        let total_allocated: u128 = 0;
        i = 0;
        while (i < len) {
            let w = (*vector::borrow(weights, i) as u128);
            let allocated = (power * w) / total_weight;
            total_allocated = total_allocated + allocated;
            vector::push_back(&mut powers, allocated);
            i = i + 1;
        };
        (powers, total_allocated)
    }

    // Validates timelock proposal execution conditions
    public fun validate_proposal_execution(
        eta: u64,
        grace_period: u64,
        executed: bool,
        canceled: bool,
        total_participation: u64,
        quorum_required: u64,
        for_votes: u64,
        against_votes: u64,
        now: u64,
        err_not_ready: u64,
        err_expired: u64,
        err_executed: u64,
        err_canceled: u64,
        err_not_succeeded: u64,
        err_defeated: u64,
    ) {
        assert!(eta != 0 && now >= eta, error::invalid_state(err_not_ready));
        assert!(now <= eta + grace_period, error::invalid_state(err_expired));
        assert!(!executed, error::invalid_state(err_executed));
        assert!(!canceled, error::invalid_state(err_canceled));
        assert!(total_participation >= quorum_required, error::invalid_state(err_not_succeeded));
        assert!(for_votes > against_votes, error::invalid_state(err_defeated));
    }

    // Validates standard proposal parameters (propose_standard)
    public fun validate_standard_proposal_params(
        proposal_type: u8,
        action_recipient: address,
        action_amount: u64,
        action_config_key: u8,
        action_target_address: address,
        err_invalid: u64,
    ): (address, address, bool) {
        assert!(
            proposal_type == 1 || proposal_type == 2 || proposal_type == 3 ||
            proposal_type == 4 || proposal_type == 5 || proposal_type == 6 ||
            proposal_type == 7 || proposal_type == 9,
            error::invalid_argument(err_invalid)
        );
        let is_super_quorum = (
            proposal_type == 2 || proposal_type == 4 ||
            proposal_type == 6 || proposal_type == 9
        );
        let derived_target = if (proposal_type == 1) { action_recipient } else { action_target_address };
        let derived_asset = if (proposal_type == 1) { action_target_address } else { @0x0 };

        if (proposal_type == 1) {
            assert!(action_recipient != @0x0 && action_amount > 0, error::invalid_argument(err_invalid));
        } else if (proposal_type == 2) {
            assert!(
                action_config_key <= 11 || (action_config_key >= 20 && action_config_key <= 27),
                error::invalid_argument(err_invalid)
            );
        };
        (derived_target, derived_asset, is_super_quorum)
    }

    // Computes lock extension end epoch with boundaries
    public fun calculate_extend_lock_epoch(
        old_end: u64,
        current_epoch: u64,
        additional_epochs: u64,
        min_epochs: u64,
        max_epochs: u64,
        err_short: u64,
        err_long: u64,
    ): u64 {
        let base = if (old_end > current_epoch) { old_end } else { current_epoch };
        let new_end = base + additional_epochs;
        assert!(new_end >= current_epoch + min_epochs, error::invalid_argument(err_short));
        assert!(new_end <= current_epoch + max_epochs, error::invalid_state(err_long));
        new_end
    }

    // Computes merge lock end epoch with cap
    public fun calculate_merge_lock_epoch(
        from_end: u64,
        into_end: u64,
        current_epoch: u64,
        max_epochs: u64,
    ): u64 {
        let new_end = if (from_end > into_end) { from_end } else { into_end };
        if (new_end > current_epoch + max_epochs) {
            new_end = current_epoch + max_epochs;
        };
        new_end
    }

    // Computes orphaned rebase for expired veTokens
    public fun compute_orphaned_rebase(
        locked_amount: u64,
        acc_rebase: u128,
        rebase_debt: u128,
        rebase_bal: u64,
    ): (u64, u128) {
        let earned = calculate_rebase_debt(locked_amount, acc_rebase);
        let pending = if (earned > rebase_debt) { ((earned - rebase_debt) as u64) } else { 0 };
        let orphaned = if (pending > rebase_bal) { rebase_bal } else { pending };
        (orphaned, earned)
    }

    // Computes pending rebase for compounding
    public fun compute_pending_rebase(
        locked_amount: u64,
        acc_rebase: u128,
        rebase_debt: u128,
        rebase_bal: u64,
    ): (u64, u128) {
        let earned = calculate_rebase_debt(locked_amount, acc_rebase);
        let pending = if (earned > rebase_debt) { ((earned - rebase_debt) as u64) } else { 0 };
        let claimable = if (pending > rebase_bal) { rebase_bal } else { pending };
        (claimable, earned)
    }

    // Adjusts working supply after working balance change
    public fun adjust_working_supply(
        old_supply: u128,
        old_working: u128,
        new_working: u128,
    ): u128 {
        if (new_working >= old_working) {
            old_supply + (new_working - old_working)
        } else {
            let diff = old_working - new_working;
            if (old_supply > diff) { old_supply - diff } else { 0 }
        }
    }

    // Computes bribe claim share
    public fun compute_bribe_claim_share(
        total_bribe: u64,
        user_power: u128,
        total_power: u128,
    ): u64 {
        if (total_bribe == 0 || total_power == 0 || user_power == 0) {
            0
        } else {
            (mul_div_u128((total_bribe as u128), user_power, total_power) as u64)
        }
    }

    // Validates metadata lengths, decimals and supply tracking
    public fun validate_token_metadata_and_supply(
        name_len: u64,
        symbol_len: u64,
        decimals: u8,
        supply_opt: &option::Option<u128>,
        expected_supply_opt: &option::Option<u128>,
        e_name_too_long: u64,
        e_symbol_too_long: u64,
        e_decimals_too_high: u64,
        e_no_supply_tracking: u64,
        e_supply_zero: u64
    ): u128 {
        assert!(name_len <= 60, error::invalid_argument(e_name_too_long));
        assert!(symbol_len <= 20, error::invalid_argument(e_symbol_too_long));
        assert!(decimals <= 8, error::invalid_argument(e_decimals_too_high));
        assert!(option::is_some(supply_opt), error::invalid_argument(e_no_supply_tracking));
        let current_supply = if (option::is_some(expected_supply_opt)) { *option::borrow(expected_supply_opt) } else { *option::borrow(supply_opt) };
        assert!(current_supply > 0 && current_supply <= 18446744073709551615, error::invalid_argument(e_supply_zero));
        current_supply
    }

    // Validates wrapper token address, native & wrapped supply
    public fun validate_wrapper_token(
        dao_router: address,
        wrapper_seed: vector<u8>,
        wrapped_addr: address,
        native_addr: address,
        native_supply_opt: option::Option<u128>,
        wrapped_supply_opt: option::Option<u128>,
        wrapped_decimals: u8,
        native_decimals: u8,
        e_invalid_wrapper: u64,
        e_supply_zero: u64,
        e_decimals_too_high: u64
    ): u128 {
        let wrapper_address = account::create_resource_address(&dao_router, wrapper_seed);
        let expected_wrapper_address = object::create_object_address(&wrapper_address, bcs::to_bytes(&native_addr));
        assert!(wrapped_addr == expected_wrapper_address, error::invalid_argument(e_invalid_wrapper));
        assert!(option::is_some(&native_supply_opt), error::invalid_argument(e_supply_zero));
        let native_supply = *option::borrow(&native_supply_opt);
        assert!(native_supply > 0, error::invalid_argument(e_supply_zero));
        assert!(option::is_some(&wrapped_supply_opt) && *option::borrow(&wrapped_supply_opt) == 0, error::invalid_argument(e_supply_zero));
        assert!(wrapped_decimals == native_decimals, error::invalid_argument(e_decimals_too_high));
        native_supply
    }

    // Calculates Synthetix gauge emission reward rate
    public fun calculate_gauge_reward_rate(
        actual_amount: u128,
        period_finish: u64,
        current_time: u64,
        old_reward_rate: u128,
        duration: u64
    ): (u128, u64) {
        let dur = (duration as u128);
        let new_rate = if (current_time >= period_finish) {
            actual_amount / dur
        } else {
            let remaining = period_finish - current_time;
            let leftover = (remaining as u128) * old_reward_rate;
            (actual_amount + leftover) / dur
        };
        (new_rate, current_time + duration)
    }

    // Validates veNFT merge preconditions
    public fun validate_merge_preconditions(
        from_dao: address,
        into_dao: address,
        from_end_epoch: u64,
        from_last_voted: u64,
        into_last_voted: u64,
        current_epoch: u64,
        e_invalid_object: u64,
        e_lock_expired: u64,
        e_voted_recently: u64
    ) {
        assert!(from_dao == into_dao, error::invalid_argument(e_invalid_object));
        assert!(from_end_epoch > current_epoch, error::invalid_state(e_lock_expired));
        let check_epoch = if (current_epoch > 0) { current_epoch - 1 } else { 0 };
        assert!(from_last_voted < check_epoch, error::invalid_state(e_voted_recently));
        assert!(into_last_voted < check_epoch, error::invalid_state(e_voted_recently));
    }

    // Validates public cancel preconditions
    public fun validate_public_cancel(
        eta: u64,
        end_time: u64,
        now: u64,
        ve_token_addr: address,
        e_already_queued: u64,
        e_not_active: u64,
        e_threshold_not_dropped: u64
    ) {
        assert!(eta == 0, error::invalid_state(e_already_queued));
        assert!(now <= end_time, error::invalid_state(e_not_active));
        assert!(ve_token_addr != @0x0, error::invalid_state(e_threshold_not_dropped));
    }

    // Validates cancel expired preconditions
    public fun validate_cancel_expired(
        eta: u64,
        grace_period: u64,
        now: u64,
        e_timelock_not_ready: u64,
        e_not_expired: u64
    ) {
        assert!(eta != 0, error::invalid_state(e_timelock_not_ready));
        assert!(now > eta + grace_period, error::invalid_state(e_not_expired));
    }

    // Computes proposal start and end times
    public fun compute_proposal_window(
        now: u64,
        voting_delay: u64,
        voting_period: u64
    ): (u64, u64) {
        let start_time = now + voting_delay;
        (start_time, start_time + voting_period)
    }

    // Computes required quorum
    public fun compute_required_quorum(
        total_power: u64,
        super_quorum_threshold: u64,
        quorum_den: u64,
        is_super_quorum: bool,
        dynamic_quorum: u64
    ): u64 {
        if (quorum_den == 0) {
            0
        } else if (is_super_quorum) {
            let q = mul_div_u64(total_power, super_quorum_threshold, quorum_den);
            if (q == 0 && total_power > 0) { 1 } else { q }
        } else {
            let q = dynamic_quorum;
            if (q == 0 && total_power > 0) { 1 } else { q }
        }
    }

    // Calculates late quorum extension
    public fun calculate_late_quorum_extension(
        end_time: u64,
        now: u64,
        late_quorum: u64
    ): (bool, u64) {
        let remaining = if (end_time > now) { end_time - now } else { 0 };
        if (remaining < late_quorum && late_quorum > 0) {
            (true, now + late_quorum)
        } else {
            (false, end_time)
        }
    }

    // Computes proposal state (0: Pending, 1: Active, 2: Canceled, 3: Defeated, 4: Succeeded, 5: Queued, 6: Executed)
    public fun compute_proposal_state(
        canceled: bool,
        executed: bool,
        eta: u64,
        current_time: u64,
        start_time: u64,
        end_time: u64,
        for_votes: u64,
        against_votes: u64,
        abstain_votes: u64,
        quorum_required: u64
    ): u8 {
        if (canceled) { return 2u8 };
        if (executed) { return 6u8 };
        if (eta != 0) { return 5u8 };
        if (current_time < start_time) { return 0u8 };
        if (current_time <= end_time) { return 1u8 };
        let total_participation = for_votes + against_votes + abstain_votes;
        if (total_participation >= quorum_required && for_votes > against_votes) {
            4u8
        } else {
            3u8
        }
    }

    // Validates script proposal execution hash and argument commitments
    public fun validate_script_proposal_hashes(
        execution_hash: &vector<u8>,
        args_commitment: &vector<u8>,
        has_args: bool,
        empty_commitment: vector<u8>,
        e_invalid_len: u64,
        e_empty_args: u64,
        e_has_args: u64
    ) {
        assert!(vector::length(execution_hash) == 32, error::invalid_argument(e_invalid_len));
        assert!(vector::length(args_commitment) == 32, error::invalid_argument(e_invalid_len));
        if (has_args) {
            assert!(*args_commitment != empty_commitment, error::invalid_argument(e_empty_args));
        } else {
            assert!(*args_commitment == empty_commitment, error::invalid_argument(e_has_args));
        };
    }


    // Validates bribe deposit preconditions
    public fun validate_bribe_deposit(
        amount: u64,
        pilgrim_epoch: u64,
        current_epoch: u64,
        gauge_id: u64,
        gauge_count: u64,
        gauge_is_active: bool,
        token_is_obj: bool,
        e_zero: u64,
        e_epoch: u64,
        e_gauge: u64,
        e_obj: u64
    ) {
        assert!(amount > 0, error::invalid_argument(e_zero));
        assert!(pilgrim_epoch > current_epoch, error::invalid_argument(e_epoch));
        assert!(gauge_id < gauge_count, error::invalid_argument(e_gauge));
        assert!(gauge_is_active, error::invalid_state(e_gauge));
        assert!(token_is_obj, error::invalid_argument(e_obj));
    }

    // Validates proposal queue preconditions
    public fun validate_proposal_queue(
        eta: u64,
        canceled: bool,
        end_time: u64,
        grace_period: u64,
        now: u64,
        total_participation: u64,
        quorum_required: u64,
        for_votes: u64,
        against_votes: u64,
        e_already_queued: u64,
        e_already_canceled: u64,
        e_expired: u64,
        e_not_succeeded: u64
    ) {
        assert!(now <= end_time + grace_period, error::invalid_state(e_expired));
        assert!(eta == 0, error::invalid_state(e_already_queued));
        assert!(!canceled, error::invalid_state(e_already_canceled));
        assert!(total_participation >= quorum_required && for_votes > against_votes, error::invalid_state(e_not_succeeded));
    }

}
