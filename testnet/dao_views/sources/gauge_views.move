// Gauge views extracted from dao_factory::zeal (package size refactor).
//
// Only consumes public views of the core package, so no friend access is
// required. Semantics are identical to the original
// zeal::find_gauge_by_staking_token: sparse gauge ids (removed/never-filled
// slots) are skipped, mirroring the original smart_table::contains guard.
module dao_factory::gauge_views {
    use dao_factory::foundry;
    use dao_factory::zeal;

    /// Returns the id of the gauge whose staking token matches, or
    /// GAUGE_NOT_FOUND (u64::MAX, same sentinel as zeal).
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
}
