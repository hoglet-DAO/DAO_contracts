// Proposal Voting Module.
//
// Allows veToken holders to cast votes on active proposals.
// The voting weight is calculated with the ve(3,3) formula:
//   Weight = Amount * (EpochsLeft / MAX_LOCK_EPOCHS)
//
// Voting power is read from the epoch PREVIOUS to the vote to prevent
// manipulation (buy power, vote, sell in the same block).
//
// Supports Late Quorum Extension (GovernorPreventLateQuorum) to prevent
// last-minute sniping.
//
// Supports delegation: a delegate registered in legacy can vote with the
// veToken power without being the owner of the NFT.
module dao_factory::witness {
    friend dao_factory::petra;
    use std::signer;
    use std::error;
    use supra_framework::timestamp;
    use supra_framework::event;

    use aptos_std::smart_table::{Self, SmartTable};

    use dao_factory::ledger;
    use dao_factory::legacy;
    use dao_factory::charter;
    use dao_factory::pilgrim;
    use dao_factory::sentinel;

    // Errors 
    const E_NOT_AUTHORIZED: u64     = 1;
    const E_ZERO_POWER: u64         = 2;
    const E_INVALID_SUPPORT: u64    = 3;
    const E_PROPOSAL_NOT_ACTIVE: u64 = 4;
    const E_ALREADY_VOTED: u64      = 5;
    const E_LOCK_EXPIRED: u64       = 6;
    const E_NOT_OBJECT: u64         = 7;
    const E_DAO_NOT_ACTIVE: u64     = 8;

    // Structs 

    // Registry of cast votes to prevent double voting.
    // Indexed by proposal_id = ve_token_address.
    struct VoteRegistry has key {
        // proposal_id = SmartTable(ve_token_address = voted)
        votes: SmartTable<u64, SmartTable<address, bool>>,
    }

    // Events 
    #[event]
    struct VoteCast has drop, store {
        dao_address: address,
        proposal_id: u64,
        voter: address,
        legacy: address,
        support: u8,
        weight: u64,
        // Updated totals after the vote (for indexers)
        total_for: u64,
        total_against: u64,
        total_abstain: u64,
    }

    #[event]
    struct LateQuorumExtended has drop, store {
        dao_address: address,
        proposal_id: u64,
        old_end_time: u64,
        new_end_time: u64,
    }

    // Initialization 
    // Initializes the vote registry. Called by petra when creating the DAO.
    public(friend) fun initialize(dao_signer: &signer) {
        move_to(dao_signer, VoteRegistry {
            votes: smart_table::new(),
        });
    }

    // Functions 

    // Casts a vote on an active proposal using the power of a veToken.
    //
    // # Arguments
    // - `voter`: The signer (must be owner of the veToken OR a registered delegate).
    // - `ve_token_obj`: The veToken NFT with voting power.
    // - `dao_address`: Address of the DAO's resource account.
    // - `proposal_id`: ID of the proposal to vote on.
    // - `support`: 0 = Against, 1 = For, 2 = Abstain.
    //
    // # Anti-manipulation
    // Voting power is calculated with the PREVIOUS epoch (now - 1), not the current one.
    // This prevents someone from locking tokens and voting in the same block.
    public entry fun cast_vote(
        voter: &signer,
        legacy_addr: address,
        dao_address: address,
        proposal_id: u64,
        support: u8,
    ) acquires VoteRegistry {
        assert!(support <= 2, error::invalid_argument(E_INVALID_SUPPORT));
        assert!(supra_framework::object::is_object(legacy_addr), error::invalid_argument(E_NOT_OBJECT));
        let ve_token_obj = supra_framework::object::address_to_object<legacy::VeToken>(legacy_addr);

        // Sentinel: cast_vote is pausable
        sentinel::assert_not_paused(dao_address);

        // DAO Activation Lock: Only active DAOs allow votes
        assert!(charter::is_active(dao_address), error::permission_denied(E_DAO_NOT_ACTIVE));

        let voter_addr = signer::address_of(voter);
        let ve_addr = supra_framework::object::object_address(&ve_token_obj);

        // The voter must be the owner of the veToken OR a registered delegate.
        let is_owner = supra_framework::object::is_owner(ve_token_obj, voter_addr);
        let is_delegate = legacy::is_delegate(ve_token_obj, voter_addr);
        assert!(is_owner || is_delegate, error::permission_denied(E_NOT_AUTHORIZED));

        // ANTI-EXPLOIT: Ensure the veToken being used belongs to this DAO
        assert!(
            legacy::get_dao_address(ve_token_obj) == dao_address, 
            error::invalid_argument(E_NOT_AUTHORIZED)
        );

        // The veToken cannot be expired.
        assert!(!legacy::is_expired(ve_token_obj), error::invalid_state(E_LOCK_EXPIRED));

        // Verify that the proposal is active.
        let (_, start_time, end_time, _, _, _, _, _, _) = ledger::get_proposal_details(dao_address, proposal_id);
        let current_time = timestamp::now_seconds();
        assert!(
            current_time >= start_time && 
            current_time <= end_time,
            error::invalid_state(E_PROPOSAL_NOT_ACTIVE)
        );

        // Anti-double-vote: verify by Object Address (not by wallet).
        // This prevents someone from transferring the veToken and voting twice.
        let registry = borrow_global_mut<VoteRegistry>(dao_address);
        if (!smart_table::contains(&registry.votes, proposal_id)) {
            smart_table::add(&mut registry.votes, proposal_id, smart_table::new());
        };
        let prop_votes = smart_table::borrow_mut(&mut registry.votes, proposal_id);
        assert!(!smart_table::contains(prop_votes, ve_addr), error::invalid_state(E_ALREADY_VOTED));
        smart_table::add(prop_votes, ve_addr, true);

        // Calculate voting power in the previous epoch (anti-flash-loan).
        let check_epoch = if (pilgrim::now() > 0) { pilgrim::now() - 1 } else { 0 };
        let weight = legacy::get_voting_power_at(ve_token_obj, check_epoch);
        assert!(weight > 0, error::invalid_state(E_ZERO_POWER));

        // Register vote in ledger using safe setters.
        if (support == 0)      { ledger::add_against_votes(dao_address, proposal_id, weight); }
        else if (support == 1) { ledger::add_for_votes(dao_address, proposal_id, weight); }
        else                   { ledger::add_abstain_votes(dao_address, proposal_id, weight); };

        // Late Quorum Extension (GovernorPreventLateQuorum) 
        // If quorum is reached near the end of the voting period,
        // extend the end_time to prevent last-minute sniping.
        if (!ledger::get_proposal_quorum_reached(dao_address, proposal_id)) {
            let quorum_required = ledger::get_proposal_quorum(dao_address, proposal_id);
            
            let (_, _, _, _, _, _, for_v, _, _) = ledger::get_proposal_details(dao_address, proposal_id);
            let total_supporting = for_v;
            
            if (total_supporting >= quorum_required) {
                ledger::set_quorum_reached(dao_address, proposal_id);
                
                let (_, _, end_t, _, _, _, _, _, _) = ledger::get_proposal_details(dao_address, proposal_id);
                let remaining = if (end_t > current_time) { end_t - current_time } else { 0 };
                let late_quorum = charter::get_late_quorum_extension(dao_address);
                
                if (remaining < late_quorum && late_quorum > 0) {
                    let new_end = current_time + late_quorum;
                    ledger::set_proposal_end_time(dao_address, proposal_id, new_end);
                    
                    event::emit(LateQuorumExtended {
                        dao_address,
                        proposal_id,
                        old_end_time: end_t,
                        new_end_time: new_end,
                    });
                };
            };
        };

        // Read updated totals for the event
        let (_, _, _, _, _, _, total_for, total_against, total_abstain) = ledger::get_proposal_details(dao_address, proposal_id);

        event::emit(VoteCast {
            dao_address,
            proposal_id,
            voter: voter_addr,
            legacy: ve_addr,
            support,
            weight,
            total_for,
            total_against,
            total_abstain,
        });
    }

    // View Function 
    #[view]
    public fun has_voted(
        dao_address: address,
        proposal_id: u64,
        ve_token_addr: address,
    ): bool acquires VoteRegistry {
        let registry = borrow_global<VoteRegistry>(dao_address);
        if (!smart_table::contains(&registry.votes, proposal_id)) return false;
        let prop_votes = smart_table::borrow(&registry.votes, proposal_id);
        smart_table::contains(prop_votes, ve_token_addr)
    }
}
