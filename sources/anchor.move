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
    use dao_factory::foundry;
    use dao_factory::boost_registry;
    use dao_factory::jubilee;
    use dao_tokens::smart_token;
    use supra_framework::object;
    use supra_framework::coin;
    use supra_framework::supra_coin::SupraCoin;
    use supra_framework::fungible_asset::Metadata;
    use supra_framework::primary_fungible_store;

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
    const E_NOT_INFLATIONARY: u64 = 14;
    const E_NO_COINS_TO_WRAP: u64 = 15;
    const E_PROPOSAL_NOT_EXPIRED: u64 = 16;

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
        let (_, _, end_time, eta, executed, canceled, for_votes, against_votes, abstain_votes) = ledger::get_proposal_details(dao_address, proposal_id);
        
        assert_active_and_ended(dao_address, end_time);
        
        // Cannot queue twice
        assert!(eta == 0, error::invalid_state(E_ALREADY_QUEUED));
        assert!(!executed, error::invalid_state(E_ALREADY_EXECUTED));
        assert!(!canceled, error::invalid_state(E_ALREADY_CANCELED));
        
        let quorum_required = ledger::get_proposal_quorum(dao_address, proposal_id);
        let total_participation = for_votes + against_votes + abstain_votes;
        
        // Must reach quorum AND have more for votes than against votes
        assert!(total_participation >= quorum_required && for_votes > against_votes, error::invalid_state(E_PROPOSAL_NOT_SUCCEEDED));
        
        let timelock_delay = charter::get_timelock_delay(dao_address);
        let eta = timestamp::now_seconds() + timelock_delay;
        ledger::set_proposal_eta(dao_address, proposal_id, eta);
        
        event::emit(ProposalQueued { dao_address, proposal_id, eta });
    }

    // Executes a proposal that has passed the timelock.
    // Extracts the DAO's SignerCapability and publishes the new code.
    public entry fun execute_proposal(_caller: &signer, dao_address: address, proposal_id: u64) {
        validate_and_mark_executed(dao_address, proposal_id);

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
        validate_and_mark_executed(dao_address, proposal_id);

        let dao_signer = ledger::generate_signer(dao_address);
        let proposal_type = ledger::get_proposal_type(dao_address, proposal_id);
        
        assert!(proposal_type != 0, error::invalid_argument(E_INVALID_PROPOSAL_TYPE));

        if (proposal_type == 1) { // Treasury Transfer (SupraCoin or FungibleAsset)
            let (asset_address, recipient, amount) = ledger::extract_proposal_action_treasury(dao_address, proposal_id);
            
            // By convention, we use @0x1 to represent the native SupraCoin.
            if (asset_address == @0x1) {
                coin::transfer<SupraCoin>(&dao_signer, recipient, amount);
            } else {
                // Otherwise, treat it as a FungibleAsset
                let metadata = object::address_to_object<Metadata>(asset_address);
                primary_fungible_store::transfer(&dao_signer, metadata, recipient, amount);
            };
        } else if (proposal_type == 2) { // Config Change
            let (config_key, config_value) = ledger::get_proposal_action_config(dao_address, proposal_id);
            // Defense in depth: keys 9-11 are jubilee emission parameters and
            // only exist on inflationary DAOs (herald already gates this at
            // proposal time; we re-verify before executing).
            if (config_key >= 9) {
                assert!(charter::is_inflationary(dao_address), error::invalid_state(E_NOT_INFLATIONARY));
            };
            if (config_key <= 8) {
                charter::update_config(&dao_signer, config_key, config_value);
            } else if (config_key <= 11) {
                jubilee::update_config(&dao_signer, (config_key as u64), config_value);
            } else if (config_key >= 20 && config_key <= 27) {
                let token_addr = dao_factory::legacy::get_dao_token_address(dao_address);
                smart_token::update_single_param(token_addr, &dao_signer, config_key - 20, config_value);
            } else { abort error::invalid_argument(E_INVALID_ACTION) };
        } else if (proposal_type == 3) { // Gauge Action
            // Defense in depth: gauges only exist on inflationary DAOs.
            assert!(charter::is_inflationary(dao_address), error::invalid_state(E_NOT_INFLATIONARY));
            let (action_type, target_address, gauge_id) = ledger::get_proposal_action_gauge(dao_address, proposal_id);
            if (action_type == 0) {
                // target_address is the LP Token Address
                let dao_token_address = dao_factory::legacy::get_dao_token_address(dao_address);
                let gauge_address = foundry::create_gauge(&dao_signer, target_address, dao_token_address);
                dao_factory::zeal::create_gauge(&dao_signer, gauge_address, target_address);
                if (smart_token::is_initialized(dao_token_address)) {
                    smart_token::set_exemption(dao_token_address, &dao_signer, gauge_address, true);
                };
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
        } else if (proposal_type == 5) { // NFT Transfer
            let (nft_address, recipient) = ledger::extract_proposal_action_nft(dao_address, proposal_id);
            let nft_obj = object::address_to_object<object::ObjectCore>(nft_address);
            object::transfer(&dao_signer, nft_obj, recipient);
        } else if (proposal_type == 6) { // Claim Capability
            // We reuse extract_proposal_action_guardian because both just extract action_target_address
            let target_address = ledger::extract_proposal_action_guardian(dao_address, proposal_id);
            ledger::claim_capability(dao_address, target_address);
        } else if (proposal_type == 7) { // Module Settings
            let (setting_type, target_address, string_bytes, bool_val) = ledger::get_proposal_action_module_setting(dao_address, proposal_id);
            if (setting_type == 0) { // legacy::update_base_uri
                dao_factory::legacy::update_base_uri(&dao_signer, std::string::utf8(string_bytes));
            } else if (setting_type == 1) { // restore::set_whitelist
                // Defense in depth: bribe whitelists only exist on inflationary DAOs.
                assert!(charter::is_inflationary(dao_address), error::invalid_state(E_NOT_INFLATIONARY));
                let token_metadata = object::address_to_object<supra_framework::fungible_asset::Metadata>(target_address);
                dao_factory::restore::set_whitelist(&dao_signer, token_metadata, bool_val == 1);
            } else if (setting_type == 2) { // Smart Token: Update Treasury Address
                let token_addr = dao_factory::legacy::get_dao_token_address(dao_address);
                smart_token::update_treasury_address(token_addr, &dao_signer, target_address);
            } else if (setting_type == 3) { // Smart Token: Update Blacklist
                let token_addr = dao_factory::legacy::get_dao_token_address(dao_address);
                smart_token::update_blacklist(token_addr, &dao_signer, target_address, bool_val == 1);
            } else {
                abort error::invalid_argument(E_INVALID_ACTION)
            };
        } else if (proposal_type == 8) { // NFT Boost Collection Action
            // Defense in depth: the boost registry only exists on inflationary DAOs.
            assert!(charter::is_inflationary(dao_address), error::invalid_state(E_NOT_INFLATIONARY));
            // Same (u8, address, u64) payload shape as Gauge actions: the view is reused.
            let (action_type, collection_addr, boost_bps) = ledger::get_proposal_action_gauge(dao_address, proposal_id);
            if (action_type == 0) {
                boost_registry::set_collection(&dao_signer, collection_addr, boost_bps);
            } else if (action_type == 1) {
                boost_registry::remove_collection(&dao_signer, collection_addr);
            } else {
                abort error::invalid_argument(E_INVALID_ACTION)
            };
        } else {
            abort error::invalid_argument(E_INVALID_PROPOSAL_TYPE)
        };
        
        event::emit(ProposalExecuted { dao_address, proposal_id });
    }

    // Security Function: A Guardian can cancel a proposal before it is executed.
    // This is standard in DeFi protocols (Compound, Aerodrome, etc.) to prevent governance attacks.
    public entry fun cancel_proposal(caller: &signer, dao_address: address, proposal_id: u64) {
        let guardian_opt = charter::get_guardian(dao_address);
        assert!(std::option::is_some(&guardian_opt), error::invalid_state(E_NO_GUARDIAN_CONFIGURED));
        assert!(signer::address_of(caller) == *std::option::borrow(&guardian_opt), error::permission_denied(E_NOT_GUARDIAN));

        mark_as_canceled(dao_address, proposal_id);
    }

    // Security Function: Public Cancellation (Threshold Drop).
    // Anyone can cancel a proposal if the proposer's voting power drops below the required threshold.
    // This acts as a decentralized immune system against proposers who lose their community backing.
    public entry fun public_cancel_proposal(_caller: &signer, dao_address: address, proposal_id: u64) {
        let (proposer, start_time, _, _, _, _, _, _, _) = ledger::get_proposal_details(dao_address, proposal_id);
        let (_, _, _, proposal_threshold, _, _, _, _) = charter::get_dao_config_view(dao_address);
        let ve_token_addr = ledger::get_proposal_ve_token(dao_address, proposal_id);
        
        // If the NFT address is 0x0, it means the proposal was created before the update or is invalid.
        // We shouldn't allow public cancellation if we can't verify it.
        assert!(ve_token_addr != @0x0, error::invalid_state(E_THRESHOLD_NOT_DROPPED));

        let current_power = if (object::object_exists<legacy::VeToken>(ve_token_addr)) {
            let ve_token_obj = object::address_to_object<legacy::VeToken>(ve_token_addr);
            if (object::is_owner(ve_token_obj, proposer)) {
                // Check power at the time the proposal was created to avoid natural time decay griefing
                let start_epoch = start_time / 604800; // Convert timestamp to epoch
                legacy::get_voting_power_at(ve_token_obj, start_epoch)
            } else {
                0
            }
        } else {
            0 // NFT was destroyed, voting power is 0
        };

        // If the power is still above or equal to the threshold, it cannot be canceled.
        assert!(current_power < proposal_threshold, error::invalid_state(E_THRESHOLD_NOT_DROPPED));

        mark_as_canceled(dao_address, proposal_id);
    }

    // Security Function (M9): Cancel Expired Proposal.
    // If a proposal is queued but nobody executes it within the grace period,
    // it becomes a "Zombie". This function allows anyone to clean up the state
    // by permanently canceling it, removing it from the queue securely.
    public entry fun cancel_expired_proposal(_caller: &signer, dao_address: address, proposal_id: u64) {
        let (_, _, _, eta, _, _, _, _, _) = ledger::get_proposal_details(dao_address, proposal_id);
        
        assert!(eta != 0, error::invalid_state(E_TIMELOCK_NOT_READY));

        let grace_period = charter::get_grace_period(dao_address);
        assert!(timestamp::now_seconds() > eta + grace_period, error::invalid_state(E_PROPOSAL_NOT_EXPIRED));

        mark_as_canceled(dao_address, proposal_id);
    }


    // Security Function: Finalizes a proposal after voting ends, recording its participation
    // for the dynamic rolling quorum. Anyone can call this.
    public entry fun finalize_proposal(_caller: &signer, dao_address: address, proposal_id: u64) {
        let (_, _, end_time, _, executed, canceled, for_v, against_v, abstain_v) = ledger::get_proposal_details(dao_address, proposal_id);
        
        assert_active_and_ended(dao_address, end_time);
        assert!(!canceled, error::invalid_state(E_ALREADY_CANCELED));
        assert!(!executed, error::invalid_state(E_ALREADY_EXECUTED));

        let total_participation = for_v + against_v + abstain_v;

        // SECURITY FIX (VULN-03): Only record participation if the proposal
        // genuinely succeeded: it must win the vote AND reach quorum.
        // The previous check (for_v > against_v alone) allowed a governance
        // capture spiral: an attacker with just enough power to propose could
        // create self-voted proposals with tiny turnout (which "win" 1-0 but
        // never reach quorum), driving the rolling average participation down
        // to the 10%-of-default floor. Since treasury transfers only require
        // the regular dynamic quorum, this paved the way to drain the treasury
        // with minimal voting power.
        let quorum_required = ledger::get_proposal_quorum(dao_address, proposal_id);
        if (for_v > against_v && total_participation >= quorum_required) {
            ledger::record_participation(dao_address, proposal_id, total_participation);
        } else {
            // Mark it as finalized in the ledger without affecting the moving average quorum
            ledger::record_participation(dao_address, proposal_id, 0); // Assuming 0 skips the EMA calculation, or we need a specific function.
        };
    }

    /// Allows anyone to wrap legacy coins residing in the DAO's CoinStore into Fungible Assets.
    /// This is a permissionless maintenance crank to ensure the treasury remains FA-native.
    public entry fun wrap_legacy_coins<CoinType>(_caller: &signer, dao_address: address) {
        let balance = coin::balance<CoinType>(dao_address);
        assert!(balance > 0, error::invalid_state(E_NO_COINS_TO_WRAP));

        // We need the DAO's signer to withdraw from its own CoinStore
        let dao_signer = ledger::generate_signer(dao_address);
        
        // Withdraw the entire legacy coin balance
        let coins = coin::withdraw<CoinType>(&dao_signer, balance);

        // Convert the legacy coins to fungible assets
        let fa = coin::coin_to_fungible_asset(coins);

        // Deposit the fungible assets back into the DAO's PrimaryFungibleStore
        primary_fungible_store::deposit(dao_address, fa);
    }

    // --- Helpers for Deduplication ---

    fun assert_active_and_ended(dao_address: address, end_time: u64) {
        assert!(timestamp::now_seconds() > end_time, error::invalid_state(E_PROPOSAL_NOT_ACTIVE));
        assert!(charter::is_active(dao_address), error::invalid_state(E_PROPOSAL_NOT_ACTIVE));
    }

    fun validate_and_mark_executed(dao_address: address, proposal_id: u64) {
        sentinel::assert_not_paused(dao_address);
        assert!(charter::is_active(dao_address), error::invalid_state(E_PROPOSAL_NOT_ACTIVE));

        let (_, _, _, eta, executed, canceled, for_votes, against_votes, abstain_votes) = ledger::get_proposal_details(dao_address, proposal_id);
        
        assert!(eta != 0, error::invalid_state(E_TIMELOCK_NOT_READY)); 
        assert!(timestamp::now_seconds() >= eta, error::invalid_state(E_TIMELOCK_NOT_READY)); 
        
        let grace_period = charter::get_grace_period(dao_address);
        assert!(timestamp::now_seconds() <= eta + grace_period, error::invalid_state(E_PROPOSAL_EXPIRED));

        assert!(!executed, error::invalid_state(E_ALREADY_EXECUTED));
        assert!(!canceled, error::invalid_state(E_ALREADY_CANCELED));
        
        let quorum_required = ledger::get_proposal_quorum(dao_address, proposal_id);
        let total_participation = for_votes + against_votes + abstain_votes;
        assert!(total_participation >= quorum_required, error::invalid_state(E_PROPOSAL_NOT_SUCCEEDED));
        assert!(for_votes > against_votes, error::invalid_state(E_PROPOSAL_DEFEATED));
        
        ledger::set_proposal_executed(dao_address, proposal_id);
    }

    fun mark_as_canceled(dao_address: address, proposal_id: u64) {
        let (_, _, _, _, executed, canceled, _, _, _) = ledger::get_proposal_details(dao_address, proposal_id);
        assert!(!executed, error::invalid_state(E_ALREADY_EXECUTED));
        assert!(!canceled, error::invalid_state(E_ALREADY_CANCELED));
        ledger::set_proposal_canceled(dao_address, proposal_id);
        event::emit(ProposalCanceled { dao_address, proposal_id });
    }
}
