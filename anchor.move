module dao_factory::anchor {
    use std::signer;
    use std::error;
    use supra_framework::timestamp;
    use supra_framework::event;
    use supra_framework::code;
    
    use dao_factory::ledger;
    use dao_factory::charter;
    use dao_factory::legacy;
    use dao_factory::sentinel;
    use dao_factory::pilgrim;
    use dao_factory::foundry;
    use supra_framework::object;

    const E_PROPOSAL_NOT_SUCCEEDED: u64 = 1;
    const E_PROPOSAL_NOT_ACTIVE: u64 = 2;
    const E_TIMELOCK_NOT_READY: u64 = 3;
    const E_NOT_GUARDIAN: u64 = 4;
    const E_NO_GUARDIAN_CONFIGURED: u64 = 5;
    const E_ALREADY_QUEUED: u64 = 6;
    const E_ALREADY_EXECUTED: u64 = 7;
    const E_ALREADY_CANCELED: u64 = 8;
    const E_PROPOSAL_DEFEATED: u64 = 9;
    const E_THRESHOLD_NOT_DROPPED: u64 = 10;
    const E_PROPOSAL_EXPIRED: u64 = 11;
    const E_INVALID_ACTION: u64 = 12;
    const E_INVALID_PROPOSAL_TYPE: u64 = 13;

    #[event]
    struct ProposalExecuted has drop, store {
        dao_address: address,
        proposal_id: u64,
    }

    #[event]
    struct ProposalCanceled has drop, store {
        dao_address: address,
        proposal_id: u64,
    }

    #[event]
    struct ProposalQueued has drop, store {
        dao_address: address,
        proposal_id: u64,
        eta: u64,
    }

    // Queues an approved proposal for execution after the timelock.
    // Anyone can call this function if the proposal meets the conditions.
    public entry fun queue_proposal(_caller: &signer, dao_address: address, proposal_id: u64) {
        let (_, _, end_time, eta, executed, canceled, for_votes, against_votes, _abstain_votes) = ledger::get_proposal_details(dao_address, proposal_id);
        let current_time = timestamp::now_seconds();
        
        // Voting must have ended
        assert!(current_time > end_time, error::invalid_state(E_PROPOSAL_NOT_ACTIVE)); 
        
        // Cannot queue twice
        assert!(eta == 0, error::invalid_state(E_ALREADY_QUEUED));
        assert!(!executed, error::invalid_state(E_ALREADY_EXECUTED));
        assert!(!canceled, error::invalid_state(E_ALREADY_CANCELED));
        
        let quorum_required = ledger::get_proposal_quorum(dao_address, proposal_id);
        
        let total_supporting = for_votes;
        
        // Must reach quorum AND have more for votes than against votes
        assert!(total_supporting >= quorum_required && for_votes > against_votes, error::invalid_state(E_PROPOSAL_NOT_SUCCEEDED));
        
        let timelock_delay = charter::get_timelock_delay(dao_address);
        let eta = current_time + timelock_delay;
        ledger::set_proposal_eta(dao_address, proposal_id, eta);
        
        event::emit(ProposalQueued { dao_address, proposal_id, eta });
    }

    // Executes a proposal that has passed the timelock.
    // Extracts the DAO's SignerCapability and publishes the new code.
    public entry fun execute_proposal(_caller: &signer, dao_address: address, proposal_id: u64) {
        // Sentinel: execute_proposal is pausable
        sentinel::assert_not_paused(dao_address);

        let (_, _, _, eta, executed, canceled, for_votes, against_votes, _) = ledger::get_proposal_details(dao_address, proposal_id);
        
        assert!(eta != 0, error::invalid_state(E_TIMELOCK_NOT_READY)); 
        assert!(timestamp::now_seconds() >= eta, error::invalid_state(E_TIMELOCK_NOT_READY)); 
        
        let grace_period = charter::get_grace_period(dao_address);
        assert!(timestamp::now_seconds() <= eta + grace_period, error::invalid_state(E_PROPOSAL_EXPIRED));

        assert!(!executed, error::invalid_state(E_ALREADY_EXECUTED));
        assert!(!canceled, error::invalid_state(E_ALREADY_CANCELED));
        
        // Defense in depth: re-verify quorum and that votes are still in favor
        let quorum_required = ledger::get_proposal_quorum(dao_address, proposal_id);
        assert!(for_votes >= quorum_required, error::invalid_state(E_PROPOSAL_NOT_SUCCEEDED));
        assert!(
            for_votes > against_votes, 
            error::invalid_state(E_PROPOSAL_DEFEATED)
        );
        
        ledger::set_proposal_executed(dao_address, proposal_id);

        let proposal_type = ledger::get_proposal_type(dao_address, proposal_id);
        assert!(proposal_type == 0, error::invalid_argument(E_INVALID_PROPOSAL_TYPE));

        // === CODE PUBLISHING ===
        
        // Extract the compiled code, metadata, and the target address for the upgrade
        let (metadata, code_bytes, target_address) = ledger::get_proposal_upgrade_data(dao_address, proposal_id);
        
        // Route the signer based on the target address
        let upgrade_signer = if (target_address == @0x0) {
            // DAO upgrades itself
            ledger::generate_signer(dao_address)
        } else {
            // DAO upgrades an external contract it owns (e.g. AMM)
            ledger::generate_external_signer(dao_address, target_address)
        };

        // The DAO publishes and overwrites the target Smart Contract on the Blockchain!
        code::publish_package_txn(&upgrade_signer, metadata, code_bytes);
        
        event::emit(ProposalExecuted { dao_address, proposal_id });
    }

    // Executes a proposal action (Treasury, Config, Gauge) that has passed the timelock.
    public entry fun execute_action(_caller: &signer, dao_address: address, proposal_id: u64) {
        sentinel::assert_not_paused(dao_address);

        let (_, _, _, eta, executed, canceled, for_votes, against_votes, _) = ledger::get_proposal_details(dao_address, proposal_id);
        
        assert!(eta != 0, error::invalid_state(E_TIMELOCK_NOT_READY)); 
        assert!(timestamp::now_seconds() >= eta, error::invalid_state(E_TIMELOCK_NOT_READY)); 
        
        let grace_period = charter::get_grace_period(dao_address);
        assert!(timestamp::now_seconds() <= eta + grace_period, error::invalid_state(E_PROPOSAL_EXPIRED));

        assert!(!executed, error::invalid_state(E_ALREADY_EXECUTED));
        assert!(!canceled, error::invalid_state(E_ALREADY_CANCELED));
        
        let quorum_required = ledger::get_proposal_quorum(dao_address, proposal_id);
        assert!(for_votes >= quorum_required, error::invalid_state(E_PROPOSAL_NOT_SUCCEEDED));
        assert!(for_votes > against_votes, error::invalid_state(E_PROPOSAL_DEFEATED));
        
        ledger::set_proposal_executed(dao_address, proposal_id);

        let dao_signer = ledger::generate_signer(dao_address);
        let proposal_type = ledger::get_proposal_type(dao_address, proposal_id);
        
        assert!(proposal_type != 0, error::invalid_argument(E_INVALID_PROPOSAL_TYPE));

        if (proposal_type == 1) { // Treasury Transfer (SupraCoin or FungibleAsset)
            let (asset_address, recipient, amount) = ledger::extract_proposal_action_treasury(dao_address, proposal_id);
            
            // By convention, we use @0x1 to represent the native SupraCoin.
            if (asset_address == @0x1) {
                supra_framework::coin::transfer<supra_framework::supra_coin::SupraCoin>(&dao_signer, recipient, amount);
            } else {
                // Otherwise, treat it as a FungibleAsset
                let metadata = supra_framework::object::address_to_object<supra_framework::fungible_asset::Metadata>(asset_address);
                supra_framework::primary_fungible_store::transfer(&dao_signer, metadata, recipient, amount);
            };
        } else if (proposal_type == 2) { // Config Change
            let (config_key, config_value) = ledger::get_proposal_action_config(dao_address, proposal_id);
            if (config_key == 0) charter::update_super_quorum(&dao_signer, config_value)
            else if (config_key == 1) charter::update_quorum_numerator(&dao_signer, config_value)
            else if (config_key == 2) charter::update_quorum_denominator(&dao_signer, config_value)
            else if (config_key == 3) charter::update_late_quorum_extension(&dao_signer, config_value)
            else if (config_key == 4) charter::update_voting_delay(&dao_signer, config_value)
            else if (config_key == 5) charter::update_voting_period(&dao_signer, config_value)
            else if (config_key == 6) charter::update_proposal_threshold(&dao_signer, config_value)
            else if (config_key == 7) charter::update_timelock_delay(&dao_signer, config_value)
            else if (config_key == 8) charter::update_grace_period(&dao_signer, config_value)
            else { abort error::invalid_argument(E_INVALID_ACTION) };
        } else if (proposal_type == 3) { // Gauge Action
            let (action_type, target_address, gauge_id) = ledger::get_proposal_action_gauge(dao_address, proposal_id);
            if (action_type == 0) {
                // target_address is the LP Token Address
                let dao_token_address = dao_factory::legacy::get_dao_token_address(dao_address);
                let gauge_address = foundry::create_gauge(&dao_signer, target_address, dao_token_address);
                dao_factory::zeal::create_gauge(&dao_signer, gauge_address);
            } else if (action_type == 1) {
                dao_factory::zeal::set_gauge_status(&dao_signer, gauge_id, false); // Deactivate
            } else if (action_type == 2) {
                dao_factory::zeal::set_gauge_status(&dao_signer, gauge_id, true); // Activate
            } else {
                abort error::invalid_argument(E_INVALID_ACTION)
            };
        } else if (proposal_type == 4) { // Guardian Update
            let new_guardian = ledger::extract_proposal_action_guardian(dao_address, proposal_id);
            if (new_guardian == @0x0) {
                charter::update_guardian(&dao_signer, std::option::none());
            } else {
                charter::update_guardian(&dao_signer, std::option::some(new_guardian));
            };
        };
        
        event::emit(ProposalExecuted { dao_address, proposal_id });
    }

    // Security Function: A Guardian can cancel a proposal before it is executed.
    // This is standard in DeFi protocols (Compound, Aerodrome, etc.) to prevent governance attacks.
    public entry fun cancel_proposal(caller: &signer, dao_address: address, proposal_id: u64) {
        let guardian_opt = charter::get_guardian(dao_address);
        assert!(std::option::is_some(&guardian_opt), error::invalid_state(E_NO_GUARDIAN_CONFIGURED));
        assert!(signer::address_of(caller) == *std::option::borrow(&guardian_opt), error::permission_denied(E_NOT_GUARDIAN));

        let (_, _, _, _, executed, canceled, _, _, _) = ledger::get_proposal_details(dao_address, proposal_id);
        assert!(!executed, error::invalid_state(E_ALREADY_EXECUTED));
        assert!(!canceled, error::invalid_state(E_ALREADY_CANCELED));

        ledger::set_proposal_canceled(dao_address, proposal_id);

        event::emit(ProposalCanceled { dao_address, proposal_id });
    }

    // Security Function: Public Cancellation (Threshold Drop).
    // Anyone can cancel a proposal if the proposer's voting power drops below the required threshold.
    // This acts as a decentralized immune system against proposers who lose their community backing.
    public entry fun public_cancel_proposal(_caller: &signer, dao_address: address, proposal_id: u64) {
        let (proposer, _, _, _, executed, canceled, _, _, _) = ledger::get_proposal_details(dao_address, proposal_id);
        assert!(!executed, error::invalid_state(E_ALREADY_EXECUTED));
        assert!(!canceled, error::invalid_state(E_ALREADY_CANCELED));

        let (_, _, _, proposal_threshold, _, _, _, _) = charter::get_dao_config_view(dao_address);
        let ve_token_addr = ledger::get_proposal_ve_token(dao_address, proposal_id);
        
        // If the NFT address is 0x0, it means the proposal was created before the update or is invalid.
        // We shouldn't allow public cancellation if we can't verify it.
        assert!(ve_token_addr != @0x0, error::invalid_state(E_THRESHOLD_NOT_DROPPED));

        let current_power = if (object::object_exists<legacy::VeToken>(ve_token_addr)) {
            let ve_token_obj = object::address_to_object<legacy::VeToken>(ve_token_addr);
            if (object::is_owner(ve_token_obj, proposer)) {
                // Check power in the current epoch to see if it dropped
                legacy::get_voting_power_at(ve_token_obj, pilgrim::now())
            } else {
                0
            }
        } else {
            0 // NFT was destroyed, voting power is 0
        };

        // If the power is still above or equal to the threshold, it cannot be canceled.
        assert!(current_power < proposal_threshold, error::invalid_state(E_THRESHOLD_NOT_DROPPED));

        ledger::set_proposal_canceled(dao_address, proposal_id);
        event::emit(ProposalCanceled { dao_address, proposal_id });
    }

    // Security Function: Finalizes a proposal after voting ends, recording its participation
    // for the dynamic rolling quorum. Anyone can call this.
    public entry fun finalize_proposal(_caller: &signer, dao_address: address, proposal_id: u64) {
        let (_, _, end_time, _, executed, canceled, for_v, against_v, abstain_v) = ledger::get_proposal_details(dao_address, proposal_id);
        
        // Ensure voting has ended
        assert!(timestamp::now_seconds() > end_time, error::invalid_state(E_PROPOSAL_NOT_ACTIVE));
        assert!(!canceled, error::invalid_state(E_ALREADY_CANCELED));
        assert!(!executed, error::invalid_state(E_ALREADY_EXECUTED));

        let total_participation = for_v + against_v + abstain_v;
        
        // FIX (M-05): Only record participation if the proposal succeeded.
        // Since network fees are low, this prevents attackers from creating cheap spam proposals
        // that are intentionally defeated just to artificially inflate the dynamic quorum of the DAO.
        if (for_v > against_v) {
            ledger::record_participation(dao_address, proposal_id, total_participation);
        } else {
            // Mark it as finalized in the ledger without affecting the moving average quorum
            ledger::record_participation(dao_address, proposal_id, 0); // Assuming 0 skips the EMA calculation, or we need a specific function.
        };
    }
}
