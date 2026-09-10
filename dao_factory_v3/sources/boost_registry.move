// NFT Boost Registry - DAO-governed NFT collection boosts for Gauges.
//
// Implements the V2 NFT Boost architecture using the 0x4 Digital Assets standard:
// the DAO decides (via governance proposals type 8) which NFT collections grant
// a passive reward multiplier to their holders when staking in any Gauge.
//
// Security model:
// - The reward_rate of a Gauge is FIXED. Boosts only REDISTRIBUTE the same
//   emissions among stakers; they can never mint or drain extra tokens.
// - HARD_MAX_BOOST_CAP_BPS is an unbreakable constant. No matter how many
//   approved NFTs a user holds, their total boost can never exceed the cap.
// - Each approved collection counts ONCE per user (anti-accumulation rule).
// - NFTs are ESCROWED inside the gauge (foundry::apply_boost), so a boost can
//   never go "zombie": the user cannot sell what the gauge holds. Users can
//   always withdraw via foundry::unboost (uncensorable, registry-independent).
module dao_factory::boost_registry {
    friend dao_factory::petra;
    friend dao_factory::anchor;

    use std::error;
    use std::signer;
    use std::vector;
    use supra_framework::object;
    use supra_framework::event;
    use aptos_std::smart_table::{Self, SmartTable};
    use aptos_token_objects::collection;
    use aptos_token_objects::token;
    use dao_factory::table;

    // Errors
    const E_COLLECTION_NOT_FOUND: u64 = 1;
    const E_BOOST_TOO_HIGH: u64 = 2;
    const E_TOO_MANY_COLLECTIONS: u64 = 3;
    const E_TOO_MANY_NFTS: u64 = 4;
    const E_ZERO_BOOST: u64 = 5;
    const E_NOT_A_COLLECTION: u64 = 6;
    const E_NOT_INITIALIZED: u64 = 7;

    // UNBREAKABLE hard cap: no user can ever receive more than +13.7% rewards,
    // regardless of how many approved NFTs they hold. Protects the fixed
    // emissions redistribution against whale accumulation attacks.
    const HARD_MAX_BOOST_CAP_BPS: u64 = 1370;

    // Max approved collections per DAO (bounds storage and governance abuse).
    const MAX_COLLECTIONS: u64 = 32;

    // Max NFT addresses a user can submit per boost computation (bounds gas).
    const MAX_NFTS_PER_CALL: u64 = 10;

    // The registry lives at the DAO's resource account address.
    struct BoostRegistry has key {
        // collection_addr -> boost_bps (e.g. 500 = +5%)
        collections: SmartTable<address, u64>,
        collection_count: u64,
    }

    #[event]
    struct BoostCollectionSet has drop, store {
        dao_address: address,
        collection_addr: address,
        boost_bps: u64,
    }

    #[event]
    struct BoostCollectionRemoved has drop, store {
        dao_address: address,
        collection_addr: address,
    }

    // Initialization (called once by petra when an inflationary DAO is born).
    public(friend) fun initialize(dao_signer: &signer) {
        let dao_address = signer::address_of(dao_signer);
        if (!exists<BoostRegistry>(dao_address)) {
            move_to(dao_signer, BoostRegistry {
                collections: smart_table::new(),
                collection_count: 0,
            });
        };
    }

    // Governance Functions (only callable by anchor after a passed proposal)

    // Adds a new approved collection or updates the boost of an existing one.
    public(friend) fun set_collection(
        dao_signer: &signer,
        collection_addr: address,
        boost_bps: u64,
    ) acquires BoostRegistry {
        // Must be a real 0x4 Collection object on-chain.
        assert!(
            object::object_exists<collection::Collection>(collection_addr),
            error::invalid_argument(E_NOT_A_COLLECTION)
        );
        assert!(boost_bps > 0, error::invalid_argument(E_ZERO_BOOST));
        assert!(boost_bps <= HARD_MAX_BOOST_CAP_BPS, error::invalid_argument(E_BOOST_TOO_HIGH));

        // The registry must already exist (inflationary DAOs are born with it).
        // No lazy initialization: boosts must never silently extend to a DAO
        // that was not created with the ve(3,3) engine.
        let dao_address = signer::address_of(dao_signer);
        assert!(exists<BoostRegistry>(dao_address), error::not_found(E_NOT_INITIALIZED));
        let registry = borrow_global_mut<BoostRegistry>(dao_address);

        if (!smart_table::contains(&registry.collections, collection_addr)) {
            assert!(
                registry.collection_count < MAX_COLLECTIONS,
                error::invalid_state(E_TOO_MANY_COLLECTIONS)
            );
            registry.collection_count = registry.collection_count + 1;
        };
        smart_table::upsert(&mut registry.collections, collection_addr, boost_bps);

        event::emit(BoostCollectionSet { dao_address, collection_addr, boost_bps });
    }

    // Removes a collection from the registry. Existing stored boosts become
    // stale and are stripped on the next sync/claim of each affected user.
    public(friend) fun remove_collection(
        dao_signer: &signer,
        collection_addr: address,
    ) acquires BoostRegistry {
        let dao_address = signer::address_of(dao_signer);
        assert!(exists<BoostRegistry>(dao_address), error::not_found(E_NOT_INITIALIZED));
        let registry = borrow_global_mut<BoostRegistry>(dao_address);
        assert!(
            smart_table::contains(&registry.collections, collection_addr),
            error::not_found(E_COLLECTION_NOT_FOUND)
        );

        smart_table::remove(&mut registry.collections, collection_addr);
        registry.collection_count = registry.collection_count - 1;

        event::emit(BoostCollectionRemoved { dao_address, collection_addr });
    }

    // Boost Computation (used by foundry)

    // Computes the capped total boost for a user, given the NFT objects they
    // claim to own. Each approved collection counts ONCE.
    //
    // For every NFT address we verify:
    // 1. It is a real 0x4 Token object.
    // 2. The user DIRECTLY owns it right now (object::is_owner).
    // 3. Its collection is approved by the DAO and not counted yet.
    //
    // Returns (total_boost_bps_capped, valid_nft_addrs). The valid addresses
    // are returned so the caller can store them as evidence for later
    // permissionless re-verification (anti stale-boost).
    #[view]
    public fun compute_boost(
        dao_address: address,
        user: address,
        nft_addrs: vector<address>,
    ): (u64, vector<address>) acquires BoostRegistry {
        assert!(
            vector::length(&nft_addrs) <= MAX_NFTS_PER_CALL,
            error::invalid_argument(E_TOO_MANY_NFTS)
        );
        if (!exists<BoostRegistry>(dao_address)) return (0, vector::empty());

        let registry = borrow_global<BoostRegistry>(dao_address);
        let total_bps: u64 = 0;
        let counted_collections = vector::empty<address>();
        let valid_nfts = vector::empty<address>();

        let i = 0;
        let len = vector::length(&nft_addrs);
        // The loop stops early once the unbreakable hard cap is reached.
        while (i < len && total_bps < HARD_MAX_BOOST_CAP_BPS) {
            let nft_addr = *vector::borrow(&nft_addrs, i);
            i = i + 1;

            // 1. Must be a real 0x4 Token object.
            if (object::object_exists<token::Token>(nft_addr)) {
                let token_obj = object::address_to_object<token::Token>(nft_addr);

                // 2. The user must directly own the NFT right now.
                if (object::is_owner(token_obj, user)) {
                    let collection_obj = token::collection_object(token_obj);
                    let collection_addr = object::object_address(&collection_obj);

                    // 3. Collection must be approved and counted at most once.
                    if (smart_table::contains(&registry.collections, collection_addr)
                        && !vector::contains(&counted_collections, &collection_addr)) {
                        vector::push_back(&mut counted_collections, collection_addr);
                        vector::push_back(&mut valid_nfts, nft_addr);
                        total_bps = total_bps + *smart_table::borrow(&registry.collections, collection_addr);
                    };
                };
            };
        };

        // Unbreakable hard cap.
        if (total_bps > HARD_MAX_BOOST_CAP_BPS) {
            total_bps = HARD_MAX_BOOST_CAP_BPS;
        };

        (total_bps, valid_nfts)
    }

    // Computes the capped total boost for a set of NFTs that are already in escrow.
    // Unlike compute_boost, this does NOT check is_owner (since the gauge custodies them)
    // and it processes all NFTs to determine which ones to keep and which to return.
    // Returns (total_bps, kept_nfts, rejected_nfts)
    public fun compute_escrowed_boost(
        dao_address: address,
        nft_addrs: vector<address>,
    ): (u64, vector<address>, vector<address>) acquires BoostRegistry {
        let kept_nfts = vector::empty<address>();
        let rejected_nfts = vector::empty<address>();
        if (!exists<BoostRegistry>(dao_address)) {
            // If no registry, all are rejected
            return (0, vector::empty(), nft_addrs)
        };

        let registry = borrow_global<BoostRegistry>(dao_address);
        let total_bps: u64 = 0;
        let counted_collections = vector::empty<address>();

        let i = 0;
        let len = vector::length(&nft_addrs);
        while (i < len) {
            let nft_addr = *vector::borrow(&nft_addrs, i);
            i = i + 1;

            if (object::object_exists<token::Token>(nft_addr)) {
                let token_obj = object::address_to_object<token::Token>(nft_addr);
                let collection_obj = token::collection_object(token_obj);
                let collection_addr = object::object_address(&collection_obj);

                let coll_bps = table::u64_or_zero(&registry.collections, collection_addr);

                if (coll_bps == 0 || vector::contains(&counted_collections, &collection_addr)) {
                    vector::push_back(&mut rejected_nfts, nft_addr);
                } else {
                    vector::push_back(&mut counted_collections, collection_addr);
                    vector::push_back(&mut kept_nfts, nft_addr);
                    total_bps = total_bps + coll_bps;
                };
            };
            // else: NFT burned while escrowed -> silently dropped from evidence.
        };

        if (total_bps > HARD_MAX_BOOST_CAP_BPS) {
            total_bps = HARD_MAX_BOOST_CAP_BPS;
        };

        (total_bps, kept_nfts, rejected_nfts)
    }

    // View Functions

    #[view]
    public fun hard_cap_bps(): u64 { HARD_MAX_BOOST_CAP_BPS }

    #[view]
    public fun is_initialized(dao_address: address): bool {
        exists<BoostRegistry>(dao_address)
    }

    #[view]
    public fun get_collection_boost(dao_address: address, collection_addr: address): u64 acquires BoostRegistry {
        if (!exists<BoostRegistry>(dao_address)) return 0;
        table::u64_or_zero(&borrow_global<BoostRegistry>(dao_address).collections, collection_addr)
    }
    
    #[view]
    public fun is_boosted_collection(dao_address: address, collection_addr: address): bool acquires BoostRegistry {
        if (!exists<BoostRegistry>(dao_address)) return false;
        smart_table::contains(&borrow_global<BoostRegistry>(dao_address).collections, collection_addr)
    }
    
    #[view]
    public fun get_registry_size(dao_address: address): u64 acquires BoostRegistry {
        if (!exists<BoostRegistry>(dao_address)) return 0;
        borrow_global<BoostRegistry>(dao_address).collection_count
    }
}
