// Gauge views extracted from dao_factory::zeal (package size refactor).
//
// Only consumes public views of the core package, so no friend access is
// required. Semantics are identical to the original
// zeal::find_gauge_by_staking_token: sparse gauge ids (removed/never-filled
// slots) are skipped, mirroring the original smart_table::contains guard.
module dao_views::gauge_views {
    use std::vector;
    use dao_factory::foundry;
    use dao_factory::restore;
    use dao_factory::zeal;
    use dao_libs::math;
    use dao_libs::pilgrim;

    // Returns the id of the gauge whose staking token matches, or
    // GAUGE_NOT_FOUND (u64::MAX, same sentinel as zeal).
    #[view]
    public fun find_gauge_by_staking_token(dao_address: address, staking_token_addr: address): u64 {
        let gauge_count = zeal::get_gauge_count(dao_address);
        let gauge_id: u64 = 0;
        while (gauge_id < gauge_count) {
            let destination = zeal::get_gauge_destination(dao_address, gauge_id);
            if (destination != @0x0) {
                if (foundry::staking_token(destination) == staking_token_addr) {
                    return gauge_id
                };
            };
            gauge_id = gauge_id + 1;
        };
        0xFFFFFFFFFFFFFFFF
    }

    // Consolidated user gauge dashboard data in a single view call (avoids multiple separate RPCs).
    #[view]
    public fun get_user_gauge_info(gauge_addr: address, account: address): (
        u128,    // 0: balance_of
        u64,     // 1: earned
        u128,    // 2: working_balance
        u128,    // 3: working_supply
        u128,    // 4: reward_rate
        u64,     // 5: period_finish
        u64      // 6: user_boost_bps
    ) {
        (
            foundry::balance_of(gauge_addr, account),
            foundry::earned(gauge_addr, account),
            foundry::working_balance_of(gauge_addr, account),
            foundry::working_supply(gauge_addr),
            foundry::reward_rate(gauge_addr),
            foundry::period_finish(gauge_addr),
            foundry::get_user_boost_bps(gauge_addr, account)
        )
    }

    // Batch query of balances and earned rewards across multiple gauges for a user.
    #[view]
    public fun get_batch_user_gauge_balances(gauge_addrs: vector<address>, account: address): (
        vector<u128>, // balances
        vector<u64>   // earned rewards
    ) {
        let balances = vector::empty<u128>();
        let earned = vector::empty<u64>();
        let i = 0;
        let len = vector::length(&gauge_addrs);
        while (i < len) {
            let g = *vector::borrow(&gauge_addrs, i);
            vector::push_back(&mut balances, foundry::balance_of(g, account));
            vector::push_back(&mut earned, foundry::earned(g, account));
            i = i + 1;
        };
        (balances, earned)
    }

    // Calcula el monto exacto de bribe reclamable por un veNFT en una época pasada (0 si ya reclamó o si la época sigue abierta)
    #[view]
    public fun get_claimable_bribe(
        dao_address: address,
        pilgrim_epoch: u64,
        gauge_id: u64,
        token_addr: address,
        ve_token_addr: address
    ): u64 {
        if (pilgrim_epoch >= pilgrim::now()) return 0;
        if (restore::has_claimed_bribe(dao_address, pilgrim_epoch, gauge_id, token_addr, ve_token_addr)) return 0;
        let total_bribe = restore::get_total_bribes_for(dao_address, pilgrim_epoch, gauge_id, token_addr);
        let user_power = zeal::get_user_vote_power(dao_address, pilgrim_epoch, ve_token_addr, gauge_id);
        let total_power = zeal::get_gauge_total_votes(dao_address, pilgrim_epoch, gauge_id);
        math::compute_bribe_claim_share(total_bribe, user_power, total_power)
    }
}

