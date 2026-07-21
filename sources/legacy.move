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

    struct Snapshot has store, drop {
        pilgrim: u64,
        locked_amount: u64,
        end_epoch: u64,
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
        let collection_name = string::utf8(b"Governance of ");
        string::append(&mut collection_name, dao_name);

        let collection_desc = string::utf8(b"Exclusive voting rights and economic power in the ");
        string::append(&mut collection_desc, dao_name);
        string::append(&mut collection_desc, string::utf8(b" ecosystem."));

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
        };
        fungible_asset::deposit(registry.rebase_store, rebase_fa);
    }

    public(friend) fun inject_rewards(
        dao_address: address, 
        reward: FungibleAsset
    ) acquires VeTokenRegistry {
        let registry = borrow_global<VeTokenRegistry>(dao_address);
        harvest::inject_rewards(dao_address, reward, registry.total_locked);
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
            ve_data.rebase_debt = (((ve_data.locked_amount as u256) * (registry.acc_rebase_per_share as u256) / PRECISION) as u128);
            harvest::checkpoint(ve_data.dao_address, obj_addr, ve_data.locked_amount);
            return
        };

        let earned_u128 = (((ve_data.locked_amount as u256) * (registry.acc_rebase_per_share as u256) / PRECISION) as u128);
        let pending_u128 = if (earned_u128 > ve_data.rebase_debt) { earned_u128 - ve_data.rebase_debt } else { 0 };
        let pending = (pending_u128 as u64);

        if (pending > 0) {
            let dao_signer = ledger::generate_signer(ve_data.dao_address);
            let fa = fungible_asset::withdraw(&dao_signer, registry.rebase_store, pending);
            
            let store = object::address_to_object<FungibleStore>(obj_addr);
            fungible_asset::deposit(store, fa);

            ve_data.locked_amount = ve_data.locked_amount + pending;
            registry.total_locked = registry.total_locked + pending;
            
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

            event::emit(RebaseCompounded { legacy: obj_addr, amount: pending });
        };

        ve_data.rebase_debt = (((ve_data.locked_amount as u256) * (registry.acc_rebase_per_share as u256) / PRECISION) as u128);

        // Checkpoint harvest rewards AFTER changing locked_amount
        harvest::checkpoint(ve_data.dao_address, obj_addr, ve_data.locked_amount);
    }

    // SVG Generator (100% On-Chain Cyberpunk V5) 

    fun format_compact(raw_amount: u64, decimals: u8): String {
        let divisor = 1;
        let i = 0;
        while (i < decimals) {
            divisor = divisor * 10;
            i = i + 1;
        };
        let amt = raw_amount / divisor;
        if (amt >= 1_000_000_000_000) {
            let whole = amt / 1_000_000_000_000;
            let frac = (amt % 1_000_000_000_000) / 100_000_000_000;
            let str = string_utils::to_string(&whole);
            string::append(&mut str, string::utf8(b"."));
            string::append(&mut str, string_utils::to_string(&frac));
            string::append(&mut str, string::utf8(b"T"));
            str
        } else if (amt >= 1_000_000_000) {
            let whole = amt / 1_000_000_000;
            let frac = (amt % 1_000_000_000) / 100_000_000;
            let str = string_utils::to_string(&whole);
            string::append(&mut str, string::utf8(b"."));
            string::append(&mut str, string_utils::to_string(&frac));
            string::append(&mut str, string::utf8(b"B"));
            str
        } else if (amt >= 1_000_000) {
            let whole = amt / 1_000_000;
            let frac = (amt % 1_000_000) / 100_000;
            let str = string_utils::to_string(&whole);
            string::append(&mut str, string::utf8(b"."));
            string::append(&mut str, string_utils::to_string(&frac));
            string::append(&mut str, string::utf8(b"M"));
            str
        } else if (amt >= 1_000) {
            let whole = amt / 1_000;
            let frac = (amt % 1_000) / 100;
            let str = string_utils::to_string(&whole);
            string::append(&mut str, string::utf8(b"."));
            string::append(&mut str, string_utils::to_string(&frac));
            string::append(&mut str, string::utf8(b"K"));
            str
        } else {
            let str = string_utils::to_string(&amt);
            string::append(&mut str, string::utf8(b".00"));
            str
        }
    }

    fun format_boost(epochs: u64): String {
        let boost_percent = (epochs * 100) / MAX_LOCK_EPOCHS;
        if (boost_percent >= 100) {
            string::utf8(b"1.00x")
        } else {
            let str = string::utf8(b"0.");
            if (boost_percent < 10) {
                string::append(&mut str, string::utf8(b"0"));
            };
            string::append(&mut str, string_utils::to_string(&boost_percent));
            string::append(&mut str, string::utf8(b"x"));
            str
        }
    }



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

    public(friend) fun update_base_uri(dao_signer: &signer, new_uri: String) acquires VeTokenRegistry {
        let dao_address = signer::address_of(dao_signer);
        let registry = borrow_global_mut<VeTokenRegistry>(dao_address);
        registry.base_uri = new_uri;
    }

    // Public Functions 

    public entry fun compound(caller: &signer, legacy_addr: address) acquires VeToken, VeTokenRegistry, VeTokenRefs {
        assert!(object::is_object(legacy_addr), error::invalid_argument(E_INVALID_OBJECT));
        let legacy = object::address_to_object<VeToken>(legacy_addr);
        let owner_addr = object::owner(legacy);
        assert!(owner_addr == signer::address_of(caller), error::permission_denied(E_NOT_OWNER));
        let obj_addr = legacy_addr;
        let ve_data = borrow_global_mut<VeToken>(obj_addr);
        let registry = borrow_global_mut<VeTokenRegistry>(ve_data.dao_address);
        
        compound_rebase_internal(owner_addr, obj_addr, ve_data, registry);
        
        let is_delegated = option::is_some(&ve_data.delegate) && *option::borrow(&ve_data.delegate) != owner_addr;
        update_svg_uri(obj_addr, ve_data.dao_address, ve_data.locked_amount, ve_data.end_epoch, is_delegated);
    }

    /// Entry point for Frontend/Wallets to create a lock. 
    /// Discards the returned Object<VeToken> since entry functions cannot return values.
    public entry fun create_lock_entry(
        user: &signer,
        dao_address: address,
        amount: u64,
        lock_epochs: u64,
    ) acquires VeTokenRegistry {
        let _nft_object = create_lock(user, dao_address, amount, lock_epochs);
    }

    public fun create_lock(
        user: &signer,
        dao_address: address,
        amount: u64,
        lock_epochs: u64,
    ): Object<VeToken> acquires VeTokenRegistry {
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
        string::append(&mut token_name, string::utf8(b" Position #"));
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

        let initial_debt = (((amount as u256) * (registry.acc_rebase_per_share as u256) / PRECISION) as u128);

        move_to(&obj_signer, VeToken {
            dao_address,
            locked_amount: amount,
            end_epoch,
            snapshots,
            rebase_debt: initial_debt,
            token_metadata: registry.token_metadata,
            delegate: option::none(),
            delegator: user_addr,
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
        let owner_addr = signer::address_of(owner);
        assert!(object::is_object(legacy_addr), error::invalid_argument(E_INVALID_OBJECT));
        let legacy = object::address_to_object<VeToken>(legacy_addr);
        assert!(object::is_owner(legacy, owner_addr), error::permission_denied(E_NOT_OWNER));

        let obj_addr = legacy_addr;
        
        {
            let ve_data = borrow_global_mut<VeToken>(obj_addr);
            let registry = borrow_global_mut<VeTokenRegistry>(ve_data.dao_address);
            compound_rebase_internal(owner_addr, obj_addr, ve_data, registry);
        };

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

        let len = smart_vector::length(&ve_data.snapshots);
        if (len > 0 && smart_vector::borrow(&ve_data.snapshots, len - 1).pilgrim == current_epoch) {
            let snap = smart_vector::borrow_mut(&mut ve_data.snapshots, len - 1);
            snap.locked_amount = ve_data.locked_amount;
            snap.end_epoch = new_end_epoch;
        } else {
            smart_vector::push_back(&mut ve_data.snapshots, Snapshot {
                pilgrim: current_epoch,
                locked_amount: ve_data.locked_amount,
                end_epoch: new_end_epoch,
            });
        };

        // Update SVG to reflect the new lock time
        let is_delegated = option::is_some(&ve_data.delegate) && *option::borrow(&ve_data.delegate) != owner_addr;
        update_svg_uri(obj_addr, ve_data.dao_address, ve_data.locked_amount, new_end_epoch, is_delegated);

        event::emit(LockExtended { owner: owner_addr, legacy: obj_addr, old_end_epoch, new_end_epoch });
    }

    public entry fun increase_amount(
        owner: &signer,
        legacy_addr: address,
        additional_amount: u64,
    ) acquires VeToken, VeTokenRegistry, VeTokenRefs {
        assert!(additional_amount > 0, error::invalid_argument(E_ZERO_AMOUNT));
        let owner_addr = signer::address_of(owner);
        assert!(object::is_object(legacy_addr), error::invalid_argument(E_INVALID_OBJECT));
        let legacy = object::address_to_object<VeToken>(legacy_addr);
        assert!(object::is_owner(legacy, owner_addr), error::permission_denied(E_NOT_OWNER));

        let obj_addr = legacy_addr;
        
        {
            let ve_data = borrow_global_mut<VeToken>(obj_addr);
            let registry = borrow_global_mut<VeTokenRegistry>(ve_data.dao_address);
            compound_rebase_internal(owner_addr, obj_addr, ve_data, registry);
        };

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

        ve_data.rebase_debt = (((new_total as u256) * (registry.acc_rebase_per_share as u256) / PRECISION) as u128);

        // Checkpoint for rewards (Must be called AFTER updating amount)
        harvest::checkpoint(ve_data.dao_address, obj_addr, new_total);

        let len = smart_vector::length(&ve_data.snapshots);
        if (len > 0 && smart_vector::borrow(&ve_data.snapshots, len - 1).pilgrim == current_epoch) {
            let snap = smart_vector::borrow_mut(&mut ve_data.snapshots, len - 1);
            snap.locked_amount = new_total;
            snap.end_epoch = ve_data.end_epoch;
        } else {
            smart_vector::push_back(&mut ve_data.snapshots, Snapshot {
                pilgrim: current_epoch,
                locked_amount: new_total,
                end_epoch: ve_data.end_epoch,
            });
        };

        // Update SVG to reflect the new amount
        let is_delegated = option::is_some(&ve_data.delegate) && *option::borrow(&ve_data.delegate) != owner_addr;
        update_svg_uri(obj_addr, ve_data.dao_address, new_total, ve_data.end_epoch, is_delegated);

        event::emit(AmountIncreased { owner: owner_addr, legacy: obj_addr, added_amount: additional_amount, new_total });
    }

    public entry fun withdraw(
        owner: &signer,
        legacy_addr: address,
    ) acquires VeToken, VeTokenRefs, VeTokenRegistry {
        let owner_addr = signer::address_of(owner);
        assert!(object::is_object(legacy_addr), error::invalid_argument(E_INVALID_OBJECT));
        let legacy = object::address_to_object<VeToken>(legacy_addr);
        assert!(object::is_owner(legacy, owner_addr), error::permission_denied(E_NOT_OWNER));

        let obj_addr = legacy_addr;
        
        {
            let ve_data = borrow_global_mut<VeToken>(obj_addr);
            let registry = borrow_global_mut<VeTokenRegistry>(ve_data.dao_address);
            compound_rebase_internal(owner_addr, obj_addr, ve_data, registry);
        };

        let current_epoch = pilgrim::now();
        let dao_address;

        {
            let ve_data = borrow_global<VeToken>(obj_addr);
            assert!(current_epoch >= ve_data.end_epoch, error::invalid_state(E_STILL_LOCKED));
            dao_address = ve_data.dao_address;
        };

        let VeToken { dao_address: _, locked_amount, end_epoch: _, snapshots, rebase_debt: _, token_metadata: _, delegate: _, delegator: _ } =
            move_from<VeToken>(obj_addr);

        let registry = borrow_global_mut<VeTokenRegistry>(dao_address);
        registry.total_locked = registry.total_locked - locked_amount;

        smart_vector::destroy_empty({
            let len = smart_vector::length(&snapshots);
            let i = 0;
            while (i < len) {
                smart_vector::pop_back(&mut snapshots);
                i = i + 1;
            };
            snapshots
        });

        let VeTokenRefs { extend_ref, delete_ref, mutator_ref: _ } =
            move_from<VeTokenRefs>(obj_addr);

        let obj_signer = object::generate_signer_for_extending(&extend_ref);
        let store = object::address_to_object<FungibleStore>(obj_addr);
        
        let fa = fungible_asset::withdraw(&obj_signer, store, locked_amount);
        primary_fungible_store::deposit(owner_addr, fa);

        object::delete(delete_ref);

        // Checkpoint for rewards (0 because everything was withdrawn)
        harvest::checkpoint(dao_address, obj_addr, 0);

        event::emit(Withdrawn { owner: owner_addr, legacy: obj_addr, amount: locked_amount });
    }

    public entry fun merge(
        owner: &signer,
        from_legacy_addr: address,
        into_legacy_addr: address,
    ) acquires VeToken, VeTokenRefs, VeTokenRegistry {
        let owner_addr = signer::address_of(owner);
        assert!(from_legacy_addr != into_legacy_addr, error::invalid_argument(E_INVALID_OBJECT));
        
        assert!(object::is_object(from_legacy_addr), error::invalid_argument(E_INVALID_OBJECT));
        assert!(object::is_object(into_legacy_addr), error::invalid_argument(E_INVALID_OBJECT));
        
        let from_legacy = object::address_to_object<VeToken>(from_legacy_addr);
        let into_legacy = object::address_to_object<VeToken>(into_legacy_addr);
        
        assert!(object::is_owner(from_legacy, owner_addr), error::permission_denied(E_NOT_OWNER));
        assert!(object::is_owner(into_legacy, owner_addr), error::permission_denied(E_NOT_OWNER));

        // Get DAO Address and ensure they belong to the same DAO
        let dao_address;
        {
            let from_ve_data = borrow_global<VeToken>(from_legacy_addr);
            let into_ve_data = borrow_global<VeToken>(into_legacy_addr);
            assert!(from_ve_data.dao_address == into_ve_data.dao_address, error::invalid_argument(E_INVALID_OBJECT));
            assert!(from_ve_data.end_epoch > pilgrim::now(), error::invalid_state(E_LOCK_EXPIRED));
            dao_address = from_ve_data.dao_address;
        };

        // Sentinel: merge is pausable
        sentinel::assert_not_paused(dao_address);

        // Compound rebase for BOTH tokens before proceeding
        {
            let registry = borrow_global_mut<VeTokenRegistry>(dao_address);
            let from_ve_data = borrow_global_mut<VeToken>(from_legacy_addr);
            compound_rebase_internal(owner_addr, from_legacy_addr, from_ve_data, registry);
        };
        {
            let registry = borrow_global_mut<VeTokenRegistry>(dao_address);
            let into_ve_data = borrow_global_mut<VeToken>(into_legacy_addr);
            compound_rebase_internal(owner_addr, into_legacy_addr, into_ve_data, registry);
        };

        // Variables to extract from `from_legacy`
        let from_amount: u64;
        let from_end_epoch: u64;
        let old_delegate: Option<address>;
        let old_delegator: address;
        
        // 1. Move out VeToken and VeTokenRefs from `from_legacy`
        {
            let VeToken { dao_address: _, locked_amount, end_epoch, snapshots, rebase_debt: _, token_metadata: _, delegate, delegator } =
                move_from<VeToken>(from_legacy_addr);
            
            from_amount = locked_amount;
            from_end_epoch = end_epoch;
            old_delegate = delegate;
            old_delegator = delegator;

            smart_vector::destroy_empty({
                let len = smart_vector::length(&snapshots);
                let i = 0;
                while (i < len) {
                    smart_vector::pop_back(&mut snapshots);
                    i = i + 1;
                };
                snapshots
            });
        };

        let VeTokenRefs { extend_ref, delete_ref, mutator_ref: _ } =
            move_from<VeTokenRefs>(from_legacy_addr);

        let from_obj_signer = object::generate_signer_for_extending(&extend_ref);
        let from_store = object::address_to_object<FungibleStore>(from_legacy_addr);
        
        // Withdraw FA from the old token
        let fa = fungible_asset::withdraw(&from_obj_signer, from_store, from_amount);

        // Delete the old token object
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
        let is_delegated: bool;
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
            let registry = borrow_global<VeTokenRegistry>(dao_address);
            into_ve_data.rebase_debt = (((new_total as u256) * (registry.acc_rebase_per_share as u256) / PRECISION) as u128);

            // Correctly update snapshots
            let len = smart_vector::length(&into_ve_data.snapshots);
            if (len > 0 && smart_vector::borrow(&into_ve_data.snapshots, len - 1).pilgrim == current_epoch) {
                let snap = smart_vector::borrow_mut(&mut into_ve_data.snapshots, len - 1);
                snap.locked_amount = new_total;
                snap.end_epoch = new_end_epoch;
            } else {
                smart_vector::push_back(&mut into_ve_data.snapshots, Snapshot {
                    pilgrim: current_epoch,
                    locked_amount: new_total,
                    end_epoch: new_end_epoch,
                });
            };

            is_delegated = option::is_some(&into_ve_data.delegate) && *option::borrow(&into_ve_data.delegate) != owner_addr;
        };

        // Checkpoints
        harvest::checkpoint(dao_address, from_legacy_addr, 0);
        harvest::checkpoint(dao_address, into_legacy_addr, new_total);

        // Update SVG
        update_svg_uri(into_legacy_addr, dao_address, new_total, new_end_epoch, is_delegated);

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
        let owner_addr = signer::address_of(owner);
        assert!(object::is_object(legacy_addr), error::invalid_argument(E_INVALID_OBJECT));
        let legacy = object::address_to_object<VeToken>(legacy_addr);
        assert!(object::is_owner(legacy, owner_addr), error::permission_denied(E_NOT_OWNER));
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
        let owner_addr = signer::address_of(owner);
        assert!(object::is_object(legacy_addr), error::invalid_argument(E_INVALID_OBJECT));
        let legacy = object::address_to_object<VeToken>(legacy_addr);
        assert!(object::is_owner(legacy, owner_addr), error::permission_denied(E_NOT_OWNER));

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
    public fun is_delegate(legacy: Object<VeToken>, addr: address): bool acquires VeToken {
        let obj_addr = object::object_address(&legacy);
        if (!exists<VeToken>(obj_addr)) return false;
        let ve_data = borrow_global<VeToken>(obj_addr);
        
        // Implicitly void delegation if the token was transferred to a new owner
        if (object::owner(legacy) != ve_data.delegator) return false;

        option::is_some(&ve_data.delegate) && *option::borrow(&ve_data.delegate) == addr
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
    public fun get_dao_token_address(dao_address: address): address acquires VeTokenRegistry {
        if (!exists<VeTokenRegistry>(dao_address)) return @0x0;
        object::object_address(&borrow_global<VeTokenRegistry>(dao_address).token_metadata)
    }

    #[view]
    public fun get_delegate(legacy: Object<VeToken>): Option<address> acquires VeToken {
        let obj_addr = object::object_address(&legacy);
        borrow_global<VeToken>(obj_addr).delegate
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
                    let is_delegated = option::is_some(&ve_data.delegate);
                    
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
        let owner_addr = signer::address_of(owner);
        assert!(object::is_object(legacy_addr), error::invalid_argument(E_INVALID_OBJECT));
        let legacy = object::address_to_object<VeToken>(legacy_addr);
        assert!(object::is_owner(legacy, owner_addr), error::permission_denied(E_NOT_OWNER));
        
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
}
