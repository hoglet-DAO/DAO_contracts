module dao_factory::ledger {
    friend dao_factory::witness;
    friend dao_factory::anchor;
    friend dao_factory::herald;
    friend dao_factory::petra;
    friend dao_factory::legacy;
    friend dao_factory::harvest;
    friend dao_factory::restore;
    friend dao_factory::foundry;
    
    use std::string::String;
    use std::error;
    use std::vector;
    use std::signer;
    use supra_framework::timestamp;
    use supra_framework::account::{Self, SignerCapability};
    use aptos_std::smart_table::{Self, SmartTable};

    const E_PROPOSAL_NOT_FOUND: u64 = 4;
    const E_NOT_FOUND: u64 = 6;
    const E_ALREADY_EXECUTED: u64 = 7;

    struct Proposal has store {
        id: u64,
        proposer: address,
        proposer_ve_token: address,
        title: String,
        description_hash: vector<u8>,
        start_time: u64,
        end_time: u64,
        eta: u64, 
        executed: bool,
        canceled: bool,
        quorum_reached_historically: bool,
        for_votes: u64,
        against_votes: u64,
        abstain_votes: u64,
        upgrade_metadata: vector<u8>,
        quorum_required: u64,
        proposal_type: u8, // 1 = Treasury, 2 = Config, 3 = Gauge, 4 = Guardian, 5 = NFT Transfer, 7 = Module Settings, 8 = NFT Boost Collection, 9 = Script Execution
        action_recipient: address,
        action_amount: u64,
        action_config_key: u8,
        action_config_value: u64,
        action_target_address: address,
    }

    struct DaoState has key {
        signer_cap: SignerCapability, 
        proposals: SmartTable<u64, Proposal>,
        recent_participations: vector<u128>,
        recorded_proposals: SmartTable<u64, bool>,
    }

    // Constructor for the initial table
    public(friend) fun initialize(dao_signer: &signer, signer_cap: SignerCapability) {
        move_to(dao_signer, DaoState {
            signer_cap,
            proposals: smart_table::new(),
            recent_participations: vector::empty<u128>(),
            recorded_proposals: smart_table::new(),
        });
    }

    // Saves a new proposal in the DAO state
    public(friend) fun add_proposal(dao_address: address, proposal_id: u64, proposal: Proposal) acquires DaoState {
        let dao_state = borrow_global_mut<DaoState>(dao_address);
        smart_table::add(&mut dao_state.proposals, proposal_id, proposal);
    }

    // Setters & Internal Mutations (Friend Modules) 

    public(friend) fun set_proposal_eta(dao_address: address, proposal_id: u64, eta: u64) acquires DaoState { 
        let state = borrow_global_mut<DaoState>(dao_address);
        get_proposal_mut_safe(state, proposal_id).eta = eta; 
    }
    public(friend) fun set_proposal_executed(dao_address: address, proposal_id: u64) acquires DaoState { 
        let state = borrow_global_mut<DaoState>(dao_address);
        get_proposal_mut_safe(state, proposal_id).executed = true; 
    }
    public(friend) fun set_proposal_canceled(dao_address: address, proposal_id: u64) acquires DaoState { 
        let state = borrow_global_mut<DaoState>(dao_address);
        let p = get_proposal_mut_safe(state, proposal_id);
        p.canceled = true; 
        p.eta = 0; 
    }
    public(friend) fun set_proposal_end_time(dao_address: address, proposal_id: u64, end_time: u64) acquires DaoState { 
        let state = borrow_global_mut<DaoState>(dao_address);
        get_proposal_mut_safe(state, proposal_id).end_time = end_time; 
    }
    public(friend) fun set_quorum_reached(dao_address: address, proposal_id: u64) acquires DaoState { 
        let state = borrow_global_mut<DaoState>(dao_address);
        get_proposal_mut_safe(state, proposal_id).quorum_reached_historically = true; 
    }
    public(friend) fun add_votes(dao_address: address, proposal_id: u64, support: u8, weight: u64) acquires DaoState { 
        let state = borrow_global_mut<DaoState>(dao_address);
        let p = get_proposal_mut_safe(state, proposal_id);
        if (support == 0) { p.against_votes = p.against_votes + weight; }
        else if (support == 1) { p.for_votes = p.for_votes + weight; }
        else { p.abstain_votes = p.abstain_votes + weight; };
    }

    // Extracts the arguments for a Treasury Transfer proposal (asset_address, recipient, amount)
    public(friend) fun extract_proposal_action_treasury(dao_address: address, proposal_id: u64): (address, address, u64) acquires DaoState {
        let state = borrow_global<DaoState>(dao_address);
        let proposal = get_proposal_safe(state, proposal_id);
        (proposal.action_target_address, proposal.action_recipient, proposal.action_amount)
    }

    // Extracts the arguments for a NFT Transfer proposal (nft_address, recipient)
    public(friend) fun extract_proposal_action_nft(dao_address: address, proposal_id: u64): (address, address) acquires DaoState {
        let state = borrow_global<DaoState>(dao_address);
        let proposal = get_proposal_safe(state, proposal_id);
        (proposal.action_target_address, proposal.action_recipient)
    }

    // Extracts the arguments for a Guardian Update proposal (new_guardian)
    public(friend) fun extract_proposal_action_guardian(dao_address: address, proposal_id: u64): address acquires DaoState {
        let state = borrow_global<DaoState>(dao_address);
        let proposal = get_proposal_safe(state, proposal_id);
        proposal.action_target_address
    }

    public(friend) fun get_proposal_quorum_reached(dao_address: address, proposal_id: u64): bool acquires DaoState {
        let state = borrow_global<DaoState>(dao_address);
        get_proposal_safe(state, proposal_id).quorum_reached_historically
    }

    // Shared proposal shell: fills every field with safe defaults so each
    // typed constructor below only specifies what distinguishes it.
    // Single source for the Proposal struct literal.
    fun new_proposal_base(
        id: u64,
        proposer: address,
        proposer_ve_token: address,
        title: String,
        description_hash: vector<u8>,
        start_time: u64,
        end_time: u64,
        quorum_required: u64,
        proposal_type: u8,
        upgrade_metadata: vector<u8>,
        action_recipient: address,
        action_amount: u64,
        action_config_key: u8,
        action_config_value: u64,
        action_target_address: address,
    ): Proposal {
        Proposal {
            id, proposer, proposer_ve_token, title, description_hash, start_time, end_time, eta: 0,
            executed: false, canceled: false, quorum_reached_historically: false,
            for_votes: 0, against_votes: 0, abstain_votes: 0,
            upgrade_metadata, quorum_required,
            proposal_type,
            action_recipient,
            action_amount,
            action_config_key,
            action_config_value,
            action_target_address,
        }
    }

    // Manual proposal constructor for Treasury action (type 1)
    public(friend) fun new_treasury_proposal(
        id: u64,
        proposer: address,
        proposer_ve_token: address,
        title: String,
        description_hash: vector<u8>,
        start_time: u64,
        end_time: u64,
        quorum_required: u64,
        asset_address: address,
        recipient: address,
        amount: u64
    ): Proposal {
        new_proposal_base(
            id, proposer, proposer_ve_token, title, description_hash, start_time, end_time,
            quorum_required, 1, vector::empty(), recipient, amount, 0, 0, asset_address
        )
    }

    // Manual proposal constructor for NFT Transfer action (type 5)
    public(friend) fun new_nft_proposal(
        id: u64,
        proposer: address,
        proposer_ve_token: address,
        title: String,
        description_hash: vector<u8>,
        start_time: u64,
        end_time: u64,
        quorum_required: u64,
        nft_address: address,
        recipient: address
    ): Proposal {
        new_proposal_base(
            id, proposer, proposer_ve_token, title, description_hash, start_time, end_time,
            quorum_required, 5, vector::empty(), recipient, 1, 0, 0, nft_address
        )
    }

    // Manual proposal constructor for Config action (type 2)
    public(friend) fun new_config_proposal(
        id: u64,
        proposer: address,
        proposer_ve_token: address,
        title: String,
        description_hash: vector<u8>,
        start_time: u64,
        end_time: u64,
        quorum_required: u64,
        config_key: u8,
        config_value: u64
    ): Proposal {
        new_proposal_base(
            id, proposer, proposer_ve_token, title, description_hash, start_time, end_time,
            quorum_required, 2, vector::empty(), @0x0, 0, config_key, config_value, @0x0
        )
    }

    // Manual proposal constructor for Module Settings (type 7)
    // Note: the string payload is stored in the upgrade_metadata field.
    public(friend) fun new_module_setting_proposal(
        id: u64,
        proposer: address,
        proposer_ve_token: address,
        title: String,
        description_hash: vector<u8>,
        start_time: u64,
        end_time: u64,
        quorum_required: u64,
        setting_type: u8,
        target_address: address,
        string_value: vector<u8>,
        bool_value: u64
    ): Proposal {
        new_proposal_base(
            id, proposer, proposer_ve_token, title, description_hash, start_time, end_time,
            quorum_required, 7, string_value, @0x0, 0, setting_type, bool_value, target_address
        )
    }

    // Manual proposal constructor for Guardian Update action (type 4)
    public(friend) fun new_guardian_proposal(
        id: u64,
        proposer: address,
        proposer_ve_token: address,
        title: String,
        description_hash: vector<u8>,
        start_time: u64,
        end_time: u64,
        quorum_required: u64,
        new_guardian: address
    ): Proposal {
        new_proposal_base(
            id, proposer, proposer_ve_token, title, description_hash, start_time, end_time,
            quorum_required, 4, vector::empty(), @0x0, 0, 0, 0, new_guardian
        )
    }

    // Manual proposal constructor for Gauge action (type 3)
    public(friend) fun new_gauge_proposal(
        id: u64,
        proposer: address,
        proposer_ve_token: address,
        title: String,
        description_hash: vector<u8>,
        start_time: u64,
        end_time: u64,
        quorum_required: u64,
        action_type: u8,
        target_address: address,
        gauge_id: u64
    ): Proposal {
        new_proposal_base(
            id, proposer, proposer_ve_token, title, description_hash, start_time, end_time,
            quorum_required, 3, vector::empty(), @0x0, 0, action_type, gauge_id, target_address
        )
    }

    // Manual proposal constructor for NFT Boost Collection action (type 8)
    public(friend) fun new_boost_proposal(
        id: u64,
        proposer: address,
        proposer_ve_token: address,
        title: String,
        description_hash: vector<u8>,
        start_time: u64,
        end_time: u64,
        quorum_required: u64,
        action_type: u8,
        collection_addr: address,
        boost_bps: u64
    ): Proposal {
        new_proposal_base(
            id, proposer, proposer_ve_token, title, description_hash, start_time, end_time,
            quorum_required, 8, vector::empty(), @0x0, 0, action_type, boost_bps, collection_addr
        )
    }

    // Manual proposal constructor for Script Execution action (type 9)
    // The 32-byte script execution hash is stored in the upgrade_metadata field.
    public(friend) fun new_script_proposal(
        id: u64,
        proposer: address,
        proposer_ve_token: address,
        title: String,
        description_hash: vector<u8>,
        start_time: u64,
        end_time: u64,
        quorum_required: u64,
        execution_hash: vector<u8>,
    ): Proposal {
        new_proposal_base(
            id, proposer, proposer_ve_token, title, description_hash, start_time, end_time,
            quorum_required, 9, execution_hash, @0x0, 0, 0, 0, @0x0
        )
    }

    // Generates a temporary signer using the master key (Only for friend modules)
    public(friend) fun generate_signer(dao_address: address): signer acquires DaoState {
        let state = borrow_global<DaoState>(dao_address);
        account::create_signer_with_capability(&state.signer_cap)
    }



    // ==========================================
    // VIEW FUNCTIONS (For the Frontend)
    // ==========================================

    // Returns the dynamic state of the proposal (emulating OpenZeppelin states)
    // 0: Pending, 1: Active, 2: Canceled, 3: Defeated, 4: Succeeded, 5: Queued, 6: Executed
    #[view]
    public fun get_proposal_state(dao_address: address, proposal_id: u64): u8 acquires DaoState {
        let state = borrow_global<DaoState>(dao_address);
        let proposal = get_proposal_safe(state, proposal_id);
        let current_time = timestamp::now_seconds();
        
        if (proposal.canceled) { return 2u8 }; // Canceled
        if (proposal.executed) { return 6u8 }; // Executed
        if (proposal.eta != 0) { return 5u8 }; // Queued (Timelock)
        
        if (current_time < proposal.start_time) { return 0u8 }; // Pending
        if (current_time <= proposal.end_time) { return 1u8 }; // Active
        
        let total_participation = proposal.for_votes + proposal.against_votes + proposal.abstain_votes;
        let quorum_reached = total_participation >= proposal.quorum_required;

        if (quorum_reached && proposal.for_votes > proposal.against_votes) {
            4u8 // Succeeded
        } else {
            3u8 // Defeated
        }
    }

    // Returns the public details of the proposal
    #[view]
    public fun get_proposal_details(dao_address: address, proposal_id: u64): (address, u64, u64, u64, bool, bool, u64, u64, u64) acquires DaoState {
        let state = borrow_global<DaoState>(dao_address);
        let proposal = get_proposal_safe(state, proposal_id);
        (
            proposal.proposer,
            proposal.start_time,
            proposal.end_time,
            proposal.eta,
            proposal.executed,
            proposal.canceled,
            proposal.for_votes,
            proposal.against_votes,
            proposal.abstain_votes
        )
    }

    // Returns the NFT address used to create the proposal
    #[view]
    public fun get_proposal_ve_token(dao_address: address, proposal_id: u64): address acquires DaoState {
        let state = borrow_global<DaoState>(dao_address);
        get_proposal_safe(state, proposal_id).proposer_ve_token
    }

    // Returns the snapshot quorum required for a proposal
    #[view]
    public fun get_proposal_quorum(dao_address: address, proposal_id: u64): u64 acquires DaoState {
        let state = borrow_global<DaoState>(dao_address);
        get_proposal_safe(state, proposal_id).quorum_required
    }

    #[view]
    public fun get_proposal_type(dao_address: address, proposal_id: u64): u8 acquires DaoState {
        let state = borrow_global<DaoState>(dao_address);
        get_proposal_safe(state, proposal_id).proposal_type
    }
    
    #[view]
    public fun get_proposal_action_treasury(dao_address: address, proposal_id: u64): (address, u64) acquires DaoState {
        let state = borrow_global<DaoState>(dao_address);
        let proposal = get_proposal_safe(state, proposal_id);
        (proposal.action_recipient, proposal.action_amount)
    }
    
    #[view]
    public fun get_proposal_action_config(dao_address: address, proposal_id: u64): (u8, u64) acquires DaoState {
        let state = borrow_global<DaoState>(dao_address);
        let proposal = get_proposal_safe(state, proposal_id);
        (proposal.action_config_key, proposal.action_config_value)
    }

    #[view]
    public fun get_proposal_action_gauge(dao_address: address, proposal_id: u64): (u8, address, u64) acquires DaoState {
        let state = borrow_global<DaoState>(dao_address);
        let proposal = get_proposal_safe(state, proposal_id);
        (proposal.action_config_key, proposal.action_target_address, proposal.action_config_value)
    }

    #[view]
    public fun get_proposal_action_module_setting(dao_address: address, proposal_id: u64): (u8, address, vector<u8>, u64) acquires DaoState {
        let state = borrow_global<DaoState>(dao_address);
        let proposal = get_proposal_safe(state, proposal_id);
        (proposal.action_config_key, proposal.action_target_address, *&proposal.upgrade_metadata, proposal.action_config_value)
    }

    #[view]
    public fun get_proposal_execution_hash(dao_address: address, proposal_id: u64): vector<u8> acquires DaoState {
        let state = borrow_global<DaoState>(dao_address);
        let proposal = get_proposal_safe(state, proposal_id);
        *&proposal.upgrade_metadata
    }

    // Dynamic Quorum (Rolling Average) 

    // Records the participation (total votes cast) of a finalized proposal.
    // Keeps a moving window of the last 5 participations.
    public(friend) fun record_participation(dao_address: address, proposal_id: u64, participation: u64) acquires DaoState {
        let state = borrow_global_mut<DaoState>(dao_address);
        if (smart_table::contains(&state.recorded_proposals, proposal_id)) {
            return
        };
        smart_table::add(&mut state.recorded_proposals, proposal_id, true);

        if (participation > 0) {
            vector::push_back(&mut state.recent_participations, (participation as u128));
            if (vector::length(&state.recent_participations) > 5) {
                vector::remove(&mut state.recent_participations, 0);
            };
        };
    }

    // Returns the dynamically calculated quorum (50% of the average recent participation).
    // If there is no history, returns the `default_quorum`.
    #[view]
    public fun get_dynamic_quorum(dao_address: address, default_quorum: u64): u64 acquires DaoState {
        let state = borrow_global<DaoState>(dao_address);
        let len = vector::length(&state.recent_participations);
        if (len == 0) {
            return default_quorum
        };

        let sum: u128 = 0;
        let i = 0;
        while (i < len) {
            sum = sum + *vector::borrow(&state.recent_participations, i);
            i = i + 1;
        };

        let avg = sum / (len as u128);
        let raw_dynamic_quorum = avg / 2; // 50% of the average recent participation
        
        // --- Smoothing (Volatility Clamp) ---
        // Prevents the quorum from jumping too aggressively from the default quorum.
        // The dynamic quorum can be at most 200% of the default quorum and at least 10% of the default quorum.
        
        let max_ceiling = ((default_quorum as u128) * 200) / 100;
        let min_floor = ((default_quorum as u128) * 10) / 100;
        
        if (min_floor == 0 && default_quorum > 0) {
            min_floor = 1;
        };

        let clamped_quorum = if (raw_dynamic_quorum > max_ceiling) {
            max_ceiling
        } else if (raw_dynamic_quorum < min_floor) {
            min_floor
        } else {
            raw_dynamic_quorum
        };

        (clamped_quorum as u64)
    }

    // --- Helpers for Deduplication ---

    fun get_proposal_safe(state: &DaoState, proposal_id: u64): &Proposal {
        assert!(smart_table::contains(&state.proposals, proposal_id), error::not_found(E_PROPOSAL_NOT_FOUND));
        smart_table::borrow(&state.proposals, proposal_id)
    }

    fun get_proposal_mut_safe(state: &mut DaoState, proposal_id: u64): &mut Proposal {
        assert!(smart_table::contains(&state.proposals, proposal_id), error::not_found(E_PROPOSAL_NOT_FOUND));
        smart_table::borrow_mut(&mut state.proposals, proposal_id)
    }
}
