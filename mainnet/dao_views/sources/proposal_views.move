module dao_views::proposal_views {
    use std::vector;
    use dao_factory::ledger;

    // Consolidated full view for a single proposal (avoids multiple separate RPC calls).
    #[view]
    public fun get_proposal_full_info(dao_address: address, proposal_id: u64): (
        u8,              // 0: state (0..6)
        address,         // 1: proposer
        u64,             // 2: start_time
        u64,             // 3: end_time
        u64,             // 4: eta
        bool,            // 5: executed
        bool,            // 6: canceled
        u64,             // 7: for_votes
        u64,             // 8: against_votes
        u64,             // 9: abstain_votes
        u64,             // 10: quorum_required
        address,         // 11: proposer_ve_token
        u64              // 12: snapshot_epoch
    ) {
        let state = ledger::get_proposal_state(dao_address, proposal_id);
        let (proposer, start_t, end_t, eta, exec, canc, for_v, ag_v, abs_v) =
            ledger::get_proposal_details(dao_address, proposal_id);
        let quorum = ledger::get_proposal_quorum(dao_address, proposal_id);
        let ve_token = ledger::get_proposal_ve_token(dao_address, proposal_id);
        let epoch = ledger::get_proposal_snapshot_epoch(dao_address, proposal_id);

        (state, proposer, start_t, end_t, eta, exec, canc, for_v, ag_v, abs_v, quorum, ve_token, epoch)
    }

    // Batch read of proposal states for a list of proposal IDs in one round-trip.
    #[view]
    public fun get_batch_proposal_states(dao_address: address, proposal_ids: vector<u64>): vector<u8> {
        let states = vector::empty<u8>();
        let i = 0;
        let len = vector::length(&proposal_ids);
        while (i < len) {
            let pid = *vector::borrow(&proposal_ids, i);
            let s = ledger::get_proposal_state(dao_address, pid);
            vector::push_back(&mut states, s);
            i = i + 1;
        };
        states
    }
}
