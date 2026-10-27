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
    const E_NOT_AN_NFT: u64 = 17;
    const E_INVALID_TARGET: u64 = 18;
    const E_NOT_BLESSED: u64 = 19;

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
        // Hash of the off-chain proposal metadata (title/description/discussion
        // link). It is already stored on-chain in `ledger::Proposal`, but
        // without emitting it here indexers cannot resolve it and every
        // proposal gets indexed with the "No description provided." default.
        description_hash: vector<u8>,
        // Hash of the compiled Move script bytecode (sha3-256) for type 8 proposals.
        // Empty for standard proposal types (1-7).
        execution_hash: vector<u8>,
        // keccak256 of the script args (32 bytes) for type 8 proposals; empty for
        // every other type. Lets indexers commit to the args without a view call.
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
        is_super_quorum: bool,
        proposal_type: u8
    ): (address, address, u64, u64, u64, u64, u64) acquires HeraldState {
        let proposer_addr = signer::address_of(proposer);

        assert!(object::is_object(legacy_addr), error::invalid_argument(E_NOT_OBJECT));
        let legacy = object::address_to_object<legacy::VeToken>(legacy_addr);

        // Sentinel: propose is pausable except for Type 4 (Guardian removal)
        if (proposal_type != 4) {
            sentinel::assert_not_paused(dao_address);
        };
        
        // DAO Activation Lock: Only active DAOs can accept proposals
        assert!(charter::is_active(dao_address), error::permission_denied(E_DAO_NOT_ACTIVE));

        // FIX (audit10 M3): blacklisted accounts cannot create proposals
        legacy::assert_not_blacklisted(dao_address, proposer_addr);

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
        let (start_time, end_time) = math::compute_proposal_window(timestamp::now_seconds(), voting_delay, voting_period);

        // Sequential ID.
        let proposal_id = charter::increment_proposal_count(dao_address);

        // Update latest proposal tracking
        smart_table::upsert(&mut herald_state.latest_proposals, proposer_addr, proposal_id);

        let ve_token_addr = object::object_address(&legacy);

        // Calculate dynamic quorum at the exact moment of proposal creation
        // FIX (audit H-03): Use total voting power (decayed ve-supply) at check_epoch,
        // so quorum required is evaluated in the exact same units as votes cast (veToken voting power)
        let total_power = legacy::get_total_voting_power_at(dao_address, check_epoch);
        
        let default_quorum = math::mul_div_u64(total_power, quorum_num, quorum_den);
        let dynamic_quorum = ledger::get_dynamic_quorum(dao_address, default_quorum);
        let quorum_required = math::compute_required_quorum(total_power, super_quorum_threshold, quorum_den, is_super_quorum, dynamic_quorum);
        
        (proposer_addr, ve_token_addr, start_time, end_time, proposal_id, quorum_required, check_epoch)
    }

    // Generic standard proposal entry point (types 1-7, 9).
    // Convenience wrappers for each proposal type live in dao_router::dao_proposals.
    public entry fun propose_standard(
        proposer: &signer,
        legacy_addr: address,
        dao_address: address,
        title: String,
        description_hash: vector<u8>,
        proposal_type: u8,
        proposal_data: vector<u8>,
        action_recipient: address,
        action_amount: u64,
        action_config_key: u8,
        action_config_value: u64,
        action_target_address: address,
        _event_target: address,
        _event_asset: address,
    ) acquires HeraldState {
        let (derived_target, derived_asset, is_super_quorum) = math::validate_standard_proposal_params(
            proposal_type, action_recipient, action_amount, action_config_key, action_target_address, E_INVALID_ACTION_TYPE
        );
        if (proposal_type == 9) {
            assert!(charter::is_blessed(dao_address), error::invalid_state(E_NOT_BLESSED));
        };

        create_proposal_internal(
            proposer, legacy_addr, dao_address, title, description_hash, is_super_quorum, proposal_type,
            proposal_data, action_recipient, action_amount, action_config_key, action_config_value,
            action_target_address, derived_target, derived_asset, vector::empty(), vector::empty()
        );
    }

    public entry fun propose_script(
        proposer: &signer,
        legacy_addr: address,
        dao_address: address,
        title: String,
        description_hash: vector<u8>,
        script_id: u64,
        args_commitment: vector<u8>,
    ) acquires HeraldState {
        assert!(
            std::option::is_some(&charter::get_guardian(dao_address)),
            error::invalid_state(E_NO_GUARDIAN)
        );
        assert!(charter::is_blessed(dao_address), error::invalid_state(E_NOT_BLESSED));
        assert!(
            vault::is_approved(dao_address, script_id),
            error::invalid_state(E_SCRIPT_NOT_ALLOWED)
        );
        let execution_hash = library::get_execution_hash(script_id);
        let empty_commitment = aptos_hash::keccak256(vector::empty<u8>());
        math::validate_script_proposal_hashes(
            &execution_hash,
            &args_commitment,
            library::has_args(script_id),
            empty_commitment,
            E_INVALID_HASH_LENGTH,
            E_PARAMETERIZED_SCRIPT_EMPTY_ARGS,
            E_STATIC_SCRIPT_HAS_ARGS
        );

        let packed = execution_hash;
        vector::append(&mut packed, args_commitment);

        create_proposal_internal(
            proposer, legacy_addr, dao_address, title, description_hash, true, 8,
            packed, @0x0, script_id, 0, 0, @0x0, @0x0, @0x0, execution_hash, args_commitment
        );
    }

    // --- Helper for Deduplication ---

    fun create_proposal_internal(
        proposer: &signer,
        legacy_addr: address,
        dao_address: address,
        title: String,
        description_hash: vector<u8>,
        is_super_quorum: bool,
        proposal_type: u8,
        proposal_data: vector<u8>,
        action_recipient: address,
        action_amount: u64,
        action_config_key: u8,
        action_config_value: u64,
        action_target_address: address,
        event_target: address,
        event_asset: address,
        execution_hash: vector<u8>,
        args_commitment: vector<u8>,
    ) acquires HeraldState {
        let (proposer_addr, ve_token_addr, start_time, end_time, proposal_id, quorum_required, snapshot_epoch) = 
            validate_and_prepare_proposal(proposer, legacy_addr, dao_address, is_super_quorum, proposal_type);

        let proposal = ledger::new_proposal(
            proposal_id, proposer_addr, ve_token_addr, title, description_hash, start_time, end_time,
            snapshot_epoch, quorum_required, proposal_type, proposal_data, action_recipient,
            action_amount, action_config_key, action_config_value, action_target_address
        );
        ledger::add_proposal(dao_address, proposal_id, proposal);
        event::emit(ProposalCreated {
            dao_address,
            proposal_id,
            proposer: proposer_addr,
            title,
            proposal_type,
            start_time,
            end_time,
            action_target_address: event_target,
            action_asset_address: event_asset,
            action_recipient,
            action_amount,
            action_config_key: (action_config_key as u64),
            action_config_value,
            description_hash,
            execution_hash,
            args_commitment,
        });
    }
}
