module dao_views::proposal_views {
    use std::option::Option;
    use std::string::String;
    use std::vector;
    use supra_framework::timestamp;
    use dao_factory::charter;
    use dao_factory::ledger;
    use dao_factory::sentinel;

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

    // Radar de propuestas vivas (0: Pending, 1: Active, 4: Succeeded, 5: Queued)
    // descartando propuestas "zombie" cuyo grace_period ya expiró.
    #[view]
    public fun get_live_proposal_ids(dao_address: address): vector<u64> {
        let total = charter::get_proposal_count(dao_address);
        let live = vector::empty<u64>();
        if (total == 0) return live;
        let grace_period = charter::get_grace_period(dao_address);
        let now = timestamp::now_seconds();
        let start_id = if (total > 50) { total - 49 } else { 1 };
        let i = start_id;
        while (i <= total) {
            let state = ledger::get_proposal_state(dao_address, i);
            if (state == 0 || state == 1) {
                vector::push_back(&mut live, i);
            } else if (state == 4 || state == 5) {
                let (_, _, end_time, eta, _, _, _, _, _) = ledger::get_proposal_details(dao_address, i);
                let deadline = if (state == 4) { end_time + grace_period } else { eta + grace_period };
                if (now <= deadline) {
                    vector::push_back(&mut live, i);
                };
            };
            i = i + 1;
        };
        live
    }

    // Vista consolidada de auditoría para los 9 tipos de propuesta en 1 sola llamada RPC
    #[view]
    public fun get_proposal_audit_view(dao_address: address, proposal_id: u64): (
        String,          // 0: title
        vector<u8>,      // 1: description_hash
        u8,              // 2: proposal_type (1..9)
        address,         // 3: target_address (token / nft / new guardian / lp / collection)
        address,         // 4: recipient
        u64,             // 5: amount / script_id
        u8,              // 6: config_key / action_type / setting_type
        u64,             // 7: config_value / gauge_id / boost_bps / allow_flag
        vector<u8>,      // 8: execution_hash (32 bytes en tipo 8, vacío en el resto)
        vector<u8>       // 9: args_commitment (32 bytes en tipo 8, vacío en el resto)
    ) {
        let title = ledger::get_proposal_title(dao_address, proposal_id);
        let desc_hash = ledger::get_proposal_description_hash(dao_address, proposal_id);
        let (ptype, target, recipient, amount, config_key, config_value) =
            ledger::get_proposal_action_raw(dao_address, proposal_id);
        let exec_hash = ledger::get_proposal_execution_hash(dao_address, proposal_id);
        let args_commit = ledger::get_proposal_args_commitment(dao_address, proposal_id);
        (title, desc_hash, ptype, target, recipient, amount, config_key, config_value, exec_hash, args_commit)
    }

    // Panel completo del Guardian / Centinela en 1 sola llamada RPC
    #[view]
    public fun get_dao_security_status(dao_address: address): (
        Option<address>, // 0: guardian
        bool,            // 1: is_active
        bool,            // 2: is_blessed
        bool,            // 3: is_inflationary
        bool,            // 4: is_paused
        u64,             // 5: pause_expiry_epoch
        bool,            // 6: can_pause
        u64,             // 7: total_proposals
        vector<u64>      // 8: live_proposal_ids
    ) {
        (
            charter::get_guardian(dao_address),
            charter::is_active(dao_address),
            charter::is_blessed(dao_address),
            charter::is_inflationary(dao_address),
            sentinel::is_paused(dao_address),
            sentinel::pause_expiry_epoch(dao_address),
            sentinel::can_pause(dao_address),
            charter::get_proposal_count(dao_address),
            get_live_proposal_ids(dao_address)
        )
    }
}

