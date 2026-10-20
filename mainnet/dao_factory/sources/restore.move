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
    use std::vector;
    use supra_framework::fungible_asset::Metadata;
    use supra_framework::primary_fungible_store;
    use supra_framework::dispatchable_fungible_asset;

    use supra_framework::object::{Self, Object, ExtendRef};
    use supra_framework::event;
    use aptos_std::smart_table::{Self, SmartTable};
    use std::error;
    

    use dao_libs::math;
    use dao_libs::pilgrim;
    use dao_factory::ledger;
    use dao_factory::zeal;
    use dao_factory::legacy;
    use dao_libs::table;
    use dao_tax_router::tax_router;
    
    // Errors 
    const E_NOT_WHITELISTED: u64 = 1;
    const E_NO_VOTES: u64        = 2;
    const E_ALREADY_CLAIMED: u64 = 3;
    const E_NOT_OWNER: u64       = 4;
    const E_INVALID_EPOCH: u64   = 5;
    const E_INVALID_GAUGE: u64   = 6;
    const E_NOT_OBJECT: u64      = 7;
    const E_NOT_AUTHORIZED: u64  = 8;
    const E_ZERO_AMOUNT: u64     = 9;

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
        whitelisted_tokens: vector<address>,
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

    #[event]
    struct WhitelistUpdated has drop, store {
        dao_address: address,
        token: address,
        is_allowed: bool,
    }

    #[event]
    struct BribeRolledOver has drop, store {
        dao_address: address,
        from_pilgrim: u64,
        to_pilgrim: u64,
        gauge_id: u64,
        token: address,
        amount: u64,
    }

    // Initialization 

    public(friend) fun initialize(dao_signer: &signer, governance_token_addr: address, extra_whitelisted_tokens: vector<address>) {
        let constructor_ref = object::create_object(signer::address_of(dao_signer));
        // H-02 Defense: Disable ungated transfers on Bribe vault object to prevent theft via Type 5 proposals
        let transfer_ref = object::generate_transfer_ref(&constructor_ref);
        object::disable_ungated_transfer(&transfer_ref);
        
        let whitelisted = vector::empty<address>();
        if (!vector::contains(&whitelisted, &governance_token_addr)) {
            vector::push_back(&mut whitelisted, governance_token_addr);
        };
        
        let i = 0;
        let len = vector::length(&extra_whitelisted_tokens);
        while (i < len) {
            let token = *vector::borrow(&extra_whitelisted_tokens, i);
            if (!vector::contains(&whitelisted, &token)) {
                vector::push_back(&mut whitelisted, token);
            };
            i = i + 1;
        };

        move_to(dao_signer, BribeRegistry {
            vault_extend_ref: object::generate_extend_ref(&constructor_ref),
            vault_address: object::address_from_constructor_ref(&constructor_ref),
            total_bribes: smart_table::new(),
            claims: smart_table::new(),
            whitelisted_tokens: whitelisted,
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
        
        let contains = vector::contains(&registry.whitelisted_tokens, &token_addr);
        if (is_allowed && !contains) {
            vector::push_back(&mut registry.whitelisted_tokens, token_addr);
        } else if (!is_allowed && contains) {
            let (found, index) = vector::index_of(&registry.whitelisted_tokens, &token_addr);
            if (found) {
                vector::remove(&mut registry.whitelisted_tokens, index);
            };
        };

        event::emit(WhitelistUpdated {
            dao_address: signer::address_of(dao_signer),
            token: token_addr,
            is_allowed,
        });
    }

    // Deposits 

    // FIX (audit10 C4): the DAO's cap can only route its own governance
    // token (withdraw_with_ref requires matching metadata) and only exists
    // for launcher smart tokens (see tax_router::has_tax_free_router).
    fun use_cap_route(dao_address: address, token_addr: address): bool {
        tax_router::has_tax_free_router(dao_address)
            && token_addr == legacy::get_token_metadata_address(dao_address)
    }

    fun transfer_bribe_payout(
        dao_address: address,
        registry: &BribeRegistry,
        token_metadata: Object<Metadata>,
        token_addr: address,
        claimer_addr: address,
        share: u64
    ): u64 {
        let vault_store = primary_fungible_store::primary_store(registry.vault_address, token_metadata);
        let user_store = primary_fungible_store::ensure_primary_store_exists(claimer_addr, token_metadata);
        let use_cap = use_cap_route(dao_address, token_addr);
        let vault_signer = object::generate_signer_for_extending(&registry.vault_extend_ref);
        let fa = if (use_cap) {
            tax_router::withdraw_tax_free(dao_address, &ledger::generate_signer(dao_address), vault_store, share)
        } else {
            dispatchable_fungible_asset::withdraw(&vault_signer, vault_store, share)
        };
        if (use_cap) {
            tax_router::deposit_tax_free(dao_address, &ledger::generate_signer(dao_address), user_store, fa);
            share
        } else {
            let bal_before = primary_fungible_store::balance(claimer_addr, token_metadata);
            dispatchable_fungible_asset::deposit(user_store, fa);
            primary_fungible_store::balance(claimer_addr, token_metadata) - bal_before
        }
    }

    public entry fun deposit_bribe(
        depositor: &signer,
        dao_address: address,
        pilgrim: u64,
        gauge_id: u64,
        token_metadata_addr: address,
        amount: u64,
    ) acquires BribeRegistry {
        math::validate_bribe_deposit(
            amount, pilgrim, pilgrim::now(), gauge_id, zeal::get_gauge_count(dao_address),
            zeal::is_gauge_active(dao_address, gauge_id), object::is_object(token_metadata_addr),
            E_ZERO_AMOUNT, E_INVALID_EPOCH, E_INVALID_GAUGE, E_NOT_OBJECT
        );

        let token_metadata = object::address_to_object<Metadata>(token_metadata_addr);
        let depositor_addr = signer::address_of(depositor);
        let token_addr = object::object_address(&token_metadata);
        let registry = borrow_global_mut<BribeRegistry>(dao_address);

        assert!(
            vector::contains(&registry.whitelisted_tokens, &token_addr),
            error::invalid_argument(E_NOT_WHITELISTED)
        );

        let user_store = primary_fungible_store::primary_store(depositor_addr, token_metadata);
        // FIX (audit10 C4 + H-04): route through the DAO's cap ONLY when the DAO has
        // a TaxFreeRouter AND the bribe token IS the DAO's governance token.
        // Requires the depositor's explicit signer proof so no DAO script can drain user wallets.
        let use_cap = use_cap_route(dao_address, token_addr);
        let vault_dest = primary_fungible_store::ensure_primary_store_exists(registry.vault_address, token_metadata);
        let bal_before = primary_fungible_store::balance(registry.vault_address, token_metadata);
        if (use_cap) {
            tax_router::transfer_tax_free_from_owner(dao_address, depositor, user_store, vault_dest, amount);
        } else {
            let fa = dispatchable_fungible_asset::withdraw(depositor, user_store, amount);
            dispatchable_fungible_asset::deposit(vault_dest, fa);
        };
        let actual_amount = primary_fungible_store::balance(registry.vault_address, token_metadata) - bal_before;

        let key = BribeKey { pilgrim, gauge_id, token_addr };
        let current_total = table::u64_or_zero(&registry.total_bribes, key);
        smart_table::upsert(&mut registry.total_bribes, key, current_total + actual_amount);

        event::emit(BribeDeposited {
            dao_address, depositor: depositor_addr, pilgrim, gauge_id, token: token_addr, amount: actual_amount
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
        assert!(object::is_object(legacy_addr), error::invalid_argument(E_NOT_OBJECT));
        assert!(object::is_object(token_metadata_addr), error::invalid_argument(E_NOT_OBJECT));
        let ve_token_obj = object::address_to_object<legacy::VeToken>(legacy_addr);
        let token_metadata = object::address_to_object<Metadata>(token_metadata_addr);

        // Can only claim from PAST epochs (the epoch's voting has already closed)
        // This ensures that the total_power is immutable and final.
        assert!(pilgrim < pilgrim::now(), error::invalid_state(E_NO_VOTES));

        let claimer_addr = signer::address_of(claimer);
        // FIX (audit10 M3): blacklisted accounts must not extract bribes.
        legacy::assert_not_blacklisted(dao_address, claimer_addr);
        assert!(object::is_owner(ve_token_obj, claimer_addr), error::permission_denied(E_NOT_OWNER));

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
        let share = math::compute_bribe_claim_share(total_bribe, user_power, total_power);
        
        if (share > 0) {

            let actual_claimed = transfer_bribe_payout(dao_address, registry, token_metadata, token_addr, claimer_addr, share);

            event::emit(BribeClaimed {
                dao_address, claimer: claimer_addr, legacy: ve_token_addr, pilgrim, gauge_id, token: token_addr, amount: actual_claimed
            });
        };
    }

    // Views (Frontend) 
    #[view]
    public fun is_whitelisted(dao_address: address, token_addr: address): bool acquires BribeRegistry {
        if (!exists<BribeRegistry>(dao_address)) return false;
        let registry = borrow_global<BribeRegistry>(dao_address);
        vector::contains(&registry.whitelisted_tokens, &token_addr)
    }

    #[view]
    public fun get_whitelisted_tokens(dao_address: address): vector<address> acquires BribeRegistry {
        if (!exists<BribeRegistry>(dao_address)) return vector::empty<address>();
        let registry = borrow_global<BribeRegistry>(dao_address);
        registry.whitelisted_tokens
    }

    #[view]
    public fun get_vault_address(dao_address: address): address acquires BribeRegistry {
        let registry = borrow_global<BribeRegistry>(dao_address);
        registry.vault_address
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
        table::u64_or_zero(&registry.total_bribes, key)
    }

    #[view]
    public fun has_claimed_bribe(
        dao_address: address,
        pilgrim: u64,
        gauge_id: u64,
        token_addr: address,
        ve_token_addr: address,
    ): bool acquires BribeRegistry {
        if (!exists<BribeRegistry>(dao_address)) return false;
        let registry = borrow_global<BribeRegistry>(dao_address);
        let key = ClaimKey { pilgrim, gauge_id, token_addr, ve_token_addr };
        if (!smart_table::contains(&registry.claims, key)) return false;
        true
    }

    // Rolls over unclaimed bribes to the next available voting epoch if a gauge received 0 votes.
    public entry fun rollover_bribe(
        dao_address: address,
        past_pilgrim: u64,
        gauge_id: u64,
        token_metadata_addr: address,
    ) acquires BribeRegistry {
        assert!(past_pilgrim < pilgrim::now(), error::invalid_state(E_INVALID_EPOCH));
        assert!(object::is_object(token_metadata_addr), error::invalid_argument(E_NOT_OBJECT));
        
        // Verify that the gauge received exactly 0 votes in that epoch
        let total_power = zeal::get_gauge_total_votes(dao_address, past_pilgrim, gauge_id);
        assert!(total_power == 0, error::invalid_state(E_NOT_AUTHORIZED)); // Only rollover if 0 votes

        let token_addr = token_metadata_addr;
        
        let past_key = BribeKey { pilgrim: past_pilgrim, gauge_id, token_addr };
        let registry = borrow_global_mut<BribeRegistry>(dao_address);

        let amount = table::u64_or_zero(&registry.total_bribes, past_key);
        if (amount == 0) return;

        // Zero out the past epoch
        smart_table::upsert(&mut registry.total_bribes, past_key, 0);

        // Move to the next available voting epoch (now + 1)
        let target_pilgrim = pilgrim::now() + 1;
        let target_key = BribeKey { pilgrim: target_pilgrim, gauge_id, token_addr };

        let current_target_total = table::u64_or_zero(&registry.total_bribes, target_key);

        smart_table::upsert(&mut registry.total_bribes, target_key, current_target_total + amount);

        event::emit(BribeRolledOver {
            dao_address,
            from_pilgrim: past_pilgrim,
            to_pilgrim: target_pilgrim,
            gauge_id,
            token: token_addr,
            amount
        });
    }
}
