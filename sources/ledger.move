module dao_factory::ledger {
    friend dao_factory::witness;
    friend dao_factory::anchor;
    friend dao_factory::herald;
    friend dao_factory::petra;
    friend dao_factory::legacy;
    
    use std::string::String;
    use std::error;
    use std::vector;
    use std::signer;
    use supra_framework::timestamp;
    use supra_framework::account::{Self, SignerCapability};
    use aptos_std::smart_table::{Self, SmartTable};
    use supra_framework::event;

    const E_PROPOSAL_NOT_FOUND: u64 = 4;
    const E_INVALID_LABEL: u64 = 5;
    const E_NOT_FOUND: u64 = 6;
    const E_ALREADY_EXECUTED: u64 = 7;
    const E_PERMISSION_DENIED: u64 = 8;

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
        upgrade_code: vector<vector<u8>>,
        quorum_required: u64,
        proposal_type: u8, // 0 = Upgrade, 1 = Treasury, 2 = Config, 3 = Gauge
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
        capabilities: SmartTable<address, SignerCapability>, // The Vault
        account_labels: SmartTable<address, String>, // On-Chain Labels
    }

    struct PendingOffer has store {
        cap: SignerCapability,
        label: String,
        offerer: address,
    }

    struct OffersVault has key {
        offers: SmartTable<address, PendingOffer>
    }

    // --- EVENTS ---

    #[event]
    struct CapabilityOffered has drop, store {
        dao_address: address,
        target_address: address,
        offerer: address,
        label: String,
    }

    #[event]
    struct CapabilityOfferCanceled has drop, store {
        dao_address: address,
        target_address: address,
        offerer: address,
    }

    // Constructor for the initial table
    public(friend) fun initialize(dao_signer: &signer, signer_cap: SignerCapability) {
        move_to(dao_signer, DaoState {
            signer_cap,
            proposals: smart_table::new(),
            recent_participations: vector::empty<u128>(),
            recorded_proposals: smart_table::new(),
            capabilities: smart_table::new(),
            account_labels: smart_table::new(),
        });
        
        move_to(dao_signer, OffersVault {
            offers: smart_table::new()
        });
    }

    // Saves a new proposal in the DAO state
    public(friend) fun add_proposal(dao_address: address, proposal_id: u64, proposal: Proposal) acquires DaoState {
        let dao_state = borrow_global_mut<DaoState>(dao_address);
        smart_table::add(&mut dao_state.proposals, proposal_id, proposal);
    }

    // ==========================================
    // CAPABILITIES VAULT & REGISTRY
    // ==========================================

    // Validates that a label only contains safe ASCII characters to prevent homograph attacks
    fun is_valid_label(label: &String): bool {
        let bytes = std::string::bytes(label);
        let len = vector::length(bytes);
        if (len == 0 || len > 32) return false;
        
        let i = 0;
        while (i < len) {
            let b = *vector::borrow(bytes, i);
            let is_valid = 
                (b >= 48 && b <= 57) || // 0-9
                (b >= 65 && b <= 90) || // A-Z
                (b >= 97 && b <= 122) || // a-z
                (b == 32) || // Space
                (b == 45) || // Hyphen -
                (b == 95);   // Underscore _
                
            if (!is_valid) return false;
            i = i + 1;
        };
        true
    }

    // Only the DAO itself (via a passed proposal script) can deposit a capability into its vault.
    public fun deposit_capability(dao_signer: &signer, signer_cap: SignerCapability, label: String) acquires DaoState {
        assert!(is_valid_label(&label), error::invalid_argument(E_INVALID_LABEL));
        let dao_address = signer::address_of(dao_signer);
        let state = borrow_global_mut<DaoState>(dao_address);
        let target_address = account::get_signer_capability_address(&signer_cap);
        smart_table::add(&mut state.capabilities, target_address, signer_cap);
        smart_table::add(&mut state.account_labels, target_address, label);
    }

    #[view]
    public fun has_capability(dao_address: address, target_address: address): bool acquires DaoState {
        if (!exists<DaoState>(dao_address)) return false;
        
        // The DAO always has its own capability natively in state.signer_cap
        if (dao_address == target_address) return true;
        
        let state = borrow_global<DaoState>(dao_address);
        smart_table::contains(&state.capabilities, target_address)
    }

    // View function to safely get the official label of an external account
    #[view]
    public fun get_account_label(dao_address: address, target_address: address): String acquires DaoState {
        let state = borrow_global<DaoState>(dao_address);
        if (smart_table::contains(&state.account_labels, target_address)) {
            *smart_table::borrow(&state.account_labels, target_address)
        } else {
            std::string::utf8(b"Unknown Account")
        }
    }

    // --- OFFER / CLAIM CAPABILITY SYSTEM ---

    // Developers call this to offer their contract's capability to the DAO
    public fun offer_capability(offerer: &signer, dao_address: address, cap: SignerCapability, label: String) acquires OffersVault {
        assert!(is_valid_label(&label), error::invalid_argument(E_INVALID_LABEL));
        assert!(exists<OffersVault>(dao_address), error::invalid_state(E_NOT_FOUND));
        
        let vault = borrow_global_mut<OffersVault>(dao_address);
        let target_address = account::get_signer_capability_address(&cap);
        
        // Ensure no previous offer exists for this address
        assert!(!smart_table::contains(&vault.offers, target_address), error::already_exists(E_ALREADY_EXECUTED));
        
        smart_table::add(&mut vault.offers, target_address, PendingOffer {
            cap,
            label,
            offerer: signer::address_of(offerer)
        });

        event::emit(CapabilityOffered {
            dao_address,
            target_address,
            offerer: signer::address_of(offerer),
            label,
        });
    }

    // Developers can retract their capability if they change their mind before the DAO claims it
    public fun cancel_offer(offerer: &signer, dao_address: address, target_address: address): SignerCapability acquires OffersVault {
        assert!(exists<OffersVault>(dao_address), error::invalid_state(E_NOT_FOUND));
        let vault = borrow_global_mut<OffersVault>(dao_address);
        assert!(smart_table::contains(&vault.offers, target_address), error::not_found(E_NOT_FOUND));
        
        let PendingOffer { cap, label: _, offerer: original_offerer } = smart_table::remove(&mut vault.offers, target_address);
        assert!(signer::address_of(offerer) == original_offerer, error::permission_denied(E_PERMISSION_DENIED));
        
        event::emit(CapabilityOfferCanceled {
            dao_address,
            target_address,
            offerer: original_offerer,
        });

        cap
    }

    // The DAO executes this function via Proposal Type 6 to pull the capability from the pending vault into the main vault
    public(friend) fun claim_capability(dao_address: address, target_address: address) acquires OffersVault, DaoState {
        assert!(exists<OffersVault>(dao_address), error::invalid_state(E_NOT_FOUND));
        let vault = borrow_global_mut<OffersVault>(dao_address);
        assert!(smart_table::contains(&vault.offers, target_address), error::not_found(E_NOT_FOUND));
        
        let PendingOffer { cap, label, offerer: _ } = smart_table::remove(&mut vault.offers, target_address);
        
        let state = borrow_global_mut<DaoState>(dao_address);
        smart_table::add(&mut state.capabilities, target_address, cap);
        smart_table::add(&mut state.account_labels, target_address, label);
    }

    // --- VIEW FUNCTIONS FOR OFFERS VAULT ---

    #[view]
    public fun get_pending_offer_details(dao_address: address, target_address: address): (bool, String, address) acquires OffersVault {
        if (!exists<OffersVault>(dao_address)) {
            return (false, std::string::utf8(b""), @0x0)
        };
        
        let vault = borrow_global<OffersVault>(dao_address);
        if (smart_table::contains(&vault.offers, target_address)) {
            let offer = smart_table::borrow(&vault.offers, target_address);
            (true, offer.label, offer.offerer)
        } else {
            (false, std::string::utf8(b""), @0x0)
        }
    }

    // Generates a signer for an external contract using its stored capability
    public(friend) fun generate_external_signer(dao_address: address, target_address: address): signer acquires DaoState {
        let state = borrow_global<DaoState>(dao_address);
        assert!(smart_table::contains(&state.capabilities, target_address), error::not_found(E_PROPOSAL_NOT_FOUND));
        let cap = smart_table::borrow(&state.capabilities, target_address);
        account::create_signer_with_capability(cap)
    }

    // Setters & Internal Mutations (Friend Modules) 

    public(friend) fun set_proposal_eta(dao_address: address, proposal_id: u64, eta: u64) acquires DaoState { 
        let state = borrow_global_mut<DaoState>(dao_address);
        smart_table::borrow_mut(&mut state.proposals, proposal_id).eta = eta; 
    }
    public(friend) fun set_proposal_executed(dao_address: address, proposal_id: u64) acquires DaoState { 
        let state = borrow_global_mut<DaoState>(dao_address);
        smart_table::borrow_mut(&mut state.proposals, proposal_id).executed = true; 
    }
    public(friend) fun set_proposal_canceled(dao_address: address, proposal_id: u64) acquires DaoState { 
        let state = borrow_global_mut<DaoState>(dao_address);
        let p = smart_table::borrow_mut(&mut state.proposals, proposal_id);
        p.canceled = true; 
        p.eta = 0; 
    }
    public(friend) fun set_proposal_end_time(dao_address: address, proposal_id: u64, end_time: u64) acquires DaoState { 
        let state = borrow_global_mut<DaoState>(dao_address);
        smart_table::borrow_mut(&mut state.proposals, proposal_id).end_time = end_time; 
    }
    public(friend) fun set_quorum_reached(dao_address: address, proposal_id: u64) acquires DaoState { 
        let state = borrow_global_mut<DaoState>(dao_address);
        smart_table::borrow_mut(&mut state.proposals, proposal_id).quorum_reached_historically = true; 
    }
    public(friend) fun add_for_votes(dao_address: address, proposal_id: u64, weight: u64) acquires DaoState { 
        let state = borrow_global_mut<DaoState>(dao_address);
        let p = smart_table::borrow_mut(&mut state.proposals, proposal_id);
        p.for_votes = p.for_votes + weight; 
    }
    public(friend) fun add_against_votes(dao_address: address, proposal_id: u64, weight: u64) acquires DaoState { 
        let state = borrow_global_mut<DaoState>(dao_address);
        let p = smart_table::borrow_mut(&mut state.proposals, proposal_id);
        p.against_votes = p.against_votes + weight; 
    }
    public(friend) fun add_abstain_votes(dao_address: address, proposal_id: u64, weight: u64) acquires DaoState { 
        let state = borrow_global_mut<DaoState>(dao_address);
        let p = smart_table::borrow_mut(&mut state.proposals, proposal_id);
        p.abstain_votes = p.abstain_votes + weight; 
    }

    // Extracts the arguments for a Treasury Transfer proposal (asset_address, recipient, amount)
    public(friend) fun extract_proposal_action_treasury(dao_address: address, proposal_id: u64): (address, address, u64) acquires DaoState {
        let dao_state = borrow_global<DaoState>(dao_address);
        let proposal = smart_table::borrow(&dao_state.proposals, proposal_id);
        (proposal.action_target_address, proposal.action_recipient, proposal.action_amount)
    }

    // Extracts the arguments for a NFT Transfer proposal (nft_address, recipient)
    public(friend) fun extract_proposal_action_nft(dao_address: address, proposal_id: u64): (address, address) acquires DaoState {
        let dao_state = borrow_global<DaoState>(dao_address);
        let proposal = smart_table::borrow(&dao_state.proposals, proposal_id);
        (proposal.action_target_address, proposal.action_recipient)
    }

    // Extracts the arguments for a Guardian Update proposal (new_guardian)
    public(friend) fun extract_proposal_action_guardian(dao_address: address, proposal_id: u64): address acquires DaoState {
        let dao_state = borrow_global<DaoState>(dao_address);
        let proposal = smart_table::borrow(&dao_state.proposals, proposal_id);
        proposal.action_target_address
    }

    // Gets the upgrade code data (deep copies) + target address
    public(friend) fun get_proposal_upgrade_data(dao_address: address, proposal_id: u64): (vector<u8>, vector<vector<u8>>, address) acquires DaoState {
        let state = borrow_global<DaoState>(dao_address);
        let p = smart_table::borrow(&state.proposals, proposal_id);
        (*&p.upgrade_metadata, *&p.upgrade_code, p.action_target_address)
    }
    
    public(friend) fun get_proposal_quorum_reached(dao_address: address, proposal_id: u64): bool acquires DaoState {
        let state = borrow_global<DaoState>(dao_address);
        smart_table::borrow(&state.proposals, proposal_id).quorum_reached_historically
    }



    // Manual proposal constructor for Claim Capability action
    public(friend) fun new_claim_capability_proposal(
        id: u64,
        proposer: address,
        proposer_ve_token: address,
        title: String,
        description_hash: vector<u8>,
        start_time: u64,
        end_time: u64,
        quorum_required: u64,
        target_address: address,
    ): Proposal {
        Proposal {
            id, proposer, proposer_ve_token, title, description_hash, start_time, end_time, eta: 0,
            executed: false, canceled: false, quorum_reached_historically: false,
            for_votes: 0, against_votes: 0, abstain_votes: 0,
            upgrade_metadata: vector::empty(), upgrade_code: vector::empty(), quorum_required,
            proposal_type: 6, // Claim Capability Type
            action_recipient: @0x0,
            action_amount: 0,
            action_config_key: 0,
            action_config_value: 0,
            action_target_address: target_address,
        }
    }

    // Manual proposal constructor for the herald module
    public(friend) fun new_proposal(
        id: u64,
        proposer: address,
        proposer_ve_token: address,
        title: String,
        description_hash: vector<u8>,
        start_time: u64,
        end_time: u64,
        upgrade_metadata: vector<u8>,
        upgrade_code: vector<vector<u8>>,
        quorum_required: u64,
        target_address: address
    ): Proposal {
        Proposal {
            id, proposer, proposer_ve_token, title, description_hash, start_time, end_time, eta: 0,
            executed: false, canceled: false, quorum_reached_historically: false,
            for_votes: 0, against_votes: 0, abstain_votes: 0,
            upgrade_metadata, upgrade_code, quorum_required,
            proposal_type: 0,
            action_recipient: @0x0,
            action_amount: 0,
            action_config_key: 0,
            action_config_value: 0,
            action_target_address: target_address,
        }
    }

    // Manual proposal constructor for Treasury action
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
        Proposal {
            id, proposer, proposer_ve_token, title, description_hash, start_time, end_time, eta: 0,
            executed: false, canceled: false, quorum_reached_historically: false,
            for_votes: 0, against_votes: 0, abstain_votes: 0,
            upgrade_metadata: vector::empty(), upgrade_code: vector::empty(), quorum_required,
            proposal_type: 1,
            action_recipient: recipient,
            action_amount: amount,
            action_config_key: 0,
            action_config_value: 0,
            action_target_address: asset_address,
        }
    }

    // Manual proposal constructor for NFT Transfer action
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
        Proposal {
            id, proposer, proposer_ve_token, title, description_hash, start_time, end_time, eta: 0,
            executed: false, canceled: false, quorum_reached_historically: false,
            for_votes: 0, against_votes: 0, abstain_votes: 0,
            upgrade_metadata: vector::empty(), upgrade_code: vector::empty(), quorum_required,
            proposal_type: 5,
            action_recipient: recipient,
            action_amount: 1,
            action_config_key: 0,
            action_config_value: 0,
            action_target_address: nft_address,
        }
    }

    // Manual proposal constructor for Config action
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
        Proposal {
            id, proposer, proposer_ve_token, title, description_hash, start_time, end_time, eta: 0,
            executed: false, canceled: false, quorum_reached_historically: false,
            for_votes: 0, against_votes: 0, abstain_votes: 0,
            upgrade_metadata: vector::empty(), upgrade_code: vector::empty(), quorum_required,
            proposal_type: 2,
            action_recipient: @0x0,
            action_amount: 0,
            action_config_key: config_key,
            action_config_value: config_value,
            action_target_address: @0x0,
        }
    }

    // Manual proposal constructor for Guardian Update action
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
        Proposal {
            id, proposer, proposer_ve_token, title, description_hash, start_time, end_time, eta: 0,
            executed: false, canceled: false, quorum_reached_historically: false,
            for_votes: 0, against_votes: 0, abstain_votes: 0,
            upgrade_metadata: vector::empty(), upgrade_code: vector::empty(), quorum_required,
            proposal_type: 4,
            action_recipient: @0x0,
            action_amount: 0,
            action_config_key: 0,
            action_config_value: 0,
            action_target_address: new_guardian,
        }
    }

    // Manual proposal constructor for Gauge action
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
        Proposal {
            id, proposer, proposer_ve_token, title, description_hash, start_time, end_time, eta: 0,
            executed: false, canceled: false, quorum_reached_historically: false,
            for_votes: 0, against_votes: 0, abstain_votes: 0,
            upgrade_metadata: vector::empty(), upgrade_code: vector::empty(), quorum_required,
            proposal_type: 3,
            action_recipient: @0x0,
            action_amount: 0,
            action_config_key: action_type,
            action_config_value: gauge_id,
            action_target_address: target_address,
        }
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
        let dao_state = borrow_global<DaoState>(dao_address);
        assert!(smart_table::contains(&dao_state.proposals, proposal_id), error::not_found(E_PROPOSAL_NOT_FOUND));
        
        let proposal = smart_table::borrow(&dao_state.proposals, proposal_id);
        let current_time = timestamp::now_seconds();
        
        if (proposal.canceled) { return 2u8 }; // Canceled
        if (proposal.executed) { return 6u8 }; // Executed
        if (proposal.eta != 0) { return 5u8 }; // Queued (Timelock)
        
        if (current_time < proposal.start_time) { return 0u8 }; // Pending
        if (current_time <= proposal.end_time) { return 1u8 }; // Active
        
        let total_supporting = proposal.for_votes;
        let quorum_reached = total_supporting >= proposal.quorum_required;

        if (quorum_reached && proposal.for_votes > proposal.against_votes) {
            4u8 // Succeeded
        } else {
            3u8 // Defeated
        }
    }

    // Returns the public details of the proposal
    #[view]
    public fun get_proposal_details(dao_address: address, proposal_id: u64): (address, u64, u64, u64, bool, bool, u64, u64, u64) acquires DaoState {
        let dao_state = borrow_global<DaoState>(dao_address);
        assert!(smart_table::contains(&dao_state.proposals, proposal_id), error::not_found(E_PROPOSAL_NOT_FOUND));
        let proposal = smart_table::borrow(&dao_state.proposals, proposal_id);
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
        let dao_state = borrow_global<DaoState>(dao_address);
        assert!(smart_table::contains(&dao_state.proposals, proposal_id), error::not_found(E_PROPOSAL_NOT_FOUND));
        smart_table::borrow(&dao_state.proposals, proposal_id).proposer_ve_token
    }

    // Returns the snapshot quorum required for a proposal
    #[view]
    public fun get_proposal_quorum(dao_address: address, proposal_id: u64): u64 acquires DaoState {
        let dao_state = borrow_global<DaoState>(dao_address);
        assert!(smart_table::contains(&dao_state.proposals, proposal_id), error::not_found(E_PROPOSAL_NOT_FOUND));
        smart_table::borrow(&dao_state.proposals, proposal_id).quorum_required
    }

    #[view]
    public fun get_proposal_type(dao_address: address, proposal_id: u64): u8 acquires DaoState {
        let dao_state = borrow_global<DaoState>(dao_address);
        assert!(smart_table::contains(&dao_state.proposals, proposal_id), error::not_found(E_PROPOSAL_NOT_FOUND));
        smart_table::borrow(&dao_state.proposals, proposal_id).proposal_type
    }

    #[view]
    public fun get_proposal_action_treasury(dao_address: address, proposal_id: u64): (address, u64) acquires DaoState {
        let dao_state = borrow_global<DaoState>(dao_address);
        assert!(smart_table::contains(&dao_state.proposals, proposal_id), error::not_found(E_PROPOSAL_NOT_FOUND));
        let proposal = smart_table::borrow(&dao_state.proposals, proposal_id);
        (proposal.action_recipient, proposal.action_amount)
    }

    #[view]
    public fun get_proposal_action_config(dao_address: address, proposal_id: u64): (u8, u64) acquires DaoState {
        let dao_state = borrow_global<DaoState>(dao_address);
        assert!(smart_table::contains(&dao_state.proposals, proposal_id), error::not_found(E_PROPOSAL_NOT_FOUND));
        let proposal = smart_table::borrow(&dao_state.proposals, proposal_id);
        (proposal.action_config_key, proposal.action_config_value)
    }

    #[view]
    public fun get_proposal_action_gauge(dao_address: address, proposal_id: u64): (u8, address, u64) acquires DaoState {
        let dao_state = borrow_global<DaoState>(dao_address);
        assert!(smart_table::contains(&dao_state.proposals, proposal_id), error::not_found(E_PROPOSAL_NOT_FOUND));
        let proposal = smart_table::borrow(&dao_state.proposals, proposal_id);
        (proposal.action_config_key, proposal.action_target_address, proposal.action_config_value)
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
}
