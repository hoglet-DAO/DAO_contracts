// veToken Module - The heart of the ve(3,3) governance system.
//
// Features:
// - Lock FungibleAssets to obtain decaying voting power
// - Automatic Rebase (Synthetix-style acc_per_share)
// - Snapshots per epoch for anti-flash-loan
// - Vote Delegation (Velodrome v2 standard)
// - Integration with harvest checkpoint for rewards
module dao_factory::legacy {
    friend dao_factory::witness;
    friend dao_factory::petra;
    friend dao_factory::jubilee;
    friend dao_factory::anchor;
    friend dao_factory::zeal;
    use std::signer;
    use std::string::{Self, String};
    use std::option::{Self, Option};
    use std::vector;
    use std::error;
    use supra_framework::fungible_asset::{
        Self, FungibleAsset, Metadata, FungibleStore
    };
    use supra_framework::object::{Self, Object, ExtendRef, DeleteRef};
    use supra_framework::primary_fungible_store;
    use supra_framework::event;
    use aptos_std::smart_vector::{Self, SmartVector};
    use aptos_std::string_utils;
    
    use aptos_token_objects::collection;
    use aptos_token_objects::token;

    use dao_factory::pilgrim;
    use dao_factory::sentinel;
    use dao_factory::harvest;
    use dao_factory::ledger;
    use dao_factory::math;

    // Errors 
    const E_ZERO_AMOUNT: u64        = 1;
    const E_LOCK_TOO_SHORT: u64     = 2;
    const E_LOCK_TOO_LONG: u64      = 3;
    const E_NOT_OWNER: u64          = 4;
    const E_STILL_LOCKED: u64       = 5;
    const E_INVALID_EXTEND: u64     = 6;
    const E_LOCK_EXPIRED: u64       = 7;
    const E_SELF_DELEGATE: u64      = 8;
    const E_ALREADY_DELEGATED: u64  = 9;
    const E_INVALID_OBJECT: u64     = 10;
    const E_VOTED_RECENTLY: u64     = 11;

    const MIN_LOCK_EPOCHS: u64 = 3;    
    const MAX_LOCK_EPOCHS: u64 = 207;  
    const PRECISION: u256      = 1_000_000_000_000_000_000;

    struct VeTokenRegistry has key {
        total_locked: u64,
        acc_rebase_per_share: u128,
        rebase_store: Object<FungibleStore>,
        token_metadata: Object<Metadata>,
        
        // Permission to create NFTs
        creator_extend_ref: ExtendRef,
        // Counter to name NFTs (e.g. "veAERO Position #1")
        mint_count: u64,
        // Name of the dynamic collection (e.g. "Governance of Aerodrome")
        collection_name: String,
        // Token symbol for the name (e.g. "AERO")
        token_symbol: String,
        
        // Base URI for API integration (empty string means 100% SVG On-Chain)
        base_uri: String,
    }

    struct Snapshot has store, copy, drop {
        pilgrim: u64,
        locked_amount: u64,
        end_epoch: u64,
    }

    struct RegistrySnapshot has store, copy, drop {
        pilgrim: u64, // Epoch number
        total_locked: u64,
    }

    struct TotalLockedHistory has key {
        snapshots: SmartVector<RegistrySnapshot>,
    }

    struct VeToken has key {
        dao_address: address,
        locked_amount: u64,
        end_epoch: u64,
        snapshots: SmartVector<Snapshot>,
        rebase_debt: u128,
        token_metadata: Object<Metadata>,
        // Vote Delegate - if Some, the delegate can vote with this veToken.
        // The owner can revoke at any time.
        delegate: Option<address>,
        delegator: address,
        last_voted_epoch: u64,
    }

    struct VeTokenRefs has key {
        extend_ref: ExtendRef,
        delete_ref: DeleteRef,
        mutator_ref: token::MutatorRef,
    }

    // Events 
    #[event]
    struct LockCreated has drop, store {
        owner: address,
        legacy: address,
        dao_address: address,
        amount: u64,
        end_epoch: u64,
        voting_power: u64,
    }

    #[event]
    struct LockExtended has drop, store {
        owner: address,
        legacy: address,
        old_end_epoch: u64,
        new_end_epoch: u64,
    }

    #[event]
    struct AmountIncreased has drop, store {
        owner: address,
        legacy: address,
        added_amount: u64,
        new_total: u64,
    }

    #[event]
    struct Withdrawn has drop, store {
        owner: address,
        legacy: address,
        amount: u64,
    }

    #[event]
    struct RebaseCompounded has drop, store {
        legacy: address,
        amount: u64,
    }

    #[event]
    struct LockMerged has drop, store {
        owner: address,
        from_legacy: address,
        into_legacy: address,
        amount_merged: u64,
        new_total: u64,
        new_end_epoch: u64,
    }

    #[event]
    struct DelegateChanged has drop, store {
        legacy: address,
        owner: address,
        old_delegate: Option<address>,
        new_delegate: Option<address>,
    }

    // Aesthetic Initialization 

    public(friend) fun initialize_registry(
        dao_signer: &signer,
        token_metadata: Object<Metadata>,
        dao_name: String,
    ) {
        let constructor_ref = object::create_object(signer::address_of(dao_signer));
        let rebase_store = fungible_asset::create_store(&constructor_ref, token_metadata);
        
        // We create a sub-object dedicated to signing and owning the DAO's collection
        let creator_constructor = object::create_object(signer::address_of(dao_signer));
        let creator_signer = object::generate_signer(&creator_constructor);
        let creator_extend_ref = object::generate_extend_ref(&creator_constructor);

        // Premium Names (Example: "Governance of Aerodrome")
        let collection_name = string::utf8(b"Gov. of ");
        string::append(&mut collection_name, dao_name);

        let collection_desc = string::utf8(b"Gov rights for ");
        string::append(&mut collection_desc, dao_name);

        let token_symbol = fungible_asset::symbol(token_metadata);
        let token_icon = fungible_asset::icon_uri(token_metadata);

        collection::create_unlimited_collection(
            &creator_signer,
            collection_desc,
            collection_name,
            option::none(),
            token_icon, // Hereda la imagen del Token Base!
        );

        move_to(dao_signer, VeTokenRegistry {
            total_locked: 0,
            acc_rebase_per_share: 0,
            rebase_store,
            token_metadata,
            creator_extend_ref,
            mint_count: 0,
            collection_name,
            token_symbol,
            base_uri: string::utf8(b""), // Immortal SVG by default
        });

        move_to(dao_signer, TotalLockedHistory {
            snapshots: smart_vector::new<RegistrySnapshot>(),
        });
    }

    // Rebase 

    public(friend) fun inject_rebase(
        dao_address: address,
        rebase_fa: FungibleAsset
    ) acquires VeTokenRegistry {
        let registry = borrow_global_mut<VeTokenRegistry>(dao_address);
        let amount = fungible_asset::amount(&rebase_fa);

        if (registry.total_locked > 0 && amount > 0) {
            registry.acc_rebase_per_share = registry.acc_rebase_per_share
                + (((amount as u256) * PRECISION / (registry.total_locked as u256)) as u128);
            fungible_asset::deposit(registry.rebase_store, rebase_fa);
        } else {
            // SECURITY FIX (VULN-06): When no one is locking, rebase tokens
            // deposited into rebase_store would be stranded forever (the
            // accumulator can never distribute them). Redirect them to the
            // DAO treasury instead, where governance can recover them.
            primary_fungible_store::deposit(dao_address, rebase_fa);
        };
    }

    public(friend) fun inject_rewards(
        dao_address: address, 
        reward: FungibleAsset
    ) acquires VeTokenRegistry {
        let registry = borrow_global<VeTokenRegistry>(dao_address);
        harvest::inject_rewards(dao_address, reward, registry.total_locked);
    }

    // Snapshot Helpers 

    // Upserts the voting-power snapshot for the current epoch: updates the
    // last snapshot if it belongs to this epoch, otherwise appends a new one.
    // Shared by every balance/end_epoch-mutating flow (compound, extend,
    // increase, merge).
    fun upsert_snapshot(ve_data: &mut VeToken) {
        let current_epoch = pilgrim::now();
        let len = smart_vector::length(&ve_data.snapshots);
        if (len > 0 && smart_vector::borrow(&ve_data.snapshots, len - 1).pilgrim == current_epoch) {
            let snap = smart_vector::borrow_mut(&mut ve_data.snapshots, len - 1);
            snap.locked_amount = ve_data.locked_amount;
            snap.end_epoch = ve_data.end_epoch;
        } else {
            smart_vector::push_back(&mut ve_data.snapshots, Snapshot {
                pilgrim: current_epoch,
                locked_amount: ve_data.locked_amount,
                end_epoch: ve_data.end_epoch,
            });
        };
    }

    // Drains and destroys a snapshots vector (used when a VeToken is burned).
    fun destroy_snapshots(snapshots: SmartVector<Snapshot>) {
        let len = smart_vector::length(&snapshots);
        let i = 0;
        while (i < len) {
            smart_vector::pop_back(&mut snapshots);
            i = i + 1;
        };
        smart_vector::destroy_empty(snapshots);
    }

    fun update_total_locked_history(dao_address: address, current_total: u64) acquires TotalLockedHistory {
        let history = borrow_global_mut<TotalLockedHistory>(dao_address);
        let current_epoch = pilgrim::now();
        let len = smart_vector::length(&history.snapshots);
        if (len > 0) {
            let last_snap = smart_vector::borrow_mut(&mut history.snapshots, len - 1);
            if (last_snap.pilgrim == current_epoch) {
                last_snap.total_locked = current_total;
                return
            }
        };
        smart_vector::push_back(&mut history.snapshots, RegistrySnapshot {
            pilgrim: current_epoch,
            total_locked: current_total,
        });
    }

    // Deposits SupraCoin or FungibleAsset in the DAO rewards vault (auto-compounding).
    // Can only be called by harvest.
    public(friend) fun inject_bribes(dao_address: address, amount: u64) acquires VeTokenRegistry {
        let registry = borrow_global_mut<VeTokenRegistry>(dao_address);
        if (registry.total_locked > 0 && amount > 0) {
            registry.acc_rebase_per_share = registry.acc_rebase_per_share 
                + (((amount as u256) * PRECISION / (registry.total_locked as u256)) as u128);
        };
    }

    fun compound_rebase_internal(
        owner_addr: address,
        obj_addr: address,
        ve_data: &mut VeToken,
        registry: &mut VeTokenRegistry,
    ) {
        // Claim protocol rewards BEFORE changing locked_amount
        if (ve_data.locked_amount > 0) {
            harvest::claim_rewards_internal(ve_data.dao_address, owner_addr, obj_addr, ve_data.locked_amount);
        };

        // FIX (FUND-01): Do not distribute rebase to expired tokens.
        // This prevents an attacker from creating a short lock and holding it expired forever
        // as a liquid savings account that steals rebase from active lockers.
        let current_epoch = pilgrim::now();
        if (ve_data.end_epoch <= current_epoch) {
            ve_data.rebase_debt = math::calculate_rebase_debt(ve_data.locked_amount, registry.acc_rebase_per_share);
            harvest::checkpoint(ve_data.dao_address, obj_addr, ve_data.locked_amount);
            return
        };

        let earned_u128 = math::calculate_rebase_debt(ve_data.locked_amount, registry.acc_rebase_per_share);
        let pending_u128 = if (earned_u128 > ve_data.rebase_debt) { earned_u128 - ve_data.rebase_debt } else { 0 };
        let pending = (pending_u128 as u64);

        if (pending > 0) {
            let dao_signer = ledger::generate_signer(ve_data.dao_address);
            let fa = fungible_asset::withdraw(&dao_signer, registry.rebase_store, pending);
            
            let store = object::address_to_object<FungibleStore>(obj_addr);
            fungible_asset::deposit(store, fa);

            ve_data.locked_amount = ve_data.locked_amount + pending;
            registry.total_locked = registry.total_locked + pending;

            upsert_snapshot(ve_data);

            event::emit(RebaseCompounded { legacy: obj_addr, amount: pending });
        };

        ve_data.rebase_debt = math::calculate_rebase_debt(ve_data.locked_amount, registry.acc_rebase_per_share);

        // Checkpoint harvest rewards AFTER changing locked_amount
        harvest::checkpoint(ve_data.dao_address, obj_addr, ve_data.locked_amount);
    }

    // URI Generator (served by the API endpoint / configurable base_uri) 

    fun get_or_generate_uri(_dao_address: address, obj_addr: address, _amount: u64, _epochs: u64, registry: &VeTokenRegistry, _is_delegated: bool): String {
        if (string::is_empty(&registry.base_uri)) {
            // Fallback to the Next.js API endpoint to avoid EURI_TOO_LONG
            let uri = string::utf8(b"https://daos.hoglet.xyz/api/nft/");
            string::append(&mut uri, string_utils::to_string(&obj_addr));
            uri
        } else {
            let uri = registry.base_uri;
            string::append(&mut uri, string_utils::to_string(&obj_addr));
            uri
        }
    }

    fun update_svg_uri(obj_addr: address, dao_address: address, amount: u64, end_epoch: u64, is_delegated: bool) acquires VeTokenRefs, VeTokenRegistry {
        let refs = borrow_global<VeTokenRefs>(obj_addr);
        let registry = borrow_global<VeTokenRegistry>(dao_address);
        
        let current_epoch = pilgrim::now();
        let epochs_left = if (end_epoch > current_epoch) { end_epoch - current_epoch } else { 0 };
        let new_uri = get_or_generate_uri(dao_address, obj_addr, amount, epochs_left, registry, is_delegated);
        token::set_uri(&refs.mutator_ref, new_uri);
    }

    fun refresh_svg(obj_addr: address, ve_data: &VeToken, owner_addr: address) acquires VeTokenRefs, VeTokenRegistry {
        let is_delegated = option::is_some(&ve_data.delegate) && *option::borrow(&ve_data.delegate) != owner_addr;
        update_svg_uri(obj_addr, ve_data.dao_address, ve_data.locked_amount, ve_data.end_epoch, is_delegated);
    }


    public(friend) fun update_base_uri(dao_signer: &signer, new_uri: String) acquires VeTokenRegistry {
        let dao_address = signer::address_of(dao_signer);
        let registry = borrow_global_mut<VeTokenRegistry>(dao_address);
        registry.base_uri = new_uri;
    }

    // Public Functions 

    // --- Helper to reduce Bytecode Bloat ---
    // Extracted the repetitive setup for `compound_rebase_internal`
    fun prepare_and_compound(owner: &signer, legacy_addr: address): (address, address) acquires VeToken, VeTokenRegistry {
        let (owner_addr, legacy) = verify_owner_and_get_legacy(owner, legacy_addr);
        let obj_addr = legacy_addr;
        let dao_address = get_dao_address(legacy);
        
        {
            let ve_data = borrow_global_mut<VeToken>(obj_addr);
            let registry = borrow_global_mut<VeTokenRegistry>(ve_data.dao_address);
            compound_rebase_internal(owner_addr, obj_addr, ve_data, registry);
        };
        (owner_addr, dao_address)
    }

    public entry fun compound(caller: &signer, legacy_addr: address) acquires VeToken, VeTokenRegistry, VeTokenRefs {
        let (owner_addr, _) = prepare_and_compound(caller, legacy_addr);
        let obj_addr = legacy_addr;
        let ve_data = borrow_global_mut<VeToken>(obj_addr);
        
        refresh_svg(obj_addr, ve_data, owner_addr);
    }

    /// Entry point for Frontend/Wallets to create a lock. 
    /// Discards the returned Object<VeToken> since entry functions cannot return values.
    public entry fun create_lock_entry(
        user: &signer,
        dao_address: address,
        amount: u64,
        lock_epochs: u64,
    ) acquires VeTokenRegistry, TotalLockedHistory {
        let _nft_object = create_lock(user, dao_address, amount, lock_epochs);
    }

    public fun create_lock(
        user: &signer,
        dao_address: address,
        amount: u64,
        lock_epochs: u64,
    ): Object<VeToken> acquires VeTokenRegistry, TotalLockedHistory {
        assert!(amount > 0, error::invalid_argument(E_ZERO_AMOUNT));
        assert!(lock_epochs >= MIN_LOCK_EPOCHS, error::invalid_argument(E_LOCK_TOO_SHORT));
        assert!(lock_epochs <= MAX_LOCK_EPOCHS, error::invalid_argument(E_LOCK_TOO_LONG));

        // Sentinel: create_lock is pausable (withdraw is NEVER pausable)
        sentinel::assert_not_paused(dao_address);

        let registry = borrow_global_mut<VeTokenRegistry>(dao_address);
        let user_addr = signer::address_of(user);
        let current_epoch = pilgrim::now();
        let end_epoch = current_epoch + lock_epochs;

        let fa = primary_fungible_store::withdraw(user, registry.token_metadata, amount);

        // Generate NFT name: "veAERO Position #1"
        registry.mint_count = registry.mint_count + 1;
        let token_name = string::utf8(b"ve");
        string::append(&mut token_name, registry.token_symbol);
        string::append(&mut token_name, string::utf8(b" #"));
        string::append(&mut token_name, string_utils::to_string(&registry.mint_count));

        let creator_signer = object::generate_signer_for_extending(&registry.creator_extend_ref);
        
        let constructor_ref = token::create(
            &creator_signer,
            registry.collection_name, 
            string::utf8(b"Locked Governance Power"),
            token_name,
            option::none(),
            string::utf8(b""), // Updated dynamically right after
        );

        let obj_signer = object::generate_signer(&constructor_ref);
        let obj_addr = object::address_from_constructor_ref(&constructor_ref);

        let mutator_ref = token::generate_mutator_ref(&constructor_ref);
        
        // Ensure adding to total before generating SVG to correctly calculate the Share %
        registry.total_locked = registry.total_locked + amount;
        update_total_locked_history(dao_address, registry.total_locked);
        
        let dynamic_uri = get_or_generate_uri(dao_address, obj_addr, amount, lock_epochs, registry, false);
        token::set_uri(&mutator_ref, dynamic_uri);

        // Deposit into the Object's store.
        let store_constructor = fungible_asset::create_store(&constructor_ref, registry.token_metadata);
        fungible_asset::deposit(store_constructor, fa);

        let snapshots = smart_vector::new<Snapshot>();
        smart_vector::push_back(&mut snapshots, Snapshot {
            pilgrim: current_epoch,
            locked_amount: amount,
            end_epoch,
        });

        let initial_debt = math::calculate_rebase_debt(amount, registry.acc_rebase_per_share);

        move_to(&obj_signer, VeToken {
            dao_address,
            locked_amount: amount,
            end_epoch,
            snapshots,
            rebase_debt: initial_debt,
            token_metadata: registry.token_metadata,
            delegate: option::none(),
            delegator: user_addr,
            last_voted_epoch: 0,
        });

        move_to(&obj_signer, VeTokenRefs {
            extend_ref: object::generate_extend_ref(&constructor_ref),
            delete_ref: object::generate_delete_ref(&constructor_ref),
            mutator_ref: token::generate_mutator_ref(&constructor_ref),
        });

        // (total_locked was already increased above)

        let token_obj = object::object_from_constructor_ref<VeToken>(&constructor_ref);
        
        // Transfer the newly created NFT (Digital Asset) to the user
        object::transfer(&creator_signer, token_obj, user_addr);

        // Checkpoint for rewards (Must be called AFTER updating amount)
        harvest::checkpoint(dao_address, obj_addr, amount);

        // Calculate voting power for the event
        let voting_power = (((amount as u128) * (lock_epochs as u128) / (MAX_LOCK_EPOCHS as u128)) as u64);

        event::emit(LockCreated { owner: user_addr, legacy: obj_addr, dao_address, amount, end_epoch, voting_power });

        token_obj
    }

    public entry fun extend_lockup(
        owner: &signer,
        legacy_addr: address,
        additional_epochs: u64,
    ) acquires VeToken, VeTokenRegistry, VeTokenRefs {
        assert!(additional_epochs >= 1, error::invalid_argument(E_INVALID_EXTEND));
        let (owner_addr, dao_address) = prepare_and_compound(owner, legacy_addr);
        sentinel::assert_not_paused(dao_address);

        let obj_addr = legacy_addr;

        let ve_data = borrow_global_mut<VeToken>(obj_addr);
        let current_epoch = pilgrim::now();
        
        let old_end_epoch = ve_data.end_epoch;
        let new_end_epoch = if (old_end_epoch > current_epoch) {
            old_end_epoch + additional_epochs
        } else {
            current_epoch + additional_epochs
        };
        assert!(new_end_epoch <= current_epoch + MAX_LOCK_EPOCHS, error::invalid_state(E_LOCK_TOO_LONG));
        assert!(new_end_epoch >= current_epoch + MIN_LOCK_EPOCHS, error::invalid_argument(E_LOCK_TOO_SHORT));

        ve_data.end_epoch = new_end_epoch;

        upsert_snapshot(ve_data);

        // Update SVG to reflect the new lock time
        refresh_svg(obj_addr, ve_data, owner_addr);

        event::emit(LockExtended { owner: owner_addr, legacy: obj_addr, old_end_epoch, new_end_epoch });
    }

    public entry fun increase_amount(
        owner: &signer,
        legacy_addr: address,
        additional_amount: u64,
    ) acquires VeToken, VeTokenRegistry, VeTokenRefs, TotalLockedHistory {
        assert!(additional_amount > 0, error::invalid_argument(E_ZERO_AMOUNT));
        let (owner_addr, dao_address) = prepare_and_compound(owner, legacy_addr);
        sentinel::assert_not_paused(dao_address);

        let obj_addr = legacy_addr;

        let ve_data = borrow_global_mut<VeToken>(obj_addr);
        let registry = borrow_global_mut<VeTokenRegistry>(ve_data.dao_address);
        let current_epoch = pilgrim::now();
        
        assert!(ve_data.end_epoch > current_epoch, error::invalid_state(E_LOCK_EXPIRED));

        let fa = primary_fungible_store::withdraw(owner, ve_data.token_metadata, additional_amount);
        let store = object::address_to_object<FungibleStore>(obj_addr);
        fungible_asset::deposit(store, fa);

        let new_total = ve_data.locked_amount + additional_amount;
        ve_data.locked_amount = new_total;
        registry.total_locked = registry.total_locked + additional_amount;
        update_total_locked_history(ve_data.dao_address, registry.total_locked);

        ve_data.rebase_debt = math::calculate_rebase_debt(new_total, registry.acc_rebase_per_share);

        // Checkpoint for rewards (Must be called AFTER updating amount)
        harvest::checkpoint(ve_data.dao_address, obj_addr, new_total);

        upsert_snapshot(ve_data);

        // Update SVG to reflect the new amount
        refresh_svg(obj_addr, ve_data, owner_addr);

        event::emit(AmountIncreased { owner: owner_addr, legacy: obj_addr, added_amount: additional_amount, new_total });
    }

    public entry fun withdraw(
        owner: &signer,
        legacy_addr: address,
    ) acquires VeToken, VeTokenRefs, VeTokenRegistry, TotalLockedHistory {
        let (owner_addr, _) = prepare_and_compound(owner, legacy_addr);
        let obj_addr = legacy_addr;
        let current_epoch = pilgrim::now();
        let dao_address;

        {
            let ve_data = borrow_global<VeToken>(obj_addr);
            assert!(current_epoch >= ve_data.end_epoch, error::invalid_state(E_STILL_LOCKED));
            dao_address = ve_data.dao_address;
        };

        let VeToken { dao_address: _, locked_amount, end_epoch: _, snapshots, rebase_debt: _, token_metadata: _, delegate: _, delegator: _, last_voted_epoch: _ } =
            move_from<VeToken>(obj_addr);

        let registry = borrow_global_mut<VeTokenRegistry>(dao_address);
        registry.total_locked = registry.total_locked - locked_amount;
        update_total_locked_history(dao_address, registry.total_locked);

        destroy_snapshots(snapshots);

        let VeTokenRefs { extend_ref, delete_ref, mutator_ref: _ } =
            move_from<VeTokenRefs>(obj_addr);

        let obj_signer = object::generate_signer_for_extending(&extend_ref);
        let store = object::address_to_object<FungibleStore>(obj_addr);
        
        let fa = fungible_asset::withdraw(&obj_signer, store, locked_amount);
        primary_fungible_store::deposit(owner_addr, fa);

        fungible_asset::remove_store(&delete_ref);
        object::delete(delete_ref);

        // Checkpoint for rewards (0 because everything was withdrawn)
        harvest::checkpoint(dao_address, obj_addr, 0);

        event::emit(Withdrawn { owner: owner_addr, legacy: obj_addr, amount: locked_amount });
    }

    public entry fun merge(
        owner: &signer,
        from_legacy_addr: address,
        into_legacy_addr: address,
    ) acquires VeToken, VeTokenRefs, VeTokenRegistry, TotalLockedHistory {
        assert!(from_legacy_addr != into_legacy_addr, error::invalid_argument(E_INVALID_OBJECT));
        
        let (owner_addr, dao_address) = prepare_and_compound(owner, from_legacy_addr);
        let (_, _) = prepare_and_compound(owner, into_legacy_addr);

        // Ensure they belong to the same DAO & other preconditions
        {
            let from_ve_data = borrow_global<VeToken>(from_legacy_addr);
            let into_ve_data = borrow_global<VeToken>(into_legacy_addr);
            assert!(from_ve_data.dao_address == into_ve_data.dao_address, error::invalid_argument(E_INVALID_OBJECT));
            assert!(from_ve_data.end_epoch > pilgrim::now(), error::invalid_state(E_LOCK_EXPIRED));
            
            let current_epoch = pilgrim::now();
            let check_epoch = if (current_epoch > 0) { current_epoch - 1 } else { 0 };
            assert!(from_ve_data.last_voted_epoch < check_epoch, error::invalid_state(E_VOTED_RECENTLY));
        };

        // Sentinel: merge is pausable
        sentinel::assert_not_paused(dao_address);

        // Variables to extract from `from_legacy`
        let from_amount: u64;
        let from_end_epoch: u64;
        let old_delegate: Option<address>;
        let old_delegator: address;
        
        // 1. Move out VeToken and VeTokenRefs from `from_legacy`
        {
            let VeToken { dao_address: _, locked_amount, end_epoch, snapshots, rebase_debt: _, token_metadata: _, delegate, delegator, last_voted_epoch: _ } =
                move_from<VeToken>(from_legacy_addr);
            
            from_amount = locked_amount;
            from_end_epoch = end_epoch;
            old_delegate = delegate;
            old_delegator = delegator;

            destroy_snapshots(snapshots);
        };

        let VeTokenRefs { extend_ref, delete_ref, mutator_ref: _ } =
            move_from<VeTokenRefs>(from_legacy_addr);

        let from_obj_signer = object::generate_signer_for_extending(&extend_ref);
        let from_store = object::address_to_object<FungibleStore>(from_legacy_addr);
        
        // Withdraw FA from the old token
        let fa = fungible_asset::withdraw(&from_obj_signer, from_store, from_amount);

        // Delete the old token object
        fungible_asset::remove_store(&delete_ref);
        object::delete(delete_ref);

        if (option::is_some(&old_delegate)) {
            event::emit(DelegateChanged {
                legacy: from_legacy_addr,
                owner: old_delegator,
                old_delegate,
                new_delegate: option::none(),
            });
        };

        // 2. Deposit FA into the `into_legacy` store
        let into_store = object::address_to_object<FungibleStore>(into_legacy_addr);
        fungible_asset::deposit(into_store, fa);

        // 3. Update `into_legacy` metadata
        let new_total: u64;
        let new_end_epoch: u64;

        {
            let into_ve_data = borrow_global_mut<VeToken>(into_legacy_addr);
            
            new_total = into_ve_data.locked_amount + from_amount;
            into_ve_data.locked_amount = new_total;
            
            new_end_epoch = if (from_end_epoch > into_ve_data.end_epoch) {
                from_end_epoch
            } else {
                into_ve_data.end_epoch
            };
            into_ve_data.end_epoch = new_end_epoch;

            // Enforce MAX_LOCK_EPOCHS cap
            let current_epoch = pilgrim::now();
            if (new_end_epoch > current_epoch + MAX_LOCK_EPOCHS) {
                new_end_epoch = current_epoch + MAX_LOCK_EPOCHS;
                into_ve_data.end_epoch = new_end_epoch;
            };

            // Update rebase debt to prevent rebase drain exploit
            let registry = borrow_global_mut<VeTokenRegistry>(dao_address);
            registry.total_locked = registry.total_locked; // Just keeping track
            update_total_locked_history(dao_address, registry.total_locked);
            into_ve_data.rebase_debt = math::calculate_rebase_debt(new_total, registry.acc_rebase_per_share);

            // Correctly update snapshots
            upsert_snapshot(into_ve_data);
        };

        // Checkpoints
        harvest::checkpoint(dao_address, from_legacy_addr, 0);
        harvest::checkpoint(dao_address, into_legacy_addr, new_total);

        // Update SVG
        refresh_svg(into_legacy_addr, borrow_global<VeToken>(into_legacy_addr), owner_addr);

        event::emit(LockMerged { owner: owner_addr, from_legacy: from_legacy_addr, into_legacy: into_legacy_addr, amount_merged: from_amount, new_total, new_end_epoch });
    }

    // Delegation 
    // Velodrome v2 Standard: the owner can delegate their voting power to another address.
    // The delegate can vote with the veToken but CANNOT withdraw/extend/merge.
    // The owner can revoke at any time.

    // Delegates the voting power of a veToken to another address.
    // The delegate will be able to vote in `witness::cast_vote` using this veToken.
    public entry fun delegate_voting_power(
        owner: &signer,
        legacy_addr: address,
        delegate_addr: address,
    ) acquires VeToken, VeTokenRefs, VeTokenRegistry {
        let (owner_addr, _) = verify_owner_and_get_legacy(owner, legacy_addr);
        assert!(delegate_addr != owner_addr, error::invalid_argument(E_SELF_DELEGATE));

        let obj_addr = legacy_addr;
        let ve_data = borrow_global_mut<VeToken>(obj_addr);
        
        let old_delegate = ve_data.delegate;
        ve_data.delegate = option::some(delegate_addr);
        ve_data.delegator = owner_addr;

        event::emit(DelegateChanged {
            legacy: obj_addr,
            owner: owner_addr,
            old_delegate,
            new_delegate: option::some(delegate_addr),
        });

        // Update SVG to reflect DELEGATED status
        update_svg_uri(obj_addr, ve_data.dao_address, ve_data.locked_amount, ve_data.end_epoch, true);
    }

    // Revokes the vote delegation. The owner regains control of their voting power.
    public entry fun revoke_delegation(
        owner: &signer,
        legacy_addr: address,
    ) acquires VeToken, VeTokenRefs, VeTokenRegistry {
        let (owner_addr, _) = verify_owner_and_get_legacy(owner, legacy_addr);

        let obj_addr = legacy_addr;
        let ve_data = borrow_global_mut<VeToken>(obj_addr);
        
        let old_delegate = ve_data.delegate;
        ve_data.delegate = option::none();
        ve_data.delegator = owner_addr;

        event::emit(DelegateChanged {
            legacy: obj_addr,
            owner: owner_addr,
            old_delegate,
            new_delegate: option::none(),
        });

        // Update SVG to reflect SELF_VOTING status
        update_svg_uri(obj_addr, ve_data.dao_address, ve_data.locked_amount, ve_data.end_epoch, false);
    }

    // Checks if an address is the current delegate of a veToken.
    // Used by witness::cast_vote to authorize delegated votes.
    #[view]
    public fun is_delegate(ve_token_obj: Object<VeToken>, user: address): bool acquires VeToken {
        let ve_token = borrow_global<VeToken>(object::object_address(&ve_token_obj));
        
        // Implicitly void delegation if the token was transferred to a new owner
        if (object::owner(ve_token_obj) != ve_token.delegator) return false;

        option::contains(&ve_token.delegate, &user)
    }

    public(friend) fun set_last_voted_epoch(ve_token_obj: Object<VeToken>, epoch: u64) acquires VeToken {
        let ve_token = borrow_global_mut<VeToken>(object::object_address(&ve_token_obj));
        ve_token.last_voted_epoch = epoch;
    }

    // Views 
    #[view]
    public fun get_voting_power(legacy: Object<VeToken>): u64 acquires VeToken {
        get_voting_power_at(legacy, pilgrim::now())
    }

    #[view]
    public fun get_voting_power_at(
        legacy: Object<VeToken>,
        query_epoch: u64,
    ): u64 acquires VeToken {
        let obj_addr = object::object_address(&legacy);
        let ve_data = borrow_global<VeToken>(obj_addr);

        if (query_epoch >= ve_data.end_epoch) return 0;

        let snap_amount = ve_data.locked_amount;
        let snap_end    = ve_data.end_epoch;

        let len = smart_vector::length(&ve_data.snapshots);
        if (len > 0) {
            // SECURITY FIX (VULN-04): If the queried epoch predates the first
            // snapshot, the lock did not exist yet and its power must be 0.
            // Previously the fallback silently returned the CURRENT power for
            // past epochs, so a freshly created lock could propose/vote in the
            // same epoch it was created, bypassing the anti-flash-loan
            // "previous epoch" protection used by herald, witness and zeal.
            let first_snap = smart_vector::borrow(&ve_data.snapshots, 0);
            if (query_epoch < first_snap.pilgrim) return 0;

            let i = len;
            while (i > 0) {
                i = i - 1;
                let snap = smart_vector::borrow(&ve_data.snapshots, i);
                if (snap.pilgrim <= query_epoch) {
                    snap_amount = snap.locked_amount;
                    snap_end    = snap.end_epoch;
                    break
                };
            };
        };

        if (query_epoch >= snap_end) return 0;

        let epochs_left = snap_end - query_epoch;
        (((snap_amount as u128) * (epochs_left as u128) / (MAX_LOCK_EPOCHS as u128)) as u64)
    }

    #[view]
    public fun locked_amount(legacy: Object<VeToken>): u64 acquires VeToken {
        borrow_global<VeToken>(object::object_address(&legacy)).locked_amount
    }

    #[view]
    public fun is_expired(legacy: Object<VeToken>): bool acquires VeToken {
        pilgrim::now() >= borrow_global<VeToken>(object::object_address(&legacy)).end_epoch
    }

    #[view]
    public fun get_nft_metadata_info(legacy: Object<VeToken>): (u64, u64, address, u64, String, String, u64) acquires VeToken, VeTokenRegistry {
        let obj_addr = object::object_address(&legacy);
        let ve_data = borrow_global<VeToken>(obj_addr);
        let registry = borrow_global<VeTokenRegistry>(ve_data.dao_address);
        let current_epoch = pilgrim::now();

        (
            ve_data.locked_amount,
            ve_data.end_epoch,
            ve_data.dao_address,
            registry.total_locked,
            registry.collection_name,
            registry.token_symbol,
            current_epoch
        )
    }

    #[view]
    public fun get_token_metadata_address(dao_address: address): address acquires VeTokenRegistry {
        if (exists<VeTokenRegistry>(dao_address)) {
            object::object_address(&borrow_global<VeTokenRegistry>(dao_address).token_metadata)
        } else {
            @0x0
        }
    }

    #[view]
    public fun get_total_locked(dao_address: address): u64 acquires VeTokenRegistry {
        if (!exists<VeTokenRegistry>(dao_address)) return 0;
        borrow_global<VeTokenRegistry>(dao_address).total_locked
    }

    #[view]
    public fun get_total_locked_at(dao_address: address, query_epoch: u64): u64 acquires VeTokenRegistry, TotalLockedHistory {
        if (!exists<TotalLockedHistory>(dao_address)) {
            // Fallback for DAOs that don't have the history initialized
            return get_total_locked(dao_address)
        };

        let history = borrow_global<TotalLockedHistory>(dao_address);
        let len = smart_vector::length(&history.snapshots);
        if (len == 0) return 0;

        let first_snap = smart_vector::borrow(&history.snapshots, 0);
        if (query_epoch < first_snap.pilgrim) return 0;

        let i = len;
        while (i > 0) {
            i = i - 1;
            let snap = smart_vector::borrow(&history.snapshots, i);
            if (snap.pilgrim <= query_epoch) {
                return snap.total_locked
            };
        };
        0
    }

    #[view]
    public fun get_dao_token_address(dao_address: address): address acquires VeTokenRegistry {
        if (!exists<VeTokenRegistry>(dao_address)) return @0x0;
        object::object_address(&borrow_global<VeTokenRegistry>(dao_address).token_metadata)
    }

    #[view]
    public fun get_rebase_store_address(dao_address: address): address acquires VeTokenRegistry {
        let registry = borrow_global<VeTokenRegistry>(dao_address);
        object::object_address(&registry.rebase_store)
    }

    #[view]
    public fun get_delegate(legacy: Object<VeToken>): Option<address> acquires VeToken {
        let obj_addr = object::object_address(&legacy);
        let ve_token = borrow_global<VeToken>(obj_addr);
        
        if (object::owner(legacy) != ve_token.delegator) {
            option::none()
        } else {
            ve_token.delegate
        }
    }

    #[view]
    public fun get_dao_address(legacy: Object<VeToken>): address acquires VeToken {
        borrow_global<VeToken>(object::object_address(&legacy)).dao_address
    }

    #[view]
    public fun get_batch_nft_metadata(nfts: vector<address>, target_dao: address): (
        vector<address>, // valid_nfts
        vector<u64>,     // amounts
        vector<u64>,     // end_epochs
        vector<u64>,     // powers
        vector<bool>,    // is_delegated
        u64              // current_epoch
    ) acquires VeToken {
        let valid_nfts = vector::empty<address>();
        let amounts = vector::empty<u64>();
        let end_epochs = vector::empty<u64>();
        let powers = vector::empty<u64>();
        let delegated_flags = vector::empty<bool>();
        let current_epoch = pilgrim::now();

        let i = 0;
        let len = vector::length(&nfts);
        while (i < len) {
            let nft_addr = *vector::borrow(&nfts, i);
            if (exists<VeToken>(nft_addr)) {
                let ve_data = borrow_global<VeToken>(nft_addr);
                if (ve_data.dao_address == target_dao) {
                    let locked_amount = ve_data.locked_amount;
                    let end_epoch = ve_data.end_epoch;
                    let is_delegated = if (object::owner(object::address_to_object<VeToken>(nft_addr)) != ve_data.delegator) {
                        false
                    } else {
                        option::is_some(&ve_data.delegate)
                    };
                    
                    let epochs_left = if (end_epoch > current_epoch) { end_epoch - current_epoch } else { 0 };
                    let power = (((locked_amount as u128) * (epochs_left as u128) / (MAX_LOCK_EPOCHS as u128)) as u64);

                    vector::push_back(&mut valid_nfts, nft_addr);
                    vector::push_back(&mut amounts, locked_amount);
                    vector::push_back(&mut end_epochs, end_epoch);
                    vector::push_back(&mut powers, power);
                    vector::push_back(&mut delegated_flags, is_delegated);
                };
            };
            i = i + 1;
        };

        (valid_nfts, amounts, end_epochs, powers, delegated_flags, current_epoch)
    }

    // External Rewards (Harvest) 

    public entry fun claim_rewards(
        owner: &signer,
        legacy_addr: address,
    ) acquires VeToken, VeTokenRegistry {
        let (owner_addr, _) = verify_owner_and_get_legacy(owner, legacy_addr);
        
        let obj_addr = legacy_addr;
        
        {
            let ve_data = borrow_global_mut<VeToken>(obj_addr);
            let registry = borrow_global_mut<VeTokenRegistry>(ve_data.dao_address);
            compound_rebase_internal(owner_addr, obj_addr, ve_data, registry);
        };
    }

    #[view]
    public fun pending_rewards(legacy: Object<VeToken>): u64 acquires VeToken {
        let obj_addr = object::object_address(&legacy);
        let ve_data = borrow_global<VeToken>(obj_addr);
        
        harvest::calculate_pending(
            ve_data.dao_address,
            obj_addr,
            ve_data.locked_amount
        )
    }

    // --- Helpers for Deduplication ---

    fun verify_owner_and_get_legacy(owner: &signer, legacy_addr: address): (address, Object<VeToken>) {
        let owner_addr = signer::address_of(owner);
        assert!(object::is_object(legacy_addr), error::invalid_argument(E_INVALID_OBJECT));
        let legacy = object::address_to_object<VeToken>(legacy_addr);
        assert!(object::is_owner(legacy, owner_addr), error::permission_denied(E_NOT_OWNER));
        (owner_addr, legacy)
    }
}
