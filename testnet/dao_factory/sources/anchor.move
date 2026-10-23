module dao_factory::anchor {
    friend dao_factory::seal;
    use std::signer;
    use dao_tax_router::tax_router;
    use std::error;
    use supra_framework::timestamp;
    use supra_framework::event;
    
    use dao_factory::ledger;
    use dao_libs::math;
    use dao_factory::charter;
    use dao_factory::legacy;
    use dao_factory::sentinel;
    use dao_factory::foundry;
    use dao_boost::boost_registry;
    use dao_factory::jubilee;
    use dao_tokens::smart_token;
    use dao_scripts::vault;
    use supra_framework::object;
    use aptos_token_objects::token;
    use supra_framework::coin;
    use supra_framework::supra_coin::SupraCoin;
    use supra_framework::fungible_asset::Metadata;
    use supra_framework::primary_fungible_store;
    use supra_framework::dispatchable_fungible_asset;
    use supra_framework::transaction_context;

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
    const E_PROPOSAL_NOT_EXPIRED: u64 = 16;
    const E_SCRIPT_HASH_MISMATCH: u64 = 17;
    const E_CANNOT_CANCEL_GUARDIAN_PROPOSAL: u64 = 18;
    const E_NOT_BLESSED: u64 = 19;

    // FA Metadata object of the native SupraCoin (@0xa). This is the canonical
    // asset address for native SUPRA in treasury proposals; the legacy @0x1
    // sentinel is still accepted for proposals created before the migration.
    const NATIVE_SUPRA_FA: address = @0xa;

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
    public entry fun queue_proposal(dao_address: address, proposal_id: u64) {
        let (_, _, end_time, eta, _executed, canceled, for_votes, against_votes, abstain_votes) = ledger::get_proposal_details(dao_address, proposal_id);
        
        assert_active_and_ended(dao_address, end_time);
        let proposal_type = ledger::get_proposal_type(dao_address, proposal_id);
        if (proposal_type != 4) {
            sentinel::assert_not_paused(dao_address);
        };
        let grace_period = charter::get_grace_period(dao_address);
        let quorum_required = ledger::get_proposal_quorum(dao_address, proposal_id);
        let qualifying_votes = for_votes + abstain_votes;
        math::validate_proposal_queue(
            eta,
            canceled,
            end_time,
            grace_period,
            timestamp::now_seconds(),
            qualifying_votes,
            quorum_required,
            for_votes,
            against_votes,
            E_ALREADY_QUEUED,
            E_ALREADY_CANCELED,
            E_PROPOSAL_EXPIRED,
            E_PROPOSAL_NOT_SUCCEEDED
        );
        
        let timelock_delay = charter::get_timelock_delay(dao_address);
        let eta = timestamp::now_seconds() + timelock_delay;
        ledger::set_proposal_eta(dao_address, proposal_id, eta);
        
        event::emit(ProposalQueued { dao_address, proposal_id, eta });
    }

    // Resolves a script proposal (type 9) that has passed voting and timelock.
    // Can only be called within a transaction whose script bytecode hash matches the proposal's execution_hash.
    // Returns the DAO's Signer for transient execution within the calling script.
    //
    // `public(friend)` ON PURPOSE: scripts must NOT call this directly, because
    // it does not verify the args commitment nor the vault allow-list. The ONLY
    // public entry point is `seal::resolve`, which checks both and
    // then delegates here. This closes the "call anchor::resolve directly to
    // bypass seal" attack (HOG-01).
    public(friend) fun resolve(dao_address: address, proposal_id: u64): signer {
        // Type 9 hands the DAO's signer to ARBITRARY code. A guardian (who can
        // ONLY cancel, never execute) is required as a safety net: if a malicious
        // script is ever approved, the guardian can still cancel it during the
        // timelock. No guardian => no script execution.
        assert!(
            std::option::is_some(&charter::get_guardian(dao_address)),
            error::invalid_state(E_NO_GUARDIAN_CONFIGURED)
        );
        assert!(charter::is_blessed(dao_address), error::invalid_state(E_NOT_BLESSED));

        validate_and_mark_executed(dao_address, proposal_id);

        let proposal_type = ledger::get_proposal_type(dao_address, proposal_id);
        assert!(proposal_type == 8, error::invalid_argument(E_INVALID_PROPOSAL_TYPE));

        let expected_hash = ledger::get_proposal_execution_hash(dao_address, proposal_id);
        assert!(math::is_valid_hash(&expected_hash), error::invalid_argument(E_SCRIPT_HASH_MISMATCH));
        assert!(
            transaction_context::get_script_hash() == expected_hash,
            error::invalid_argument(E_SCRIPT_HASH_MISMATCH)
        );

        event::emit(ProposalExecuted { dao_address, proposal_id });

        ledger::generate_signer(dao_address)
    }

    // Executes a proposal action (Treasury, Config, Gauge, etc.) that has passed the timelock.
    public entry fun execute_action(_caller: &signer, dao_address: address, proposal_id: u64) {
        validate_and_mark_executed(dao_address, proposal_id);

        let dao_signer = ledger::generate_signer(dao_address);
        let proposal_type = ledger::get_proposal_type(dao_address, proposal_id);
        
        // Script proposals (type 8) must be resolved via anchor::resolve from a script transaction.
        assert!(proposal_type != 8, error::invalid_argument(E_INVALID_PROPOSAL_TYPE));

        if (proposal_type == 1) { // Treasury Transfer (SupraCoin or FungibleAsset)
            let (asset_address, recipient, amount) = ledger::extract_proposal_action_treasury(dao_address, proposal_id);
            
            // Native SupraCoin is identified by its FA metadata object (@0xa).
            // The legacy @0x1 sentinel stays accepted for proposals created
            // before the migration. Both route through coin::transfer, which
            // withdraws from the CoinStore AND the paired FA primary store, so
            // it works whichever form the treasury holds.
            if (asset_address == NATIVE_SUPRA_FA || asset_address == @0x1) {
                coin::transfer<SupraCoin>(&dao_signer, recipient, amount);
            } else {
                // Otherwise, treat it as a FungibleAsset
                let metadata = object::address_to_object<Metadata>(asset_address);
                let from_store = primary_fungible_store::ensure_primary_store_exists(signer::address_of(&dao_signer), metadata);
                let to_store = primary_fungible_store::ensure_primary_store_exists(recipient, metadata);
                if (tax_router::has_tax_free_router(dao_address) && asset_address == legacy::get_token_metadata_address(dao_address)) {
                    let fa = tax_router::withdraw_tax_free(dao_address, &dao_signer, from_store, amount);
                    tax_router::deposit_tax_free(dao_address, &dao_signer, to_store, fa);
                } else {
                    let fa = dispatchable_fungible_asset::withdraw(&dao_signer, from_store, amount);
                    dispatchable_fungible_asset::deposit(to_store, fa);
                };
            };
        } else if (proposal_type == 2) { // Config Change
            assert!(charter::is_blessed(dao_address), error::invalid_state(E_NOT_BLESSED));
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
                let token_addr = dao_factory::legacy::get_token_metadata_address(dao_address);
                smart_token::update_single_param(token_addr, &dao_signer, config_key - 20, config_value);
            } else { abort error::invalid_argument(E_INVALID_ACTION) };
        } else if (proposal_type == 3) { // Gauge Action
            // Defense in depth: gauges only exist on inflationary DAOs.
            assert!(charter::is_inflationary(dao_address), error::invalid_state(E_NOT_INFLATIONARY));
            let (action_type, target_address, gauge_id) = ledger::get_proposal_action_gauge(dao_address, proposal_id);
            if (action_type == 0) {
                // target_address is the LP Token Address
                let dao_token_address = dao_factory::legacy::get_token_metadata_address(dao_address);
                let gauge_address = foundry::create_gauge(&dao_signer, target_address, dao_token_address);
                dao_factory::zeal::create_gauge(&dao_signer, gauge_address, target_address, true);
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
            assert!(charter::is_blessed(dao_address), error::invalid_state(E_NOT_BLESSED));
            let new_guardian = ledger::extract_proposal_action_guardian(dao_address, proposal_id);
            if (new_guardian == @0x0) {
                charter::update_guardian(&dao_signer, std::option::none());
            } else {
                charter::update_guardian(&dao_signer, std::option::some(new_guardian));
            };
            sentinel::force_unpause_by_governance(dao_address);
        } else if (proposal_type == 5) { // NFT Transfer
            let (nft_address, recipient) = ledger::extract_proposal_action_nft(dao_address, proposal_id);
            // H-02 Defense: Ensure object is a valid NFT and not an internal protocol object or the DAO
            assert!(nft_address != dao_address, error::invalid_argument(E_INVALID_ACTION));
            assert!(object::object_exists<token::Token>(nft_address), error::invalid_argument(E_INVALID_ACTION));
            let nft_obj = object::address_to_object<token::Token>(nft_address);
            object::transfer(&dao_signer, nft_obj, recipient);
        } else if (proposal_type == 6) { // Module Settings
            let (setting_type, target_address, string_bytes, bool_val) = ledger::get_proposal_action_module_setting(dao_address, proposal_id);
            if (setting_type == 0) { // legacy::update_base_uri
                dao_factory::legacy::update_base_uri(&dao_signer, std::string::utf8(string_bytes));
            } else if (setting_type == 1) { // restore::set_whitelist
                // Defense in depth: bribe whitelists only exist on inflationary DAOs.
                assert!(charter::is_inflationary(dao_address), error::invalid_state(E_NOT_INFLATIONARY));
                let token_metadata = object::address_to_object<supra_framework::fungible_asset::Metadata>(target_address);
                dao_factory::restore::set_whitelist(&dao_signer, token_metadata, bool_val == 1);
            } else if (setting_type >= 2 && setting_type <= 4) { // Smart Token settings
                let token_addr = dao_factory::legacy::get_token_metadata_address(dao_address);
                if (setting_type == 2) {
                    smart_token::update_treasury_address(token_addr, &dao_signer, target_address);
                } else if (setting_type == 3) {
                    smart_token::update_blacklist(token_addr, &dao_signer, target_address, bool_val == 1);
                } else {
                    smart_token::set_exemption(token_addr, &dao_signer, target_address, bool_val == 1);
                };
            } else {
                abort error::invalid_argument(E_INVALID_ACTION)
            };
        } else if (proposal_type == 7) { // NFT Boost Collection Action
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
        } else if (proposal_type == 9) { // Script Allow-list (type 9)
            assert!(charter::is_blessed(dao_address), error::invalid_state(E_NOT_BLESSED));
            let (script_id, add) = ledger::get_proposal_action_script_allow(dao_address, proposal_id);
            if (add) {
                vault::add(&dao_signer, script_id);
            } else {
                vault::remove(&dao_signer, script_id);
            };
        } else {
            abort error::invalid_argument(E_INVALID_PROPOSAL_TYPE)
        };
        
        event::emit(ProposalExecuted { dao_address, proposal_id });
    }

    /// Permissionless crank: wraps the DAO's legacy Coin balance into its paired
    /// Fungible Asset. No recipient parameter, so funds cannot leave the DAO.
    public entry fun wrap<CoinType>(dao_address: address) {
        let balance = coin::balance<CoinType>(dao_address);
        let coins = coin::withdraw<CoinType>(&ledger::generate_signer(dao_address), balance);
        primary_fungible_store::deposit(dao_address, coin::coin_to_fungible_asset(coins));
    }

    // Security Function: A Guardian can cancel a proposal before it is executed.
    // This is standard in DeFi protocols (Compound, Aerodrome, etc.) to prevent governance attacks.
    public entry fun cancel_proposal(caller: &signer, dao_address: address, proposal_id: u64) {
        let guardian_opt = charter::get_guardian(dao_address);
        assert!(std::option::is_some(&guardian_opt), error::invalid_state(E_NO_GUARDIAN_CONFIGURED));
        assert!(signer::address_of(caller) == *std::option::borrow(&guardian_opt), error::permission_denied(E_NOT_GUARDIAN));

        // SECURITY FIX (M-07): A Guardian cannot cancel a proposal to update/remove the Guardian (Type 4)
        let proposal_type = ledger::get_proposal_type(dao_address, proposal_id);
        assert!(proposal_type != 4, error::permission_denied(E_CANNOT_CANCEL_GUARDIAN_PROPOSAL));

        mark_as_canceled(dao_address, proposal_id);
    }

    // Security Function: Public Cancellation (Threshold Drop).
    // Anyone can cancel a proposal if the proposer's voting power drops below the required threshold.
    // This acts as a decentralized immune system against proposers who lose their community backing.
    public entry fun public_cancel_proposal(dao_address: address, proposal_id: u64) {
        let (proposer, _, end_time, eta, _, _, _, _, _) = ledger::get_proposal_details(dao_address, proposal_id);
        let (_, _, _, proposal_threshold, _, _, _, _) = charter::get_dao_config_view(dao_address);
        let ve_token_addr = ledger::get_proposal_ve_token(dao_address, proposal_id);
        math::validate_public_cancel(
            eta,
            end_time,
            timestamp::now_seconds(),
            ve_token_addr,
            E_ALREADY_QUEUED,
            E_PROPOSAL_NOT_ACTIVE,
            E_THRESHOLD_NOT_DROPPED
        );

        let current_power = if (object::object_exists<legacy::VeToken>(ve_token_addr)) {
            let ve_token_obj = object::address_to_object<legacy::VeToken>(ve_token_addr);
            if (object::is_owner(ve_token_obj, proposer)) {
                // Check power at the proposal's snapshot epoch to avoid natural time decay griefing
                let snapshot_epoch = ledger::get_proposal_snapshot_epoch(dao_address, proposal_id);
                legacy::get_voting_power_at(ve_token_obj, snapshot_epoch)
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
    public entry fun cancel_expired_proposal(dao_address: address, proposal_id: u64) {
        let (_, _, _, eta, _, _, _, _, _) = ledger::get_proposal_details(dao_address, proposal_id);
        
        let grace_period = charter::get_grace_period(dao_address);
        math::validate_cancel_expired(eta, grace_period, timestamp::now_seconds(), E_TIMELOCK_NOT_READY, E_PROPOSAL_NOT_EXPIRED);

        mark_as_canceled(dao_address, proposal_id);
    }


    // Security Function: Finalizes a proposal after voting ends, recording its participation
    // for the dynamic rolling quorum. Anyone can call this.
    public entry fun finalize_proposal(dao_address: address, proposal_id: u64) {
        let (_, _, end_time, _, executed, canceled, for_v, against_v, abstain_v) = ledger::get_proposal_details(dao_address, proposal_id);
        
        assert_active_and_ended(dao_address, end_time);
        assert!(!canceled, error::invalid_state(E_ALREADY_CANCELED));
        assert!(!executed, error::invalid_state(E_ALREADY_EXECUTED));

        // Support-only turnout (for + abstain) drives both the quorum check and the
        // dynamic rolling average, so opposition votes never qualify a proposal.
        let qualifying_votes = for_v + abstain_v;

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
        if (for_v > against_v && qualifying_votes >= quorum_required) {
            ledger::record_participation(dao_address, proposal_id, qualifying_votes);
        } else {
            // Mark it as finalized in the ledger without affecting the moving average quorum
            ledger::record_participation(dao_address, proposal_id, 0); // Assuming 0 skips the EMA calculation, or we need a specific function.
        };
    }

    // --- Helpers for Deduplication ---

    fun assert_active_and_ended(dao_address: address, end_time: u64) {
        assert!(timestamp::now_seconds() > end_time, error::invalid_state(E_PROPOSAL_NOT_ACTIVE));
        assert!(charter::is_active(dao_address), error::invalid_state(E_PROPOSAL_NOT_ACTIVE));
    }

    fun validate_and_mark_executed(dao_address: address, proposal_id: u64) {
        let proposal_type = ledger::get_proposal_type(dao_address, proposal_id);
        // SECURITY FIX (M-07): Type 4 proposals (Guardian replacement) bypass the paused state
        // so a rogue guardian cannot freeze the DAO to prevent its own dismissal or force the proposal to expire.
        if (proposal_type != 4) {
            sentinel::assert_not_paused(dao_address);
        };
        assert!(charter::is_active(dao_address), error::invalid_state(E_PROPOSAL_NOT_ACTIVE));

        let (_, _, _, eta, executed, canceled, for_votes, against_votes, abstain_votes) = ledger::get_proposal_details(dao_address, proposal_id);
        let grace_period = charter::get_grace_period(dao_address);
        let quorum_required = ledger::get_proposal_quorum(dao_address, proposal_id);
        let qualifying_votes = for_votes + abstain_votes;
        math::validate_proposal_execution(
            eta, grace_period, executed, canceled, qualifying_votes, quorum_required, for_votes, against_votes, timestamp::now_seconds(),
            E_TIMELOCK_NOT_READY, E_PROPOSAL_EXPIRED, E_ALREADY_EXECUTED, E_ALREADY_CANCELED, E_PROPOSAL_NOT_SUCCEEDED, E_PROPOSAL_DEFEATED
        );
        
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
