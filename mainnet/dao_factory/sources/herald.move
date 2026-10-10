// Governance Proposals Module.
//
// Any veToken holder with sufficient voting power can create a proposal.
// Standard actions are executed via anchor::execute_action, and arbitrary
// external contract interactions/upgrades are executed via Move Scripts
// verified by sha3-256 script hash (via anchor::resolve).
//
// Follows the OpenZeppelin Governor standard:
// - Voting delay (time between creation and voting open)
// - Voting period (voting window)
// - Proposal threshold (minimum power to propose)
module dao_factory::herald {
    friend dao_factory::petra;
    use std::string::String;
    use std::signer;
    use std::vector;
    use supra_framework::timestamp;
    use supra_framework::event;
    use supra_framework::object;
    use std::error;
    use aptos_std::smart_table::{Self, SmartTable};
    use aptos_std::aptos_hash;

    
    use dao_libs::pilgrim;
    use dao_factory::ledger;
    use dao_factory::charter;
    use dao_factory::legacy;
    use dao_libs::math;

    use dao_factory::sentinel;
    use dao_factory::jubilee;
    use dao_factory::boost_registry;

    use dao_scripts::library;
    use dao_scripts::vault;

    // Errors
    const E_BELOW_THRESHOLD: u64 = 1;
    const E_LOCK_EXPIRED: u64    = 2;
    const E_ACTIVE_PROPOSAL_EXISTS: u64 = 3;
    const E_NOT_OBJECT: u64 = 4;
    const E_INVALID_CONFIG_KEY: u64 = 5;
    const E_NOT_INFLATIONARY: u64 = 6;
    const E_DAO_NOT_ACTIVE: u64 = 7;
    const E_INVALID_ACTION_TYPE: u64 = 8;
    const E_INVALID_BOOST: u64 = 10;
    const E_INVALID_HASH_LENGTH: u64 = 11;
    const E_NO_GUARDIAN: u64 = 12;
    const E_SCRIPT_NOT_ALLOWED: u64 = 13;
    const E_SCRIPT_NOT_FOUND: u64 = 14;
    const E_STATIC_SCRIPT_HAS_ARGS: u64 = 15;
    const E_PARAMETERIZED_SCRIPT_EMPTY_ARGS: u64 = 16;

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
        /// Hash of the off-chain proposal metadata (title/description/discussion
        /// link). It is already stored on-chain in `ledger::Proposal`, but
        /// without emitting it here indexers cannot resolve it and every
        /// proposal gets indexed with the "No description provided." default.
        description_hash: vector<u8>,
        /// Hash of the compiled Move script bytecode (sha3-256) for type 9 proposals.
        /// Empty for standard proposal types (1-8).
        execution_hash: vector<u8>,
        /// keccak256 of the script args (32 bytes) for type 9 proposals; empty for
        /// every other type. Lets indexers commit to the args without a view call.
        args_commitment: vector<u8>,
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

        let (_, voting_delay, voting_period, proposal_threshold, quorum_num, quorum_den, super_quorum_threshold, _) = charter::get_dao_config_view(dao_address);

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
        // SECURITY FIX (M11): Use historical total_locked matching the check_epoch to prevent quorum griefing
        let total_locked = legacy::get_total_locked_at(dao_address, check_epoch);
        
        let quorum_required = if (quorum_den == 0) {
            0
        } else if (is_super_quorum) {
            math::mul_div_u64(total_locked, super_quorum_threshold, quorum_den)
        } else {
            let default_quorum = math::mul_div_u64(total_locked, quorum_num, quorum_den);
            ledger::get_dynamic_quorum(dao_address, default_quorum)
        };
        
        (proposer_addr, ve_token_addr, start_time, end_time, proposal_id, quorum_required)
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
            @0x0, asset_address, recipient, amount, 0, 0, description_hash, vector::empty(), vector::empty()
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
            nft_address, @0x0, recipient, 1, 0, 0, description_hash, vector::empty(), vector::empty()
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
        assert!(config_key <= 11 || (config_key >= 20 && config_key <= 27), error::invalid_argument(E_INVALID_CONFIG_KEY));
        if (config_key <= 8) {
            charter::validate_config_value(dao_address, config_key, config_value);
        } else if (config_key >= 9 && config_key <= 11) {
            // Keys 9-11 are jubilee emission parameters (decay, tail emission,
            // gauge split): they only exist on inflationary DAOs.
            assert!(charter::is_inflationary(dao_address), error::invalid_state(E_NOT_INFLATIONARY));
            jubilee::assert_valid_emission_param(dao_address, (config_key as u64), config_value);
        };
        // Keys 20-27 are Smart Token parameters and require no extra pre-validation here.
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
            @0x0, @0x0, @0x0, 0, (config_key as u64), config_value, description_hash, vector::empty(), vector::empty()
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
            new_guardian, @0x0, @0x0, 0, 0, 0, description_hash, vector::empty(), vector::empty()
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
            target_address, @0x0, @0x0, 0, (action_type as u64), gauge_id, description_hash, vector::empty(), vector::empty()
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
        assert!(setting_type <= 4, error::invalid_argument(E_INVALID_ACTION_TYPE));
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
            target_address, @0x0, @0x0, 0, (setting_type as u64), if (bool_value) 1 else 0, description_hash, vector::empty(), vector::empty()
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
            // The collection may be a live 0x4 Collection OR the deterministic
            // wrapped address of a legacy V1 collection that has not been
            // wrapped yet (the wrapper creates it lazily at exactly that
            // address). We cannot call the wrapper from here (keeps the
            // dependency DAG acyclic), so existence is NOT asserted: the boost
            // only ever takes effect through foundry::apply_boost ->
            // boost_registry::compute_boost, which verifies real 0x4 Tokens,
            // ownership and registry membership at claim time.
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
            collection_addr, @0x0, @0x0, 0, (action_type as u64), boost_bps, description_hash, vector::empty(), vector::empty()
        );
    }

    /// Creates a proposal to execute an arbitrary Move Script (type 9).
    ///
    /// # Arguments
    /// - `script_id`: ID of the script in dao_scripts::library (must be approved in the DAO's vault).
    /// - `args_commitment`: keccak256 hash of the script arguments (or keccak256(empty) for parameterless).
    ///
    /// Uses SUPER QUORUM to prevent governance capture when executing arbitrary scripts with the DAO signer.
    public entry fun propose_script(
        proposer: &signer,
        legacy_addr: address,
        dao_address: address,
        title: String,
        description_hash: vector<u8>,
        script_id: u64,
        args_commitment: vector<u8>,
    ) acquires HeraldState {
        // Type 9 executes ARBITRARY code with the DAO's signer. Require a
        // guardian (a cancel-only safety net) before it can even be proposed.
        assert!(
            std::option::is_some(&charter::get_guardian(dao_address)),
            error::invalid_state(E_NO_GUARDIAN)
        );
        // Gate (create): the script must be in the DAO's allow-list.
        assert!(
            vault::is_approved(dao_address, script_id),
            error::invalid_state(E_SCRIPT_NOT_ALLOWED)
        );
        // The execution hash is the library's immutable hash for this id; the
        // args commitment is keccak256(args) (32 bytes).
        let execution_hash = library::get_execution_hash(script_id);
        assert!(vector::length(&execution_hash) == 32, error::invalid_argument(E_INVALID_HASH_LENGTH));
        assert!(vector::length(&args_commitment) == 32, error::invalid_argument(E_INVALID_HASH_LENGTH));

        // Enforce static vs dynamic consistency against library registry
        let empty_commitment = aptos_hash::keccak256(vector::empty<u8>());
        if (library::has_args(script_id)) {
            assert!(args_commitment != empty_commitment, error::invalid_argument(E_PARAMETERIZED_SCRIPT_EMPTY_ARGS));
        } else {
            assert!(args_commitment == empty_commitment, error::invalid_argument(E_STATIC_SCRIPT_HAS_ARGS));
        };

        let (proposer_addr, ve_token_addr, start_time, end_time, proposal_id, quorum_required) = 
            validate_and_prepare_proposal(proposer, legacy_addr, dao_address, true); // Script proposals require super quorum

        let new_proposal = ledger::new_script_proposal(
            proposal_id,
            proposer_addr,
            ve_token_addr,
            title,
            description_hash,
            start_time,
            end_time,
            quorum_required,
            execution_hash,
            args_commitment,
            script_id,
        );
        ledger::add_proposal(dao_address, proposal_id, new_proposal);

        emit_proposal_event(
            dao_address, proposal_id, proposer_addr, title, 9, start_time, end_time,
            @0x0, @0x0, @0x0, script_id, 0, 0, description_hash, execution_hash, args_commitment
        );
    }



    /// Type 10: add/remove a script id from the DAO's allow-list (vault).
    /// Super quorum: the allow-list is what enables script execution.
    public entry fun propose_script_allow(
        proposer: &signer,
        legacy_addr: address,
        dao_address: address,
        title: String,
        description_hash: vector<u8>,
        script_id: u64,
        add: bool,
    ) acquires HeraldState {
        assert!(library::script_exists(script_id), error::invalid_argument(E_SCRIPT_NOT_FOUND));

        let (proposer_addr, ve_token_addr, start_time, end_time, proposal_id, quorum_required) =
            validate_and_prepare_proposal(proposer, legacy_addr, dao_address, true); // super quorum

        let new_proposal = ledger::new_script_allow_proposal(
            proposal_id,
            proposer_addr,
            ve_token_addr,
            title,
            description_hash,
            start_time,
            end_time,
            quorum_required,
            script_id,
            add,
        );
        ledger::add_proposal(dao_address, proposal_id, new_proposal);

        emit_proposal_event(
            dao_address, proposal_id, proposer_addr, title, 10, start_time, end_time,
            @0x0, @0x0, @0x0, script_id, 0, (if (add) 1 else 0), description_hash, vector::empty(), vector::empty()
        );
    }

    // --- Helpers for Deduplication ---

    fun emit_proposal_event(
        dao_address: address, proposal_id: u64, proposer: address, title: String, proposal_type: u8, start_time: u64, end_time: u64,
        action_target_address: address, action_asset_address: address, action_recipient: address, action_amount: u64, action_config_key: u64, action_config_value: u64,
        description_hash: vector<u8>, execution_hash: vector<u8>, args_commitment: vector<u8>
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
            description_hash,
            execution_hash,
            args_commitment,
        });
    }
}
