// Bribes Module - Voting Incentives
//
// Allows any user to deposit whitelisted tokens as a bribe
// to incentivize veToken holders to vote for a specific Gauge
// in a specific epoch.
// Voters can claim their portion of the bribe proportional to their voting
// power once the epoch ends.
module dao_factory::restore {
    friend dao_factory::petra;
    friend dao_factory::anchor;
    use std::signer;
    use supra_framework::fungible_asset::{Self, Metadata};
    use supra_framework::primary_fungible_store;
    use supra_framework::object::{Self, Object, ExtendRef};
    use supra_framework::event;
    use aptos_std::smart_table::{Self, SmartTable};
    use std::error;
    
    use dao_factory::pilgrim;
    use dao_factory::zeal;
    use dao_factory::legacy;

    // Errors 
    const E_NOT_WHITELISTED: u64 = 1;
    const E_NO_VOTES: u64        = 2;
    const E_ALREADY_CLAIMED: u64 = 3;
    const E_NOT_OWNER: u64       = 4;
    const E_INVALID_EPOCH: u64   = 5;
    const E_INVALID_GAUGE: u64   = 6;
    const E_NOT_OBJECT: u64      = 7;

    // Structs 
    struct BribeKey has copy, drop, store {
        pilgrim: u64,
        gauge_id: u64,
        token_addr: address,
    }

    struct ClaimKey has copy, drop, store {
        pilgrim: u64,
        gauge_id: u64,
        token_addr: address,
        ve_token_addr: address,
    }

    struct BribeRegistry has key {
        // Central store for all bribes of this DAO
        vault_extend_ref: ExtendRef,
        vault_address: address,
        
        // Total deposited per key (epoch, gauge, token)
        total_bribes: SmartTable<BribeKey, u64>,
        
        // Claim registry to prevent double claiming
        claims: SmartTable<ClaimKey, bool>,
        
        // Tokens allowed to be used as bribe (anti-spam)
        whitelisted_tokens: SmartTable<address, bool>,
    }

    // Events 

    #[event]
    struct BribeDeposited has drop, store {
        dao_address: address,
        depositor: address,
        pilgrim: u64,
        gauge_id: u64,
        token: address,
        amount: u64,
    }

    #[event]
    struct BribeClaimed has drop, store {
        dao_address: address,
        claimer: address,
        legacy: address,
        pilgrim: u64,
        gauge_id: u64,
        token: address,
        amount: u64,
    }

    // Initialization 

    public(friend) fun initialize(dao_signer: &signer) {
        let constructor_ref = object::create_object(signer::address_of(dao_signer));
        
        move_to(dao_signer, BribeRegistry {
            vault_extend_ref: object::generate_extend_ref(&constructor_ref),
            vault_address: object::address_from_constructor_ref(&constructor_ref),
            total_bribes: smart_table::new(),
            claims: smart_table::new(),
            whitelisted_tokens: smart_table::new(),
        });
    }

    // Governance 

    // Adds or removes a token from the bribes whitelist.
    // Called by governance proposal (anchor).
    public(friend) fun set_whitelist(
        dao_signer: &signer,
        token_metadata: Object<Metadata>,
        is_allowed: bool,
    ) acquires BribeRegistry {
        let registry = borrow_global_mut<BribeRegistry>(signer::address_of(dao_signer));
        let token_addr = object::object_address(&token_metadata);
        smart_table::upsert(&mut registry.whitelisted_tokens, token_addr, is_allowed);
    }

    // Deposits 

    // Deposits tokens to incentivize votes towards a gauge in a future or current epoch.
    public entry fun deposit_bribe(
        depositor: &signer,
        dao_address: address,
        pilgrim: u64,
        gauge_id: u64,
        token_metadata_addr: address,
        amount: u64,
    ) acquires BribeRegistry {
        assert!(supra_framework::object::is_object(token_metadata_addr), error::invalid_argument(E_NOT_OBJECT));
        let token_metadata = supra_framework::object::address_to_object<Metadata>(token_metadata_addr);
        let depositor_addr = signer::address_of(depositor);
        let token_addr = object::object_address(&token_metadata);
        let registry = borrow_global_mut<BribeRegistry>(dao_address);
        
        // FIX (FUND-03): Prevent front-running by only allowing bribes for FUTURE epochs
        assert!(pilgrim > pilgrim::now(), error::invalid_argument(E_INVALID_EPOCH));
        assert!(gauge_id < zeal::get_gauge_count(dao_address), error::invalid_argument(E_INVALID_GAUGE));
        
        assert!(
            smart_table::contains(&registry.whitelisted_tokens, token_addr) && 
            *smart_table::borrow(&registry.whitelisted_tokens, token_addr),
            error::invalid_argument(E_NOT_WHITELISTED)
        );

        // Withdraw from the depositor and save in the central bribes vault
        let fa = primary_fungible_store::withdraw(depositor, token_metadata, amount);
        primary_fungible_store::deposit(registry.vault_address, fa);

        let key = BribeKey { pilgrim, gauge_id, token_addr };
        let current_total = if (smart_table::contains(&registry.total_bribes, key)) {
            *smart_table::borrow(&registry.total_bribes, key)
        } else { 0 };
        
        smart_table::upsert(&mut registry.total_bribes, key, current_total + amount);

        event::emit(BribeDeposited {
            dao_address, depositor: depositor_addr, pilgrim, gauge_id, token: token_addr, amount
        });
    }

    // Claims 
    // Voters claim their portion of the bribe once the voting epoch ends.
    public entry fun claim_bribe(
        claimer: &signer,
        legacy_addr: address,
        dao_address: address,
        pilgrim: u64,
        gauge_id: u64,
        token_metadata_addr: address,
    ) acquires BribeRegistry {
        assert!(supra_framework::object::is_object(legacy_addr), error::invalid_argument(E_NOT_OBJECT));
        assert!(supra_framework::object::is_object(token_metadata_addr), error::invalid_argument(E_NOT_OBJECT));
        let ve_token_obj = supra_framework::object::address_to_object<legacy::VeToken>(legacy_addr);
        let token_metadata = supra_framework::object::address_to_object<Metadata>(token_metadata_addr);

        // Can only claim from PAST epochs (the epoch's voting has already closed)
        // This ensures that the total_power is immutable and final.
        assert!(pilgrim < pilgrim::now(), error::invalid_state(E_NO_VOTES));

        let claimer_addr = signer::address_of(claimer);
        assert!(supra_framework::object::is_owner(ve_token_obj, claimer_addr), error::permission_denied(E_NOT_OWNER));

        let ve_token_addr = object::object_address(&ve_token_obj);
        
        // Verify that the user voted for this gauge in the specified epoch
        let user_power = zeal::get_user_vote_power(dao_address, pilgrim, ve_token_addr, gauge_id);
        assert!(user_power > 0, error::invalid_state(E_NO_VOTES));

        let total_power = zeal::get_gauge_total_votes(dao_address, pilgrim, gauge_id);
        assert!(total_power > 0, error::invalid_state(E_NO_VOTES));

        let token_addr = object::object_address(&token_metadata);
        let bribe_key = BribeKey { pilgrim, gauge_id, token_addr };
        let registry = borrow_global_mut<BribeRegistry>(dao_address);
        
        // FIX (FUND-02): Check if bribes exist BEFORE burning the user's claim ticket
        if (!smart_table::contains(&registry.total_bribes, bribe_key)) return;
        let total_bribe = *smart_table::borrow(&registry.total_bribes, bribe_key);
        if (total_bribe == 0) return;

        let claim_key = ClaimKey { pilgrim, gauge_id, token_addr, ve_token_addr };
        assert!(!smart_table::contains(&registry.claims, claim_key), error::invalid_state(E_ALREADY_CLAIMED));
        smart_table::add(&mut registry.claims, claim_key, true);
        // Their portion is proportional to their vote contribution to the gauge
        let share = (((total_bribe as u128) * user_power / total_power) as u64);
        
        if (share > 0) {
            let vault_signer = object::generate_signer_for_extending(&registry.vault_extend_ref);
            let vault_store = primary_fungible_store::primary_store(registry.vault_address, token_metadata);
            let fa = fungible_asset::withdraw(&vault_signer, vault_store, share);
            primary_fungible_store::deposit(claimer_addr, fa);

            event::emit(BribeClaimed {
                dao_address, claimer: claimer_addr, legacy: ve_token_addr, pilgrim, gauge_id, token: token_addr, amount: share
            });
        };
    }

    // Views (Frontend) 
    #[view]
    public fun is_whitelisted(dao_address: address, token_addr: address): bool acquires BribeRegistry {
        if (!exists<BribeRegistry>(dao_address)) return false;
        let registry = borrow_global<BribeRegistry>(dao_address);
        if (!smart_table::contains(&registry.whitelisted_tokens, token_addr)) return false;
        *smart_table::borrow(&registry.whitelisted_tokens, token_addr)
    }

    #[view]
    public fun get_total_bribes_for(
        dao_address: address,
        pilgrim: u64,
        gauge_id: u64,
        token_addr: address,
    ): u64 acquires BribeRegistry {
        if (!exists<BribeRegistry>(dao_address)) return 0;
        let registry = borrow_global<BribeRegistry>(dao_address);
        let key = BribeKey { pilgrim, gauge_id, token_addr };
        if (!smart_table::contains(&registry.total_bribes, key)) return 0;
        *smart_table::borrow(&registry.total_bribes, key)
    }
}
