// Gauges Module - Inflation Destinations
//
// Gauges are destinations (addresses) where the emission of new tokens is directed.
// The community votes each epoch to decide what percentage of the emission goes to each Gauge.
// The system uses Epoch Voting: votes are reset at the beginning of each epoch,
// guaranteeing that inflation always follows the current interest of the community.
module dao_factory::zeal {
    friend dao_factory::petra;
    friend dao_factory::jubilee;
    friend dao_factory::anchor;
    use std::signer;
    use supra_framework::fungible_asset::{Self, FungibleAsset, Metadata};
    use supra_framework::primary_fungible_store;
    use supra_framework::object::{Self, ExtendRef};
    use std::option::{Self, Option};

    use supra_framework::event;
    use std::error;
    use aptos_std::smart_table::{Self, SmartTable};
    use std::vector;
    
    use dao_factory::legacy;
    use dao_factory::pilgrim;
    use dao_factory::foundry;

    // Errors 
    const E_NOT_AUTHORIZED: u64  = 1;
    const E_INVALID_WEIGHTS: u64 = 2;
    const E_ALREADY_VOTED: u64   = 3;
    const E_INVALID_GAUGE: u64   = 4;
    const E_NOT_OWNER: u64       = 5;
    const E_LOCK_EXPIRED: u64    = 6;
    const E_VOTING_CLOSED: u64   = 7;
    const E_ZERO_POWER: u64      = 8;
    const E_NOT_OBJECT: u64      = 9;
    const E_ALREADY_CLAIMED: u64 = 10;
    const E_NO_EMISSIONS: u64    = 11;
    const E_INVALID_EPOCH: u64   = 12;

    // Structs 

    struct Gauge has store {
        destination: address,
        is_active: bool,
    }

    struct UserVote has store {
        gauge_ids: vector<u64>,
        powers: vector<u128>,
    }

    struct GaugeRegistry has key {
        // Sequential numeric ID -> Gauge Details
        gauges: SmartTable<u64, Gauge>,
        next_gauge_id: u64,
        
        // pilgrim -> (gauge_id -> total_votes)
        epoch_gauge_votes: SmartTable<u64, SmartTable<u64, u128>>,
        
        // pilgrim -> total_votes (sum of all gauges)
        epoch_total_votes: SmartTable<u64, u128>,
        
        // pilgrim -> (ve_token_addr -> UserVote)
        epoch_user_votes: SmartTable<u64, SmartTable<address, UserVote>>,
        
        // Vault object to hold undistributed emissions
        vault_extend_ref: ExtendRef,
        vault_address: address,

        // pilgrim -> total FA deposited for that epoch
        epoch_total_emissions: SmartTable<u64, u64>,
        
        // pilgrim -> (gauge_id -> bool)
        claimed_emissions: SmartTable<u64, SmartTable<u64, bool>>,

        // Default destination if no one votes in an epoch
        default_destination: address,
    }

    // Events 

    #[event]
    struct GaugeCreated has drop, store {
        dao_address: address,
        gauge_id: u64,
        destination: address,
    }

    #[event]
    struct Voted has drop, store {
        dao_address: address,
        pilgrim: u64,
        voter: address,
        legacy: address,
        power: u128,
    }

    #[event]
    struct EmissionsDistributed has drop, store {
        dao_address: address,
        pilgrim: u64,
        total_amount: u64,
    }

    #[event]
    struct GaugeEmissionClaimed has drop, store {
        dao_address: address,
        pilgrim: u64,
        gauge_id: u64,
        amount: u64,
    }

    #[event]
    struct GaugeStatusChanged has drop, store {
        dao_address: address,
        gauge_id: u64,
        is_active: bool,
    }

    // Initialization 

    public(friend) fun initialize(
        dao_signer: &signer,
        default_destination: address,
        amm_pool_address_opt: Option<address>,
    ) acquires GaugeRegistry {
        let constructor_ref = object::create_object(signer::address_of(dao_signer));

        move_to(dao_signer, GaugeRegistry {
            gauges: smart_table::new(),
            next_gauge_id: 0,
            epoch_gauge_votes: smart_table::new(),
            epoch_total_votes: smart_table::new(),
            epoch_user_votes: smart_table::new(),
            vault_extend_ref: object::generate_extend_ref(&constructor_ref),
            vault_address: object::address_from_constructor_ref(&constructor_ref),
            epoch_total_emissions: smart_table::new(),
            claimed_emissions: smart_table::new(),
            default_destination,
        });

        if (option::is_some(&amm_pool_address_opt)) {
            let pool_address = option::extract(&mut amm_pool_address_opt);
            create_gauge(dao_signer, pool_address);
        };
    }

    #[view]
    public fun is_initialized(dao_address: address): bool {
        exists<GaugeRegistry>(dao_address)
    }

    // Governance Functions 

    // Creates a new Gauge. Typically called through an approved proposal (`anchor`).
    public(friend) fun create_gauge(
        dao_signer: &signer,
        destination: address,
    ): u64 acquires GaugeRegistry {
        let dao_address = signer::address_of(dao_signer);
        let registry = borrow_global_mut<GaugeRegistry>(dao_address);
        
        let gauge_id = registry.next_gauge_id;
        smart_table::add(&mut registry.gauges, gauge_id, Gauge {
            destination,
            is_active: true,
        });
        registry.next_gauge_id = gauge_id + 1;

        event::emit(GaugeCreated { dao_address, gauge_id, destination });
        gauge_id
    }

    // Activates or deactivates a Gauge. Called by governance.
    public(friend) fun set_gauge_status(
        dao_signer: &signer,
        gauge_id: u64,
        is_active: bool,
    ) acquires GaugeRegistry {
        let dao_address = signer::address_of(dao_signer);
        let registry = borrow_global_mut<GaugeRegistry>(dao_address);
        assert!(smart_table::contains(&registry.gauges, gauge_id), error::invalid_argument(E_INVALID_GAUGE));
        
        let gauge = smart_table::borrow_mut(&mut registry.gauges, gauge_id);
        gauge.is_active = is_active;

        event::emit(GaugeStatusChanged {
            dao_address,
            gauge_id,
            is_active,
        });
    }

    // Core Functions 

    // Votes for one or more gauges assigning them weights.
    // Voting power is divided proportionally according to the indicated weights.
    public entry fun vote(
        voter: &signer,
        legacy_addr: address,
        dao_address: address,
        gauge_ids: vector<u64>,
        weights: vector<u64>,
    ) acquires GaugeRegistry {
        assert!(supra_framework::object::is_object(legacy_addr), error::invalid_argument(E_NOT_OBJECT));
        let ve_token_obj = supra_framework::object::address_to_object<legacy::VeToken>(legacy_addr);
        let voter_addr = signer::address_of(voter);
        assert!(supra_framework::object::is_owner(ve_token_obj, voter_addr), error::permission_denied(E_NOT_OWNER));
        assert!(!legacy::is_expired(ve_token_obj), error::invalid_state(E_LOCK_EXPIRED));
        assert!(legacy::get_dao_address(ve_token_obj) == dao_address, error::invalid_argument(E_NOT_AUTHORIZED));

        // Voter Lockout: Polls close 24 hours (86400 seconds) before the epoch ends
        // to prevent bribe sniping.
        assert!(pilgrim::seconds_until_next_epoch() > 86400, error::invalid_state(E_VOTING_CLOSED));
        
        let ve_addr = supra_framework::object::object_address(&ve_token_obj);
        let registry = borrow_global_mut<GaugeRegistry>(dao_address);
        let current_epoch = pilgrim::now();

        // Verify that they have not voted in this epoch (Epoch-based voting)
        if (!smart_table::contains(&registry.epoch_user_votes, current_epoch)) {
            smart_table::add(&mut registry.epoch_user_votes, current_epoch, smart_table::new());
        };
        let user_votes_table = smart_table::borrow_mut(&mut registry.epoch_user_votes, current_epoch);
        assert!(!smart_table::contains(user_votes_table, ve_addr), error::invalid_state(E_ALREADY_VOTED));

        // Validate arrays
        let len = vector::length(&gauge_ids);
        assert!(len == vector::length(&weights) && len > 0, error::invalid_argument(E_INVALID_WEIGHTS));
        
        let total_weight: u128 = 0;
        let i = 0;
        while (i < len) {
            let gid = *vector::borrow(&gauge_ids, i);
            assert!(smart_table::contains(&registry.gauges, gid), error::invalid_argument(E_INVALID_GAUGE));
            let g = smart_table::borrow(&registry.gauges, gid);
            assert!(g.is_active, error::invalid_state(E_INVALID_GAUGE));
            
            total_weight = total_weight + (*vector::borrow(&weights, i) as u128);
            i = i + 1;
        };
        assert!(total_weight > 0, error::invalid_argument(E_INVALID_WEIGHTS));

        // Obtain voting power (we use previous epoch to prevent flash loans).
        let check_epoch = if (current_epoch > 0) { current_epoch - 1 } else { 0 };
        let power = (legacy::get_voting_power_at(ve_token_obj, check_epoch) as u128);
        assert!(power > 0, error::invalid_state(E_ZERO_POWER));

        if (!smart_table::contains(&registry.epoch_gauge_votes, current_epoch)) {
            smart_table::add(&mut registry.epoch_gauge_votes, current_epoch, smart_table::new());
        };
        let gauge_votes_table = smart_table::borrow_mut(&mut registry.epoch_gauge_votes, current_epoch);

        let user_powers = vector::empty<u128>();

        i = 0;
        while (i < len) {
            let gid = *vector::borrow(&gauge_ids, i);
            let w = (*vector::borrow(&weights, i) as u128);
            let allocated_power = (power * w) / total_weight;
            
            vector::push_back(&mut user_powers, allocated_power);

            let current_votes = if (smart_table::contains(gauge_votes_table, gid)) {
                *smart_table::borrow(gauge_votes_table, gid)
            } else { 0 };
            
            smart_table::upsert(gauge_votes_table, gid, current_votes + allocated_power);
            i = i + 1;
        };

        // Register user vote
        smart_table::add(user_votes_table, ve_addr, UserVote {
            gauge_ids,
            powers: user_powers,
        });

        // Add to the global total of the epoch
        let current_total = if (smart_table::contains(&registry.epoch_total_votes, current_epoch)) {
            *smart_table::borrow(&registry.epoch_total_votes, current_epoch)
        } else { 0 };
        smart_table::upsert(&mut registry.epoch_total_votes, current_epoch, current_total + power);

        event::emit(Voted { dao_address, pilgrim: current_epoch, voter: voter_addr, legacy: ve_addr, power });
    }

    // Called by `jubilee` when advancing the epoch.
    // Dumps the emission destined for gauges into the vault for later claiming (Pull Architecture).
    public(friend) fun distribute_emissions(
        dao_address: address,
        target_epoch: u64,
        fa: FungibleAsset,
    ) acquires GaugeRegistry {
        let registry = borrow_global_mut<GaugeRegistry>(dao_address);
        let total_emissions = fungible_asset::amount(&fa);
        if (total_emissions == 0) {
            fungible_asset::destroy_zero(fa);
            return
        };

        let total_votes = if (smart_table::contains(&registry.epoch_total_votes, target_epoch)) {
            *smart_table::borrow(&registry.epoch_total_votes, target_epoch)
        } else { 0 };

        // If no one voted, everything goes to the default destination immediately
        if (total_votes == 0) {
            primary_fungible_store::deposit(registry.default_destination, fa);
            event::emit(EmissionsDistributed { dao_address, pilgrim: target_epoch, total_amount: total_emissions });
            return
        };

        // Push to Pull Refactor: Store the FA in the vault and record the total emissions for this epoch
        smart_table::upsert(&mut registry.epoch_total_emissions, target_epoch, total_emissions);
        primary_fungible_store::deposit(registry.vault_address, fa);

        event::emit(EmissionsDistributed { dao_address, pilgrim: target_epoch, total_amount: total_emissions });
    }

    // Pull Architecture: Anyone can call this to push a gauge's share of emissions to its destination
    public entry fun claim_gauge_emission(
        _caller: &signer,
        dao_address: address,
        target_epoch: u64,
        gauge_id: u64,
        token_metadata_addr: address,
    ) acquires GaugeRegistry {
        assert!(target_epoch < pilgrim::now(), error::invalid_argument(E_INVALID_EPOCH));
        assert!(supra_framework::object::is_object(token_metadata_addr), error::invalid_argument(E_NOT_OBJECT));
        let token_metadata = supra_framework::object::address_to_object<Metadata>(token_metadata_addr);

        let registry = borrow_global_mut<GaugeRegistry>(dao_address);
        assert!(smart_table::contains(&registry.gauges, gauge_id), error::invalid_argument(E_INVALID_GAUGE));
        assert!(smart_table::contains(&registry.epoch_total_emissions, target_epoch), error::invalid_state(E_NO_EMISSIONS));

        // Check if already claimed
        if (!smart_table::contains(&registry.claimed_emissions, target_epoch)) {
            smart_table::add(&mut registry.claimed_emissions, target_epoch, smart_table::new());
        };
        let epoch_claims = smart_table::borrow_mut(&mut registry.claimed_emissions, target_epoch);
        assert!(!smart_table::contains(epoch_claims, gauge_id), error::invalid_state(E_ALREADY_CLAIMED));

        let total_emissions = *smart_table::borrow(&registry.epoch_total_emissions, target_epoch);
        let total_votes = *smart_table::borrow(&registry.epoch_total_votes, target_epoch);
        
        let gauge_votes_table = smart_table::borrow(&registry.epoch_gauge_votes, target_epoch);
        let votes = if (smart_table::contains(gauge_votes_table, gauge_id)) {
            *smart_table::borrow(gauge_votes_table, gauge_id)
        } else { 0 };

        if (votes > 0 && total_votes > 0) {
            let share = (((total_emissions as u128) * votes / total_votes) as u64);
            if (share > 0) {
                let vault_signer = object::generate_signer_for_extending(&registry.vault_extend_ref);
                let share_fa = primary_fungible_store::withdraw(&vault_signer, token_metadata, share);
                let dest = smart_table::borrow(&registry.gauges, gauge_id).destination;
                
                // Hard-coupling to the DAO's Gauge Factory
                foundry::notify_reward_amount(dest, share_fa);
                
                event::emit(GaugeEmissionClaimed { 
                    dao_address, 
                    pilgrim: target_epoch, 
                    gauge_id, 
                    amount: share 
                });
            }
        };

        // Mark as claimed
        smart_table::add(epoch_claims, gauge_id, true);
    }

    // Views (Used by restore and Frontend) 

    #[view]
    public fun get_gauge_count(dao_address: address): u64 acquires GaugeRegistry {
        if (!exists<GaugeRegistry>(dao_address)) return 0;
        borrow_global<GaugeRegistry>(dao_address).next_gauge_id
    }

    #[view]
    public fun get_gauge_destination(dao_address: address, gauge_id: u64): address acquires GaugeRegistry {
        if (!exists<GaugeRegistry>(dao_address)) return @0x0;
        let registry = borrow_global<GaugeRegistry>(dao_address);
        if (!smart_table::contains(&registry.gauges, gauge_id)) return @0x0;
        smart_table::borrow(&registry.gauges, gauge_id).destination
    }

    #[view]
    public fun get_gauge_total_votes(
        dao_address: address,
        pilgrim: u64,
        gauge_id: u64,
    ): u128 acquires GaugeRegistry {
        if (!exists<GaugeRegistry>(dao_address)) return 0;
        let registry = borrow_global<GaugeRegistry>(dao_address);
        if (!smart_table::contains(&registry.epoch_gauge_votes, pilgrim)) return 0;
        
        let votes_table = smart_table::borrow(&registry.epoch_gauge_votes, pilgrim);
        if (smart_table::contains(votes_table, gauge_id)) {
            *smart_table::borrow(votes_table, gauge_id)
        } else { 0 }
    }

    #[view]
    public fun get_user_vote_power(
        dao_address: address,
        pilgrim: u64,
        ve_token_addr: address,
        gauge_id: u64,
    ): u128 acquires GaugeRegistry {
        if (!exists<GaugeRegistry>(dao_address)) return 0;
        let registry = borrow_global<GaugeRegistry>(dao_address);
        if (!smart_table::contains(&registry.epoch_user_votes, pilgrim)) return 0;
        
        let epoch_votes = smart_table::borrow(&registry.epoch_user_votes, pilgrim);
        if (!smart_table::contains(epoch_votes, ve_token_addr)) return 0;
        
        let user_vote = smart_table::borrow(epoch_votes, ve_token_addr);
        let i = 0;
        let len = vector::length(&user_vote.gauge_ids);
        while (i < len) {
            if (*vector::borrow(&user_vote.gauge_ids, i) == gauge_id) {
                return *vector::borrow(&user_vote.powers, i)
            };
            i = i + 1;
        };
        0
    }

    #[view]
    public fun get_epoch_total_votes(dao_address: address, pilgrim: u64): u128 acquires GaugeRegistry {
        if (!exists<GaugeRegistry>(dao_address)) return 0;
        let registry = borrow_global<GaugeRegistry>(dao_address);
        if (!smart_table::contains(&registry.epoch_total_votes, pilgrim)) return 0;
        *smart_table::borrow(&registry.epoch_total_votes, pilgrim)
    }

    #[view]
    public fun is_gauge_emission_claimed(
        dao_address: address,
        pilgrim: u64,
        gauge_id: u64
    ): bool acquires GaugeRegistry {
        if (!exists<GaugeRegistry>(dao_address)) return false;
        let registry = borrow_global<GaugeRegistry>(dao_address);
        if (!smart_table::contains(&registry.claimed_emissions, pilgrim)) return false;
        let epoch_claims = smart_table::borrow(&registry.claimed_emissions, pilgrim);
        if (!smart_table::contains(epoch_claims, gauge_id)) return false;
        *smart_table::borrow(epoch_claims, gauge_id)
    }
}
