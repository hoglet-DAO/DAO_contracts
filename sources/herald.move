// Governance Proposals Module.
//
// Any veToken holder with sufficient voting power can create a proposal.
// Proposals include the compiled code that the DAO will publish if approved
// (via anchor::execute_proposal).
//
// Follows the OpenZeppelin Governor standard:
// - Voting delay (time between creation and voting open)
// - Voting period (voting window)
// - Proposal threshold (minimum power to propose)
module dao_factory::herald {
    friend dao_factory::petra;
    use std::string::String;
    use std::signer;
    use supra_framework::timestamp;
    use supra_framework::event;
    use supra_framework::object;
    use std::error;
    use aptos_std::smart_table::{Self, SmartTable};

    use dao_factory::pilgrim;
    use dao_factory::ledger;
    use dao_factory::charter;
    use dao_factory::legacy;


    use dao_factory::sentinel;
    use dao_factory::jubilee;
    use dao_factory::boost_registry;
    use aptos_token_objects::collection;

    // Errors
    const E_BELOW_THRESHOLD: u64 = 1;
    const E_LOCK_EXPIRED: u64    = 2;
    const E_ACTIVE_PROPOSAL_EXISTS: u64 = 3;
    const E_NOT_OBJECT: u64 = 4;
    const E_INVALID_CONFIG_KEY: u64 = 5;
    const E_NOT_INFLATIONARY: u64 = 6;
    const E_DAO_NOT_ACTIVE: u64 = 7;
    const E_INVALID_ACTION_TYPE: u64 = 8;
    const E_NOT_A_COLLECTION: u64 = 9;
    const E_INVALID_BOOST: u64 = 10;

    // Structs 
    struct HeraldState has key {
        latest_proposals: SmartTable<address, u64>,
    }

    // Initialization 
    public(friend) fun initialize(dao_signer: &signer) {
        move_to(dao_signer, HeraldState {
            latest_proposals: smart_table::new(),
        });
    }

    // Events
    #[event]
    struct ProposalCreated has drop, store {
        dao_address: address,
        proposal_id: u64,
        proposer: address,
        title: String,
        proposal_type: u8,
        start_time: u64,
        end_time: u64,
        action_target_address: address,
        action_asset_address: address,
        action_recipient: address,
        action_amount: u64,
        action_config_key: u64,
        action_config_value: u64,
    }

    // Functions
    // Creates a new governance proposal.
    //
    // # Arguments
    // - `proposer`: The signer with the veToken backing the proposal.
    // - `legacy`: The proposer's veToken (governance NFT).
    // - `dao_address`: The address of the DAO's resource account.
    // - `title`: Short title of the proposal (visible on-chain).
    // - `description_hash`: Hash of the long content (IPFS CID or SHA-256).
    // - `upgrade_metadata`: Serialized BCS of the `PackageMetadata` of the new code.
    // - `upgrade_code`: Vector of compiled modules in bytes.
    //
    // # Security
    // Voting power is read from the PREVIOUS epoch (now - 1) to prevent
    // someone from creating a huge lock in the same block and proposing instantly.
    fun validate_and_prepare_proposal(
        proposer: &signer,
        legacy_addr: address,
        dao_address: address,
        is_super_quorum: bool
    ): (address, address, u64, u64, u64, u64) acquires HeraldState {
        let proposer_addr = signer::address_of(proposer);

        assert!(object::is_object(legacy_addr), error::invalid_argument(E_NOT_OBJECT));
        let legacy = object::address_to_object<legacy::VeToken>(legacy_addr);

        // Sentinel: propose is pausable
        sentinel::assert_not_paused(dao_address);
        
        // DAO Activation Lock: Only active DAOs can accept proposals
        assert!(charter::is_active(dao_address), error::permission_denied(E_DAO_NOT_ACTIVE));

        // Check Anti-Spam: 1 Active Proposal Limit
        let herald_state = borrow_global_mut<HeraldState>(dao_address);
        if (smart_table::contains(&herald_state.latest_proposals, proposer_addr)) {
            let last_id = *smart_table::borrow(&herald_state.latest_proposals, proposer_addr);
            let state = ledger::get_proposal_state(dao_address, last_id);
            // 0: Pending, 1: Active
            assert!(state > 1, error::invalid_state(E_ACTIVE_PROPOSAL_EXISTS));
        };

        // Verify that the proposer owns the veToken.
        assert!(
            supra_framework::object::is_owner(legacy, proposer_addr),
            error::permission_denied(E_BELOW_THRESHOLD)
        );

        // ANTI-EXPLOIT: Ensure the veToken belongs to the target DAO
        assert!(
            legacy::get_dao_address(legacy) == dao_address, 
            error::permission_denied(E_BELOW_THRESHOLD)
        );

        let (_, voting_delay, voting_period, proposal_threshold, _, _, _, _) = charter::get_dao_config_view(dao_address);

        // Read voting power in the PREVIOUS epoch (anti-flash-loan).
        let check_epoch = if (pilgrim::now() > 0) {
            pilgrim::now() - 1
        } else {
            0
        };
        let power = legacy::get_voting_power_at(legacy, check_epoch);
        assert!(power >= proposal_threshold, error::invalid_state(E_BELOW_THRESHOLD));

        // The veToken cannot be expired.
        assert!(!legacy::is_expired(legacy), error::invalid_state(E_LOCK_EXPIRED));

        // Calculate time windows.
        let now = timestamp::now_seconds();
        let start_time = now + voting_delay;
        let end_time   = start_time + voting_period;

        // Sequential ID.
        let proposal_id = charter::increment_proposal_count(dao_address);

        // Update latest proposal tracking
        smart_table::upsert(&mut herald_state.latest_proposals, proposer_addr, proposal_id);

        let ve_token_addr = object::object_address(&legacy);

        // Calculate dynamic quorum at the exact moment of proposal creation
        let (_, _, _, _, quorum_num, quorum_den, super_quorum_threshold, _) = charter::get_dao_config_view(dao_address);
        // SECURITY FIX (M11): Use historical total_locked matching the check_epoch to prevent quorum griefing
        let total_locked = legacy::get_total_locked_at(dao_address, check_epoch);
        
        let quorum_required = if (is_super_quorum) {
            if (quorum_den > 0) {
                ((((total_locked as u128) * (super_quorum_threshold as u128)) / (quorum_den as u128)) as u64)
            } else {
                0
            }
        } else {
            let default_quorum = if (quorum_den > 0) {
                ((((total_locked as u128) * (quorum_num as u128)) / (quorum_den as u128)) as u64)
            } else {
                0
            };
            ledger::get_dynamic_quorum(dao_address, default_quorum)
        };
        
        (proposer_addr, ve_token_addr, start_time, end_time, proposal_id, quorum_required)
    }

    public entry fun propose(
        proposer: &signer,
        legacy_addr: address,
        dao_address: address,
        title: String,
        description_hash: vector<u8>,
        target_address: address, // Added target_address for external upgrades
        upgrade_metadata: vector<u8>,
        upgrade_code: vector<vector<u8>>,
    ) acquires HeraldState {
        let (proposer_addr, ve_token_addr, start_time, end_time, proposal_id, quorum_required) = 
            validate_and_prepare_proposal(proposer, legacy_addr, dao_address, true);

        // Create and store the proposal.
        let new_proposal = ledger::new_proposal(
            proposal_id,
            proposer_addr,
            ve_token_addr,
            title,
            description_hash,
            start_time,
            end_time,
            upgrade_metadata,
            upgrade_code,
            quorum_required,
            target_address, // Passed target_address
        );
        ledger::add_proposal(dao_address, proposal_id, new_proposal);

        emit_proposal_event(
            dao_address, proposal_id, proposer_addr, title, 0, start_time, end_time,
            target_address, @0x0, @0x0, 0, 0, 0
        );
    }

    public entry fun propose_treasury_transfer(
        proposer: &signer,
        legacy_addr: address,
        dao_address: address,
        title: String,
        description_hash: vector<u8>,
        asset_address: address,
        recipient: address,
        amount: u64,
    ) acquires HeraldState {
        let (proposer_addr, ve_token_addr, start_time, end_time, proposal_id, quorum_required) = 
            validate_and_prepare_proposal(proposer, legacy_addr, dao_address, false);

        // Create and store the treasury proposal.
        let new_proposal = ledger::new_treasury_proposal(
            proposal_id,
            proposer_addr,
            ve_token_addr,
            title,
            description_hash,
            start_time,
            end_time,
            quorum_required,
            asset_address,
            recipient,
            amount,
        );
        ledger::add_proposal(dao_address, proposal_id, new_proposal);

        emit_proposal_event(
            dao_address, proposal_id, proposer_addr, title, 1, start_time, end_time,
            @0x0, asset_address, recipient, amount, 0, 0
        );
    }

    public entry fun propose_treasury_transfer_coin<CoinType>(
        proposer: &signer,
        legacy_addr: address,
        dao_address: address,
        title: String,
        description_hash: vector<u8>,
        recipient: address,
        amount: u64,
    ) acquires HeraldState {
        let (proposer_addr, ve_token_addr, start_time, end_time, proposal_id, quorum_required) = 
            validate_and_prepare_proposal(proposer, legacy_addr, dao_address, false);

        // Map CoinType to FA Metadata Address. If none exists, assume native coin (@0x1)
        let metadata_opt = supra_framework::coin::paired_metadata<CoinType>();
        let asset_address = if (std::option::is_some(&metadata_opt)) {
            let metadata = std::option::extract(&mut metadata_opt);
            object::object_address(&metadata)
        } else {
            @0x1
        };

        // Create and store the treasury proposal.
        let new_proposal = ledger::new_treasury_proposal(
            proposal_id,
            proposer_addr,
            ve_token_addr,
            title,
            description_hash,
            start_time,
            end_time,
            quorum_required,
            asset_address,
            recipient,
            amount,
        );
        ledger::add_proposal(dao_address, proposal_id, new_proposal);

        emit_proposal_event(
            dao_address, proposal_id, proposer_addr, title, 1, start_time, end_time,
            @0x0, asset_address, recipient, amount, 0, 0
        );
    }

    public entry fun propose_claim_capability(
        proposer: &signer,
        legacy_addr: address,
        dao_address: address,
        title: String,
        description_hash: vector<u8>,
        target_address: address,
    ) acquires HeraldState {
        let (proposer_addr, ve_token_addr, start_time, end_time, proposal_id, quorum_required) = 
            validate_and_prepare_proposal(proposer, legacy_addr, dao_address, false);

        // Create and store the claim capability proposal.
        let new_proposal = ledger::new_claim_capability_proposal(
            proposal_id,
            proposer_addr,
            ve_token_addr,
            title,
            description_hash,
            start_time,
            end_time,
            quorum_required,
            target_address,
        );
        ledger::add_proposal(dao_address, proposal_id, new_proposal);

        emit_proposal_event(
            dao_address, proposal_id, proposer_addr, title, 6, start_time, end_time,
            target_address, @0x0, @0x0, 0, 0, 0
        );
    }

    public entry fun propose_nft_transfer(
        proposer: &signer,
        legacy_addr: address,
        dao_address: address,
        title: String,
        description_hash: vector<u8>,
        nft_address: address,
        recipient: address,
    ) acquires HeraldState {
        let (proposer_addr, ve_token_addr, start_time, end_time, proposal_id, quorum_required) = 
            validate_and_prepare_proposal(proposer, legacy_addr, dao_address, false);

        // Create and store the NFT Transfer proposal.
        let new_proposal = ledger::new_nft_proposal(
            proposal_id,
            proposer_addr,
            ve_token_addr,
            title,
            description_hash,
            start_time,
            end_time,
            quorum_required,
            nft_address,
            recipient,
        );
        ledger::add_proposal(dao_address, proposal_id, new_proposal);

        emit_proposal_event(
            dao_address, proposal_id, proposer_addr, title, 5, start_time, end_time,
            nft_address, @0x0, recipient, 1, 0, 0
        );
    }

    public entry fun propose_config_change(
        proposer: &signer,
        legacy_addr: address,
        dao_address: address,
        title: String,
        description_hash: vector<u8>,
        config_key: u8,
        config_value: u64,
    ) acquires HeraldState {
        assert!(config_key <= 11, error::invalid_argument(E_INVALID_CONFIG_KEY));
        if (config_key <= 8) {
            charter::validate_config_value(dao_address, config_key, config_value);
        } else {
            // Keys 9-11 are jubilee emission parameters (decay, tail emission,
            // gauge split): they only exist on inflationary DAOs.
            assert!(charter::is_inflationary(dao_address), error::invalid_state(E_NOT_INFLATIONARY));
            jubilee::assert_valid_emission_param(dao_address, (config_key as u64), config_value);
        };
        let (proposer_addr, ve_token_addr, start_time, end_time, proposal_id, quorum_required) = 
            validate_and_prepare_proposal(proposer, legacy_addr, dao_address, true); // Config changes require super quorum

        let new_proposal = ledger::new_config_proposal(
            proposal_id,
            proposer_addr,
            ve_token_addr,
            title,
            description_hash,
            start_time,
            end_time,
            quorum_required,
            config_key,
            config_value,
        );
        ledger::add_proposal(dao_address, proposal_id, new_proposal);

        emit_proposal_event(
            dao_address, proposal_id, proposer_addr, title, 2, start_time, end_time,
            @0x0, @0x0, @0x0, 0, (config_key as u64), config_value
        );
    }

    public entry fun propose_guardian_update(
        proposer: &signer,
        legacy_addr: address,
        dao_address: address,
        title: String,
        description_hash: vector<u8>,
        new_guardian: address,
    ) acquires HeraldState {
        let (proposer_addr, ve_token_addr, start_time, end_time, proposal_id, quorum_required) = 
            validate_and_prepare_proposal(proposer, legacy_addr, dao_address, true); // Guardian changes require super quorum

        let new_proposal = ledger::new_guardian_proposal(
            proposal_id,
            proposer_addr,
            ve_token_addr,
            title,
            description_hash,
            start_time,
            end_time,
            quorum_required,
            new_guardian,
        );
        ledger::add_proposal(dao_address, proposal_id, new_proposal);

        emit_proposal_event(
            dao_address, proposal_id, proposer_addr, title, 4, start_time, end_time,
            new_guardian, @0x0, @0x0, 0, 0, 0
        );
    }

    public entry fun propose_gauge_action(
        proposer: &signer,
        legacy_addr: address,
        dao_address: address,
        title: String,
        description_hash: vector<u8>,
        action_type: u8,
        target_address: address,
        gauge_id: u64,
    ) acquires HeraldState {
        assert!(charter::is_inflationary(dao_address), error::invalid_state(E_NOT_INFLATIONARY));
        let (proposer_addr, ve_token_addr, start_time, end_time, proposal_id, quorum_required) = 
            validate_and_prepare_proposal(proposer, legacy_addr, dao_address, false); // Gauge actions use regular quorum

        let new_proposal = ledger::new_gauge_proposal(
            proposal_id,
            proposer_addr,
            ve_token_addr,
            title,
            description_hash,
            start_time,
            end_time,
            quorum_required,
            action_type,
            target_address,
            gauge_id,
        );
        ledger::add_proposal(dao_address, proposal_id, new_proposal);

        emit_proposal_event(
            dao_address, proposal_id, proposer_addr, title, 3, start_time, end_time,
            target_address, @0x0, @0x0, 0, (action_type as u64), gauge_id
        );
    }

    public entry fun propose_module_setting(
        proposer: &signer,
        legacy_addr: address,
        dao_address: address,
        title: String,
        description_hash: vector<u8>,
        setting_type: u8,
        target_address: address,
        string_value: String,
        bool_value: bool,
    ) acquires HeraldState {
        assert!(setting_type <= 1, error::invalid_argument(E_INVALID_ACTION_TYPE));
        if (setting_type == 1) {
            // restore::set_whitelist manages bribe tokens: only meaningful on
            // inflationary DAOs (static DAOs have no BribeRegistry).
            assert!(charter::is_inflationary(dao_address), error::invalid_state(E_NOT_INFLATIONARY));
        };
        let (proposer_addr, ve_token_addr, start_time, end_time, proposal_id, quorum_required) = 
            validate_and_prepare_proposal(proposer, legacy_addr, dao_address, true);

        let new_proposal = ledger::new_module_setting_proposal(
            proposal_id,
            proposer_addr,
            ve_token_addr,
            title,
            description_hash,
            start_time,
            end_time,
            quorum_required,
            setting_type,
            target_address,
            *std::string::bytes(&string_value),
            if (bool_value) 1 else 0,
        );
        ledger::add_proposal(dao_address, proposal_id, new_proposal);

        emit_proposal_event(
            dao_address, proposal_id, proposer_addr, title, 7, start_time, end_time,
            target_address, @0x0, @0x0, 0, (setting_type as u64), if (bool_value) 1 else 0
        );
    }

    // Creates a proposal to approve, update, or remove an NFT collection (0x4
    // Digital Assets) from the DAO's Boost Registry.
    //
    // # Arguments
    // - `action_type`: 0 = add/update collection, 1 = remove collection.
    // - `collection_addr`: address of the 0x4 Collection object.
    // - `boost_bps`: boost in basis points (e.g. 500 = +5%). Ignored for removals.
    //
    // Uses REGULAR quorum (like gauge actions): it only affects how the fixed
    // emissions are redistributed among stakers, never the total supply.
    public entry fun propose_boost_action(
        proposer: &signer,
        legacy_addr: address,
        dao_address: address,
        title: String,
        description_hash: vector<u8>,
        action_type: u8,
        collection_addr: address,
        boost_bps: u64,
    ) acquires HeraldState {
        assert!(action_type <= 1, error::invalid_argument(E_INVALID_ACTION_TYPE));
        assert!(charter::is_inflationary(dao_address), error::invalid_state(E_NOT_INFLATIONARY));

        if (action_type == 0) {
            // Fail fast: the collection must be a real 0x4 Collection object
            // and the boost must respect the unbreakable hard cap.
            assert!(
                supra_framework::object::object_exists<collection::Collection>(collection_addr),
                error::invalid_argument(E_NOT_A_COLLECTION)
            );
            assert!(
                boost_bps > 0 && boost_bps <= boost_registry::hard_cap_bps(),
                error::invalid_argument(E_INVALID_BOOST)
            );
        };

        let (proposer_addr, ve_token_addr, start_time, end_time, proposal_id, quorum_required) =
            validate_and_prepare_proposal(proposer, legacy_addr, dao_address, false); // Regular quorum

        let new_proposal = ledger::new_boost_proposal(
            proposal_id,
            proposer_addr,
            ve_token_addr,
            title,
            description_hash,
            start_time,
            end_time,
            quorum_required,
            action_type,
            collection_addr,
            boost_bps,
        );
        ledger::add_proposal(dao_address, proposal_id, new_proposal);

        emit_proposal_event(
            dao_address, proposal_id, proposer_addr, title, 8, start_time, end_time,
            collection_addr, @0x0, @0x0, 0, (action_type as u64), boost_bps
        );
    }

    // --- Helpers for Deduplication ---

    fun emit_proposal_event(
        dao_address: address, proposal_id: u64, proposer: address, title: String, proposal_type: u8, start_time: u64, end_time: u64,
        action_target_address: address, action_asset_address: address, action_recipient: address, action_amount: u64, action_config_key: u64, action_config_value: u64
    ) {
        event::emit(ProposalCreated {
            dao_address,
            proposal_id,
            proposer,
            title,
            proposal_type,
            start_time,
            end_time,
            action_target_address,
            action_asset_address,
            action_recipient,
            action_amount,
            action_config_key,
            action_config_value,
        });
    }
}
