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
    use std::error;
    use supra_framework::fungible_asset::{
        Self, FungibleAsset, Metadata, FungibleStore
    };
    use supra_framework::object::{Self, Object, ExtendRef, DeleteRef};
    use supra_framework::primary_fungible_store;
    use supra_framework::dispatchable_fungible_asset;
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
    use dao_factory::scan::{Self, RegistrySnapshot, Snapshot};
    use dao_tokens::smart_token;

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
    const E_BLACKLISTED: u64        = 12;

    const MIN_LOCK_EPOCHS: u64 = 3;    
    const MAX_LOCK_EPOCHS: u64 = 207;  

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

    // Snapshot / RegistrySnapshot moved to dao_factory::types (dao_libs_v2)
    // so the scan helpers can operate on them outside the core package.
    // Abilities (copy, drop, store) and fields are identical.

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

        // FIX (audit10 C3): plain-FA DAOs have no TaxFreeRouter and therefore
        // no cap to withdraw from rebase_store with. Redirecting their rebase
        // to the treasury keeps acc_rebase_per_share hard at 0, so the rebase
        // withdrawal in compound_rebase_internal is unreachable for them
        // (pending is always 0). Smart-token DAOs are unaffected.
        if (registry.total_locked > 0 && amount > 0 && dao_factory::tax_router::has_tax_free_router(dao_address)) {
            registry.acc_rebase_per_share = math::add_per_share(amount, registry.total_locked, registry.acc_rebase_per_share);
            dispatchable_fungible_asset::deposit(registry.rebase_store, rebase_fa);
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
    // increase, merge). Logic lives in dao_factory::scan (dao_libs).
    fun upsert_snapshot(ve_data: &mut VeToken) {
        scan::upsert_snapshot(&mut ve_data.snapshots, pilgrim::now(), ve_data.locked_amount, ve_data.end_epoch);
    }

    fun update_total_locked_history(dao_address: address, current_total: u64) acquires TotalLockedHistory {
        let history = borrow_global_mut<TotalLockedHistory>(dao_address);
        scan::upsert_registry_snapshot(&mut history.snapshots, pilgrim::now(), current_total);
    }

    // Deposits SupraCoin or FungibleAsset in the DAO rewards vault (auto-compounding).
    // Can only be called by harvest.
    public(friend) fun inject_bribes(dao_address: address, amount: u64) acquires VeTokenRegistry {
        let registry = borrow_global_mut<VeTokenRegistry>(dao_address);
        // FIX (audit10 C3): same invariant as inject_rebase without a
        // TaxFreeRouter nothing can ever withdraw from rebase_store, so the
        // accumulator must not grow (this function moves no FA itself; the
        // caller is responsible for the funds).
        if (registry.total_locked > 0 && amount > 0 && dao_factory::tax_router::has_tax_free_router(dao_address)) {
            registry.acc_rebase_per_share = math::add_per_share(amount, registry.total_locked, registry.acc_rebase_per_share);
        };
    }

    fun compound_rebase_internal(
        owner: &signer,
        obj_addr: address,
        ve_data: &mut VeToken,
        registry: &mut VeTokenRegistry,
    ) {
        let owner_addr = signer::address_of(owner);
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
            let store = object::address_to_object<FungibleStore>(obj_addr);
            // INVARIANT (audit10 C3): for plain-FA DAOs acc_rebase_per_share
            // is hard 0 (both injectors are gated), so pending is always 0
            // here and rebase_store is never touched without the cap.
            transfer_tax_free(ve_data.dao_address, owner, registry.rebase_store, store, pending);

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

    fun get_or_generate_uri(obj_addr: address, registry: &VeTokenRegistry): String {
        let uri = if (string::is_empty(&registry.base_uri)) {
            string::utf8(b"https://daos.hoglet.xyz/api/nft/")
        } else {
            registry.base_uri
        };
        string::append(&mut uri, string_utils::to_string(&obj_addr));
        uri
    }

    fun update_svg_uri(obj_addr: address, ve_data: &VeToken) acquires VeTokenRefs, VeTokenRegistry {
        let refs = borrow_global<VeTokenRefs>(obj_addr);
        let registry = borrow_global<VeTokenRegistry>(ve_data.dao_address);
        let new_uri = get_or_generate_uri(obj_addr, registry);
        token::set_uri(&refs.mutator_ref, new_uri);
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
            compound_rebase_internal(owner, obj_addr, ve_data, registry);
        };
        (owner_addr, dao_address)
    }

    public entry fun compound(caller: &signer, legacy_addr: address) acquires VeToken, VeTokenRegistry, VeTokenRefs {
        let (owner_addr, _) = prepare_and_compound(caller, legacy_addr);
        let obj_addr = legacy_addr;
        let ve_data = borrow_global_mut<VeToken>(obj_addr);
        
        update_svg_uri(obj_addr, ve_data);
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

        let user_addr = signer::address_of(user);
        // FIX (audit10 M3): a blacklisted account must not accumulate
        // voting power.
        assert_not_blacklisted(dao_address, user_addr);

        let registry = borrow_global_mut<VeTokenRegistry>(dao_address);
        let current_epoch = pilgrim::now();
        let end_epoch = current_epoch + lock_epochs;

        let user_store = primary_fungible_store::primary_store(user_addr, registry.token_metadata);


        // 1. Create the NFT Object
        let (creator_signer, obj_signer, obj_addr, constructor_ref) = create_ve_nft_object(registry);
        let mutator_ref = token::generate_mutator_ref(&constructor_ref);
        
        // Ensure adding to total before generating SVG to correctly calculate the Share %
        registry.total_locked = registry.total_locked + amount;
        update_total_locked_history(dao_address, registry.total_locked);
        
        let dynamic_uri = get_or_generate_uri(obj_addr, registry);
        token::set_uri(&mutator_ref, dynamic_uri);

        // Deposit into the Object's store.
        let store_constructor = fungible_asset::create_store(&constructor_ref, registry.token_metadata);
        transfer_tax_free(dao_address, user, user_store, store_constructor, amount);

        let snapshots = smart_vector::new<Snapshot>();
        smart_vector::push_back(&mut snapshots, scan::new_snapshot(current_epoch, amount, end_epoch));

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
        let voting_power = math::mul_div_u64(amount, lock_epochs, MAX_LOCK_EPOCHS);

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
        update_svg_uri(obj_addr, ve_data);

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
        // FIX (audit10 M3): no voting-power accumulation for blacklisted
        // accounts (see create_lock).
        assert_not_blacklisted(ve_data.dao_address, owner_addr);
        let registry = borrow_global_mut<VeTokenRegistry>(ve_data.dao_address);
        let current_epoch = pilgrim::now();
        
        assert!(ve_data.end_epoch > current_epoch, error::invalid_state(E_LOCK_EXPIRED));

        let user_store = primary_fungible_store::primary_store(owner_addr, ve_data.token_metadata);
        let store = object::address_to_object<FungibleStore>(obj_addr);
        transfer_tax_free(ve_data.dao_address, owner, user_store, store, additional_amount);

        let new_total = ve_data.locked_amount + additional_amount;
        ve_data.locked_amount = new_total;
        registry.total_locked = registry.total_locked + additional_amount;
        update_total_locked_history(ve_data.dao_address, registry.total_locked);

        ve_data.rebase_debt = math::calculate_rebase_debt(new_total, registry.acc_rebase_per_share);

        // Checkpoint for rewards (Must be called AFTER updating amount)
        harvest::checkpoint(ve_data.dao_address, obj_addr, new_total);

        upsert_snapshot(ve_data);

        // Update SVG to reflect the new amount
        update_svg_uri(obj_addr, ve_data);

        event::emit(AmountIncreased { owner: owner_addr, legacy: obj_addr, added_amount: additional_amount, new_total });
    }

    // Shared VeToken destruction used by `withdraw` and `merge`: removes the
    // VeToken and VeTokenRefs resources, destroys snapshots, drains the FA
    // store and deletes the object. Returns (locked_amount, end_epoch,
    // delegate, delegator, withdrawn_fa).
    fun burn_ve_token_and_withdraw(obj_addr: address): (u64, u64, Option<address>, address, FungibleAsset) acquires VeToken, VeTokenRefs {
        let VeToken { dao_address, locked_amount, end_epoch, snapshots, rebase_debt: _, token_metadata: _, delegate, delegator, last_voted_epoch: _ } =
            move_from<VeToken>(obj_addr);

        scan::destroy_all(snapshots);

        let VeTokenRefs { extend_ref, delete_ref, mutator_ref: _ } =
            move_from<VeTokenRefs>(obj_addr);

        let store = object::address_to_object<FungibleStore>(obj_addr);

        // FIX (audit10 C3): with a TaxFreeRouter the cap path bypasses the
        // dispatch hooks; plain-FA DAOs sign with the ve object itself, which
        // owns its store (the extend_ref was moved_from above and remains
        // valid until object::delete below).
        let fa = if (dao_factory::tax_router::has_tax_free_router(dao_address)) {
            dao_factory::tax_router::withdraw_tax_free(dao_address, store, locked_amount)
        } else {
            let obj_signer = object::generate_signer_for_extending(&extend_ref);
            fungible_asset::withdraw(&obj_signer, store, locked_amount)
        };

        fungible_asset::remove_store(&delete_ref);
        object::delete(delete_ref);

        (locked_amount, end_epoch, delegate, delegator, fa)
    }

    public entry fun withdraw(
        owner: &signer,
        legacy_addr: address,
    ) acquires VeToken, VeTokenRefs, VeTokenRegistry, TotalLockedHistory {
        let (owner_addr, dao_address) = prepare_and_compound(owner, legacy_addr);
        let obj_addr = legacy_addr;
        let current_epoch = pilgrim::now();
        assert!(current_epoch >= borrow_global<VeToken>(legacy_addr).end_epoch, error::invalid_state(E_STILL_LOCKED));

        let (locked_amount, _, _, _, fa) = burn_ve_token_and_withdraw(obj_addr);

        let registry = borrow_global_mut<VeTokenRegistry>(dao_address);
        registry.total_locked = registry.total_locked - locked_amount;
        update_total_locked_history(dao_address, registry.total_locked);

        let user_store = primary_fungible_store::ensure_primary_store_exists(owner_addr, registry.token_metadata);
        dao_factory::tax_router::deposit_tax_free(dao_address, user_store, fa);

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

        // 1. Burn `from_legacy` and drain its FA (shared with withdraw)
        let (from_amount, from_end_epoch, old_delegate, old_delegator, fa) =
            burn_ve_token_and_withdraw(from_legacy_addr);

        if (option::is_some(&old_delegate)) {
            emit_delegate_changed(from_legacy_addr, old_delegator, old_delegate, option::none());
        };

        // 2. Deposit FA into the `into_legacy` store
        let into_store = object::address_to_object<FungibleStore>(into_legacy_addr);
        dao_factory::tax_router::deposit_tax_free(dao_address, into_store, fa);

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
        update_svg_uri(into_legacy_addr, borrow_global<VeToken>(into_legacy_addr));

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

        emit_delegate_changed(obj_addr, owner_addr, old_delegate, option::some(delegate_addr));

        // Update SVG to reflect DELEGATED status
        update_svg_uri(obj_addr, ve_data);
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

        emit_delegate_changed(obj_addr, owner_addr, old_delegate, option::none());

        // Update SVG to reflect SELF_VOTING status
        update_svg_uri(obj_addr, ve_data);
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
        scan::voting_power_at(&ve_data.snapshots, ve_data.locked_amount, ve_data.end_epoch, query_epoch, MAX_LOCK_EPOCHS)
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
        scan::total_locked_at(&history.snapshots, query_epoch)
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

    /// Address that granted the current delegation (the owner at creation or
    /// delegation time). Used by zeal to enforce the blacklist on
    /// delegation-based voting (audit10 M3).
    #[view]
    public fun get_delegator(ve_token_obj: Object<VeToken>): address acquires VeToken {
        borrow_global<VeToken>(object::object_address(&ve_token_obj)).delegator
    }

    #[view]
    public fun get_dao_address(legacy: Object<VeToken>): address acquires VeToken {
        borrow_global<VeToken>(object::object_address(&legacy)).dao_address
    }

    /// Raw per-NFT summary for batch reads. Returns (false, 0, 0, false) when
    /// the address does not host a VeToken of `target_dao`; otherwise
    /// (true, locked_amount, end_epoch, is_delegated).
    /// NOTE: returns a flat tuple because this Move flavor forbids tuples as
    /// generic type arguments (no Option<(u64, u64, bool)>).
    /// Companion of dao_factory::legacy_views::get_batch_nft_metadata, which
    /// lives in the dao_views package to keep the core package small.
    #[view]
    public fun ve_info(nft_addr: address, target_dao: address): (bool, u64, u64, bool) acquires VeToken {
        if (!exists<VeToken>(nft_addr)) return (false, 0, 0, false);
        let ve_data = borrow_global<VeToken>(nft_addr);
        if (ve_data.dao_address != target_dao) return (false, 0, 0, false);

        let ve_obj = object::address_to_object<VeToken>(nft_addr);
        let is_delegated = if (object::owner(ve_obj) != ve_data.delegator) {
            false
        } else {
            option::is_some(&ve_data.delegate)
        };

        (true, ve_data.locked_amount, ve_data.end_epoch, is_delegated)
    }

    /// Max lock duration in epochs. Public so views outside the core package
    /// (dao_views) can replicate the voting-power formula exactly.
    #[view]
    public fun max_lock_epochs(): u64 {
        MAX_LOCK_EPOCHS
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
            // FIX (audit10 M3): blacklisted accounts must not extract
            // harvest rewards or rebase.
            assert_not_blacklisted(ve_data.dao_address, owner_addr);
            let registry = borrow_global_mut<VeTokenRegistry>(ve_data.dao_address);
            compound_rebase_internal(owner, obj_addr, ve_data, registry);
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

    fun emit_delegate_changed(legacy: address, owner: address, old_delegate: Option<address>, new_delegate: Option<address>) {
        event::emit(DelegateChanged { legacy, owner, old_delegate, new_delegate });
    }

    /// FIX (audit10 C3): routes internal DAO transfers. With a TaxFreeRouter
    /// (smart-token DAOs) the cap path bypasses the dispatch hooks; without
    /// one (plain-FA DAOs like HOG) the normal owner-signed flow is used 
    /// plain FA has no hooks, so the result is equivalent.
    /// `owner` must own `from_store` (only needed by the fallback branch).
    fun transfer_tax_free(dao_address: address, owner: &signer, from_store: Object<FungibleStore>, to_store: Object<FungibleStore>, amount: u64) {
        let fa = if (dao_factory::tax_router::has_tax_free_router(dao_address)) {
            dao_factory::tax_router::withdraw_tax_free(dao_address, from_store, amount)
        } else {
            fungible_asset::withdraw(owner, from_store, amount)
        };
        dao_factory::tax_router::deposit_tax_free(dao_address, to_store, fa);
    }

    /// FIX (audit10 M3): internal DAO flows bypass the token's dispatch hooks
    /// (TaxFreeCap), so the blacklist must be enforced explicitly. Shared
    /// guard for every flow that accumulates voting power or extracts value.
    public fun assert_not_blacklisted(dao_address: address, account: address) acquires VeTokenRegistry {
        assert!(
            !smart_token::is_blacklisted(get_token_metadata_address(dao_address), account),
            error::permission_denied(E_BLACKLISTED),
        );
    }

    // Extracted to save bytecode (~500 bytes saved by reusing strings and logic)
    fun create_ve_nft_object(registry: &mut VeTokenRegistry): (signer, signer, address, object::ConstructorRef) {
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
            std::option::none(),
            string::utf8(b""),
        );

        let obj_signer = object::generate_signer(&constructor_ref);
        let obj_addr = object::address_from_constructor_ref(&constructor_ref);
        (creator_signer, obj_signer, obj_addr, constructor_ref)
    }

    fun verify_owner_and_get_legacy(owner: &signer, legacy_addr: address): (address, Object<VeToken>) {
        let owner_addr = signer::address_of(owner);
        assert!(object::is_object(legacy_addr), error::invalid_argument(E_INVALID_OBJECT));
        let legacy = object::address_to_object<VeToken>(legacy_addr);
        assert!(object::is_owner(legacy, owner_addr), error::permission_denied(E_NOT_OWNER));
        (owner_addr, legacy)
    }
}
