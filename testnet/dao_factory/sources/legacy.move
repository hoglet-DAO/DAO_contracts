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
    use aptos_std::smart_table::{Self, SmartTable};
    use dao_libs::format;

    
    use aptos_token_objects::collection;
    use aptos_token_objects::token;

    use dao_libs::pilgrim;
    use dao_factory::sentinel;
    use dao_factory::harvest;
    use dao_factory::ledger;
    use dao_libs::math;
    use dao_libs::scan::{Self, RegistrySnapshot, Snapshot};
    use dao_tokens::smart_token;
    use dao_tax_router::tax_router;

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
        // FIX (audit9 H-2): ExtendRef of the rebase sub-object (owner of
        // rebase_store) so compound can prove store authority to tax_router.
        rebase_extend_ref: ExtendRef,
        // FIX (audit C-01): Dedicated protocol-controlled escrow store for all locked veTokens
        escrow_store: Object<FungibleStore>,
        escrow_extend_ref: ExtendRef,
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
        slope_changes: SmartTable<u64, u64>,
        last_epoch: u64,
        last_bias: u64,
        last_slope: u64,
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

    #[event]
    struct RebaseOrphanedSwept has drop, store {
        dao_address: address,
        legacy: address,
        amount: u64,
    }

    // Aesthetic Initialization 

    fun create_guarded_subobject(dao_signer: &signer): (object::ConstructorRef, ExtendRef) {
        let constructor_ref = object::create_object(signer::address_of(dao_signer));
        let transfer_ref = object::generate_transfer_ref(&constructor_ref);
        object::disable_ungated_transfer(&transfer_ref);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        (constructor_ref, extend_ref)
    }

    public(friend) fun initialize_registry(
        dao_signer: &signer,
        token_metadata: Object<Metadata>,
        dao_name: String,
    ) {
        let (rebase_c, rebase_extend_ref) = create_guarded_subobject(dao_signer);
        let rebase_store = fungible_asset::create_store(&rebase_c, token_metadata);

        let (escrow_c, escrow_extend_ref) = create_guarded_subobject(dao_signer);
        let escrow_store = fungible_asset::create_store(&escrow_c, token_metadata);
        
        let (creator_c, creator_extend_ref) = create_guarded_subobject(dao_signer);
        let creator_signer = object::generate_signer(&creator_c);

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
            // FIX (audit9 H-2): the rebase object is the owner of rebase_store;
            // keeping its ExtendRef lets compound prove authority to tax_router.
            rebase_extend_ref,
            escrow_store,
            escrow_extend_ref,
            creator_extend_ref,
            mint_count: 0,
            collection_name,
            token_symbol,
            base_uri: string::utf8(b""), // Immortal SVG by default
        });

        move_to(dao_signer, TotalLockedHistory {
            snapshots: smart_vector::new<RegistrySnapshot>(),
            slope_changes: smart_table::new<u64, u64>(),
            last_epoch: 0,
            last_bias: 0,
            last_slope: 0,
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
        let dest_store = if (registry.total_locked > 0 && amount > 0) {
            registry.acc_rebase_per_share = math::add_per_share(amount, registry.total_locked, registry.acc_rebase_per_share);
            registry.rebase_store
        } else {
            primary_fungible_store::ensure_primary_store_exists(dao_address, fungible_asset::asset_metadata(&rebase_fa))
        };
        tax_router::deposit_tax_free(dao_address, &ledger::generate_signer(dao_address), dest_store, rebase_fa);
    }

    public(friend) fun inject_rewards(
        dao_address: address, 
        reward: FungibleAsset
    ) acquires VeTokenRegistry {
        let registry = borrow_global<VeTokenRegistry>(dao_address);
        harvest::inject_rewards(dao_address, reward, registry.total_locked);
    }

    // Snapshot & ve-Supply Decay Helpers (delegated to dao_libs::scan)

    // Advances the global ve-supply decay to current_epoch
    fun checkpoint_supply_internal(history: &mut TotalLockedHistory, current_epoch: u64) {
        scan::checkpoint_supply(&mut history.last_epoch, &mut history.last_bias, &mut history.last_slope, &history.slope_changes, current_epoch);
    }

    // Records a brand-new lock into global ve-supply
    fun record_new_lock(history: &mut TotalLockedHistory, amount: u64, end_epoch: u64, current_epoch: u64) {
        scan::record_new_lock(&mut history.last_epoch, &mut history.last_bias, &mut history.last_slope, &mut history.slope_changes, amount, end_epoch, current_epoch, MAX_LOCK_EPOCHS);
    }

    // Updates global ve-supply when a lock's amount and/or duration changes
    fun record_lock_delta(
        history: &mut TotalLockedHistory,
        old_amount: u64,
        old_end: u64,
        new_amount: u64,
        new_end: u64,
        current_epoch: u64,
    ) {
        scan::record_lock_delta(&mut history.last_epoch, &mut history.last_bias, &mut history.last_slope, &mut history.slope_changes, old_amount, old_end, new_amount, new_end, current_epoch, MAX_LOCK_EPOCHS);
    }

    // Called when a lock is destroyed before its end_epoch (e.g. merge)
    fun record_remove_lock(history: &mut TotalLockedHistory, amount: u64, end_epoch: u64, current_epoch: u64) {
        scan::record_remove_lock(&mut history.last_epoch, &mut history.last_bias, &mut history.last_slope, &mut history.slope_changes, amount, end_epoch, current_epoch, MAX_LOCK_EPOCHS);
    }

    // Upserts the voting-power snapshot for the current epoch: updates the
    // last snapshot if it belongs to this epoch, otherwise appends a new one.
    // Shared by every balance/end_epoch-mutating flow (compound, extend,
    // increase, merge). Logic lives in dao_factory::scan (dao_libs).
    fun upsert_snapshot(ve_data: &mut VeToken) {
        scan::upsert_snapshot(&mut ve_data.snapshots, pilgrim::now(), ve_data.locked_amount, ve_data.end_epoch);
    }

    fun update_total_locked_history(dao_address: address, current_total: u64) acquires TotalLockedHistory {
        let current_epoch = pilgrim::now();
        let history = borrow_global_mut<TotalLockedHistory>(dao_address);
        checkpoint_supply_internal(history, current_epoch);
        scan::upsert_registry_snapshot(&mut history.snapshots, current_epoch, current_total, history.last_bias);
    }

    fun sweep_orphaned_rebase_internal(
        obj_addr: address,
        ve_data: &mut VeToken,
        registry: &mut VeTokenRegistry
    ) {
        let (orphaned, earned_u128) = math::compute_orphaned_rebase(
            ve_data.locked_amount, registry.acc_rebase_per_share, ve_data.rebase_debt, fungible_asset::balance(registry.rebase_store)
        );
        if (orphaned > 0) {
            let rebase_signer = object::generate_signer_for_extending(&registry.rebase_extend_ref);
            let treasury_store = primary_fungible_store::ensure_primary_store_exists(ve_data.dao_address, registry.token_metadata);
            transfer_tax_free(ve_data.dao_address, &rebase_signer, registry.rebase_store, treasury_store, orphaned);
            event::emit(RebaseOrphanedSwept { dao_address: ve_data.dao_address, legacy: obj_addr, amount: orphaned });
        };
        ve_data.rebase_debt = earned_u128;
    }

    fun apply_lock_amount_increase(
        ve_data: &mut VeToken,
        registry: &mut VeTokenRegistry,
        additional_amount: u64,
        current_epoch: u64
    ) acquires TotalLockedHistory {
        let old_amount = ve_data.locked_amount;
        let new_total = old_amount + additional_amount;
        ve_data.locked_amount = new_total;
        registry.total_locked = registry.total_locked + additional_amount;
        
        record_lock_delta(borrow_global_mut<TotalLockedHistory>(ve_data.dao_address), old_amount, ve_data.end_epoch, new_total, ve_data.end_epoch, current_epoch);
        update_total_locked_history(ve_data.dao_address, registry.total_locked);
        upsert_snapshot(ve_data);
    }

    fun compound_rebase_internal(
        owner: &signer,
        obj_addr: address,
        ve_data: &mut VeToken,
        registry: &mut VeTokenRegistry,
    ) acquires TotalLockedHistory {
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
            sweep_orphaned_rebase_internal(obj_addr, ve_data, registry);
        } else {
            let (pending, earned_u128) = math::compute_pending_rebase(
                ve_data.locked_amount, registry.acc_rebase_per_share, ve_data.rebase_debt, fungible_asset::balance(registry.rebase_store)
            );

            if (pending > 0) {
                let rebase_signer = object::generate_signer_for_extending(&registry.rebase_extend_ref);
                transfer_tax_free(ve_data.dao_address, &rebase_signer, registry.rebase_store, registry.escrow_store, pending);

                apply_lock_amount_increase(ve_data, registry, pending, current_epoch);

                event::emit(RebaseCompounded { legacy: obj_addr, amount: pending });
            };

            ve_data.rebase_debt = earned_u128;
        };

        // Checkpoint harvest rewards AFTER changing locked_amount
        harvest::checkpoint(ve_data.dao_address, obj_addr, ve_data.locked_amount);
    }

    // URI Generator (served by the API endpoint / configurable base_uri) 

    fun get_or_generate_uri(obj_addr: address, registry: &VeTokenRegistry): String {
        format::format_ve_nft_uri(registry.base_uri, obj_addr)
    }

    public(friend) fun update_base_uri(dao_signer: &signer, new_uri: String) acquires VeTokenRegistry {
        let dao_address = signer::address_of(dao_signer);
        let registry = borrow_global_mut<VeTokenRegistry>(dao_address);
        registry.base_uri = new_uri;
    }

    // Public Functions 

    // --- Helper to reduce Bytecode Bloat ---
    fun prepare_and_compound(owner: &signer, legacy_addr: address): (address, address) acquires VeToken, VeTokenRegistry, TotalLockedHistory {
        let (owner_addr, _) = verify_owner_and_get_legacy(owner, legacy_addr);
        let ve_data = borrow_global_mut<VeToken>(legacy_addr);
        let dao_address = ve_data.dao_address;
        let registry = borrow_global_mut<VeTokenRegistry>(dao_address);
        compound_rebase_internal(owner, legacy_addr, ve_data, registry);
        (owner_addr, dao_address)
    }

    public entry fun compound(caller: &signer, legacy_addr: address) acquires VeToken, VeTokenRegistry, TotalLockedHistory {
        // FIX (audit10 #12): compound extracts harvest rewards + rebase, so
        // it must enforce the blacklist exactly like claim_rewards
        // (withdraw/merge stay unguarded on purpose: exiting users recover
        // their principal + accrued).
        let (owner_addr, dao_address) = prepare_and_compound(caller, legacy_addr);
        assert_not_blacklisted(dao_address, owner_addr);
        
    }

    // Sweeps orphaned rebase from an expired lock into the DAO treasury.
    // Permissionless keeper function: anyone can call this for any expired veToken to recover trapped rewards (M-05).
    public entry fun sweep_expired_rebase(legacy_addr: address) acquires VeToken, VeTokenRegistry {
        assert!(object::is_object(legacy_addr), error::invalid_argument(E_INVALID_OBJECT));
        let ve_data = borrow_global_mut<VeToken>(legacy_addr);
        let current_epoch = pilgrim::now();
        assert!(ve_data.end_epoch <= current_epoch, error::invalid_state(E_STILL_LOCKED));

        let registry = borrow_global_mut<VeTokenRegistry>(ve_data.dao_address);
        sweep_orphaned_rebase_internal(legacy_addr, ve_data, registry);
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
        
        // Ensure adding to total before generating SVG to correctly calculate the Share %
        registry.total_locked = registry.total_locked + amount;
        record_new_lock(borrow_global_mut<TotalLockedHistory>(dao_address), amount, end_epoch, current_epoch);
        update_total_locked_history(dao_address, registry.total_locked);

        // FIX (audit C-01): Deposit into the DAO's central escrow_store instead of creating
        // a store directly on the user-owned veNFT object.
        transfer_tax_free(dao_address, user, user_store, registry.escrow_store, amount);

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

        let mutator_ref = token::generate_mutator_ref(&constructor_ref);
        let dynamic_uri = get_or_generate_uri(obj_addr, registry);
        token::set_uri(&mutator_ref, dynamic_uri);

        move_to(&obj_signer, VeTokenRefs {
            extend_ref: object::generate_extend_ref(&constructor_ref),
            delete_ref: object::generate_delete_ref(&constructor_ref),
            mutator_ref,
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
    ) acquires VeToken, VeTokenRegistry, TotalLockedHistory {
        assert!(additional_epochs >= 1, error::invalid_argument(E_INVALID_EXTEND));
        // FIX (audit10 #12): extend extracts pending rewards (via compound)
        // before extending, so it enforces the blacklist like claim_rewards.
        let (owner_addr, dao_address) = prepare_and_compound(owner, legacy_addr);
        assert_not_blacklisted(dao_address, owner_addr);
        sentinel::assert_not_paused(dao_address);

        let ve_data = borrow_global_mut<VeToken>(legacy_addr);
        let current_epoch = pilgrim::now();
        let old_end_epoch = ve_data.end_epoch;
        let new_end_epoch = math::calculate_extend_lock_epoch(
            old_end_epoch, current_epoch, additional_epochs, MIN_LOCK_EPOCHS, MAX_LOCK_EPOCHS, E_LOCK_TOO_SHORT, E_LOCK_TOO_LONG
        );
        ve_data.end_epoch = new_end_epoch;

        record_lock_delta(borrow_global_mut<TotalLockedHistory>(dao_address), ve_data.locked_amount, old_end_epoch, ve_data.locked_amount, new_end_epoch, current_epoch);
        update_total_locked_history(dao_address, borrow_global<VeTokenRegistry>(dao_address).total_locked);

        upsert_snapshot(ve_data);

        // Update SVG to reflect the new lock time

        event::emit(LockExtended { owner: owner_addr, legacy: legacy_addr, old_end_epoch, new_end_epoch });
    }

    public entry fun increase_amount(
        owner: &signer,
        legacy_addr: address,
        additional_amount: u64,
    ) acquires VeToken, VeTokenRegistry, TotalLockedHistory {
        assert!(additional_amount > 0, error::invalid_argument(E_ZERO_AMOUNT));
        let (owner_addr, dao_address) = prepare_and_compound(owner, legacy_addr);
        sentinel::assert_not_paused(dao_address);

        let ve_data = borrow_global_mut<VeToken>(legacy_addr);
        // FIX (audit10 M3): no voting-power accumulation for blacklisted
        // accounts (see create_lock).
        assert_not_blacklisted(ve_data.dao_address, owner_addr);
        let registry = borrow_global_mut<VeTokenRegistry>(ve_data.dao_address);
        let current_epoch = pilgrim::now();
        
        assert!(ve_data.end_epoch > current_epoch, error::invalid_state(E_LOCK_EXPIRED));

        let user_store = primary_fungible_store::primary_store(owner_addr, ve_data.token_metadata);
        // FIX (audit C-01): Deposit into central escrow_store
        transfer_tax_free(ve_data.dao_address, owner, user_store, registry.escrow_store, additional_amount);

        apply_lock_amount_increase(ve_data, registry, additional_amount, current_epoch);

        ve_data.rebase_debt = math::calculate_rebase_debt(ve_data.locked_amount, registry.acc_rebase_per_share);

        // Checkpoint for rewards (Must be called AFTER updating amount)
        harvest::checkpoint(ve_data.dao_address, legacy_addr, ve_data.locked_amount);

        // Update SVG to reflect the new amount

        let new_total = ve_data.locked_amount;
        event::emit(AmountIncreased { owner: owner_addr, legacy: legacy_addr, added_amount: additional_amount, new_total });
    }

    // Shared VeToken destruction used by `withdraw` and `merge`: removes the
    // VeToken and VeTokenRefs resources, destroys snapshots, and deletes the
    // NFT object. Returns (locked_amount, end_epoch, delegate, delegator).
    // FIX (audit C-01 & H-01): No per-NFT FungibleStore is created or removed,
    // avoiding both C-01 direct user withdrawal and H-01 dust-deposit lockups.
    fun burn_ve_token(obj_addr: address): (u64, u64, Option<address>, address) acquires VeToken, VeTokenRefs {
        let VeToken { dao_address: _, locked_amount, end_epoch, snapshots, rebase_debt: _, token_metadata: _, delegate, delegator, last_voted_epoch: _ } =
            move_from<VeToken>(obj_addr);

        scan::destroy_all(snapshots);

        let VeTokenRefs { extend_ref: _, delete_ref, mutator_ref: _ } =
            move_from<VeTokenRefs>(obj_addr);

        object::delete(delete_ref);

        (locked_amount, end_epoch, delegate, delegator)
    }

    public entry fun withdraw(
        owner: &signer,
        legacy_addr: address,
    ) acquires VeToken, VeTokenRefs, VeTokenRegistry, TotalLockedHistory {
        let (owner_addr, dao_address) = prepare_and_compound(owner, legacy_addr);
        assert!(pilgrim::now() >= borrow_global<VeToken>(legacy_addr).end_epoch, error::invalid_state(E_STILL_LOCKED));

        let (locked_amount, _, _, _) = burn_ve_token(legacy_addr);

        let registry = borrow_global_mut<VeTokenRegistry>(dao_address);
        registry.total_locked = registry.total_locked - locked_amount;
        update_total_locked_history(dao_address, registry.total_locked);

        let escrow_signer = object::generate_signer_for_extending(&registry.escrow_extend_ref);
        let dao_signer = ledger::generate_signer(dao_address);
        let fa = if (tax_router::has_tax_free_router(dao_address)) {
            tax_router::withdraw_tax_free(dao_address, &dao_signer, registry.escrow_store, locked_amount)
        } else {
            dispatchable_fungible_asset::withdraw(&escrow_signer, registry.escrow_store, locked_amount)
        };

        let user_store = primary_fungible_store::ensure_primary_store_exists(owner_addr, registry.token_metadata);
        tax_router::deposit_tax_free(dao_address, &dao_signer, user_store, fa);

        // Checkpoint for rewards (0 because everything was withdrawn)
        harvest::checkpoint(dao_address, legacy_addr, 0);

        event::emit(Withdrawn { owner: owner_addr, legacy: legacy_addr, amount: locked_amount });
    }

    public entry fun merge(
        owner: &signer,
        from_legacy_addr: address,
        into_legacy_addr: address,
    ) acquires VeToken, VeTokenRefs, VeTokenRegistry, TotalLockedHistory {
        assert!(from_legacy_addr != into_legacy_addr, error::invalid_argument(E_INVALID_OBJECT));
        
        let (owner_addr, dao_address) = prepare_and_compound(owner, from_legacy_addr);
        assert_not_blacklisted(dao_address, owner_addr);
        let (_, _) = prepare_and_compound(owner, into_legacy_addr);

        // Ensure they belong to the same DAO & other preconditions
        {
            let from_ve_data = borrow_global<VeToken>(from_legacy_addr);
            let into_ve_data = borrow_global<VeToken>(into_legacy_addr);
            math::validate_merge_preconditions(
                from_ve_data.dao_address,
                into_ve_data.dao_address,
                from_ve_data.end_epoch,
                from_ve_data.last_voted_epoch,
                into_ve_data.last_voted_epoch,
                pilgrim::now(),
                E_INVALID_OBJECT,
                E_LOCK_EXPIRED,
                E_VOTED_RECENTLY
            );
        };

        // Sentinel: merge is pausable
        sentinel::assert_not_paused(dao_address);

        // 1. Burn `from_legacy` (resources removed and NFT deleted)
        let (from_amount, from_end_epoch, old_delegate, old_delegator) =
            burn_ve_token(from_legacy_addr);

        if (option::is_some(&old_delegate)) {
            emit_delegate_changed(from_legacy_addr, old_delegator, old_delegate, option::none());
        };

        // 2. Both balances are already securely held in registry.escrow_store.
        // No asset transfer between stores is needed.

        // 3. Update `into_legacy` metadata
        let new_total: u64;
        let new_end_epoch: u64;

        {
            let into_ve_data = borrow_global_mut<VeToken>(into_legacy_addr);
            let old_into_amount = into_ve_data.locked_amount;
            let old_into_end = into_ve_data.end_epoch;
            
            new_total = old_into_amount + from_amount;
            into_ve_data.locked_amount = new_total;
            
            let current_epoch = pilgrim::now();
            new_end_epoch = math::calculate_merge_lock_epoch(from_end_epoch, old_into_end, current_epoch, MAX_LOCK_EPOCHS);
            into_ve_data.end_epoch = new_end_epoch;

            let history = borrow_global_mut<TotalLockedHistory>(dao_address);
            record_remove_lock(history, from_amount, from_end_epoch, current_epoch);
            record_lock_delta(history, old_into_amount, old_into_end, new_total, new_end_epoch, current_epoch);

            // Update rebase debt to prevent rebase drain exploit
            let registry = borrow_global_mut<VeTokenRegistry>(dao_address);
            update_total_locked_history(dao_address, registry.total_locked);
            into_ve_data.rebase_debt = math::calculate_rebase_debt(new_total, registry.acc_rebase_per_share);

            // Correctly update snapshots
            upsert_snapshot(into_ve_data);
        };

        // Checkpoints
        harvest::checkpoint(dao_address, from_legacy_addr, 0);
        harvest::checkpoint(dao_address, into_legacy_addr, new_total);

        // Update SVG

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
    ) acquires VeToken, VeTokenRegistry {
        let (owner_addr, _) = verify_owner_and_get_legacy(owner, legacy_addr);
        assert!(delegate_addr != owner_addr, error::invalid_argument(E_SELF_DELEGATE));

        let obj_addr = legacy_addr;
        let ve_data = borrow_global_mut<VeToken>(obj_addr);
        // FIX (audit9 M-2): a blacklisted account must not exercise governance
        // rights, including re-routing its existing voting power via
        // delegation. The delegate must not be blacklisted either (defense in
        // depth; vote-time guards would also catch it).
        assert_not_blacklisted(ve_data.dao_address, owner_addr);
        assert_not_blacklisted(ve_data.dao_address, delegate_addr);
        
        let old_delegate = ve_data.delegate;
        ve_data.delegate = option::some(delegate_addr);
        ve_data.delegator = owner_addr;

        emit_delegate_changed(obj_addr, owner_addr, old_delegate, option::some(delegate_addr));

        // Update SVG to reflect DELEGATED status
    }

    // Revokes the vote delegation. The owner regains control of their voting power.
    public entry fun revoke_delegation(
        owner: &signer,
        legacy_addr: address,
    ) acquires VeToken {
        let (owner_addr, _) = verify_owner_and_get_legacy(owner, legacy_addr);

        let obj_addr = legacy_addr;
        let ve_data = borrow_global_mut<VeToken>(obj_addr);
        
        let old_delegate = ve_data.delegate;
        ve_data.delegate = option::none();
        ve_data.delegator = owner_addr;

        emit_delegate_changed(obj_addr, owner_addr, old_delegate, option::none());

        // Update SVG to reflect SELF_VOTING status
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
        if (epoch > ve_token.last_voted_epoch) {
            ve_token.last_voted_epoch = epoch;
        };
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
    public fun get_total_voting_power_at(dao_address: address, query_epoch: u64): u64 acquires TotalLockedHistory {
        if (!exists<TotalLockedHistory>(dao_address)) {
            return 0
        };

        let history = borrow_global<TotalLockedHistory>(dao_address);
        if (history.last_epoch == 0) {
            return 0
        };

        if (query_epoch <= history.last_epoch) {
            let power = scan::total_voting_power_at(&history.snapshots, query_epoch);
            if (power > 0) {
                return power
            } else if (query_epoch == history.last_epoch) {
                return history.last_bias
            };
        };

        scan::simulate_decay_power(
            history.last_epoch,
            history.last_bias,
            history.last_slope,
            &history.slope_changes,
            query_epoch,
        )
    }

    #[view]
    public fun get_total_voting_power(dao_address: address): u64 acquires TotalLockedHistory {
        get_total_voting_power_at(dao_address, pilgrim::now())
    }

    #[view]
    public fun get_rebase_store_address(dao_address: address): address acquires VeTokenRegistry {
        let registry = borrow_global<VeTokenRegistry>(dao_address);
        object::object_address(&registry.rebase_store)
    }

    #[view]
    public fun get_escrow_store_address(dao_address: address): address acquires VeTokenRegistry {
        let registry = borrow_global<VeTokenRegistry>(dao_address);
        object::object_address(&registry.escrow_store)
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

    // Address that granted the current delegation (the owner at creation or
    // delegation time). Used by zeal to enforce the blacklist on
    // delegation-based voting (audit10 M3).
    //
    // NOTE: this is the HISTORICAL owner, not the current holder. veNFTs are
    // transferable, so use `get_owner` for the live holder.
    #[view]
    public fun get_delegator(ve_token_obj: Object<VeToken>): address acquires VeToken {
        borrow_global<VeToken>(object::object_address(&ve_token_obj)).delegator
    }

    // Live owner of the veToken object (the current holder), by raw address.
    //
    // Exposed so packages that cannot name the private `VeToken` type (e.g.
    // `dao_views`) can still verify ownership without re-implementing the
    // transferable-object check. It reads the same `object::owner` source the
    // `verify_owner_and_get_legacy` write guard uses.
    #[view]
    public fun get_owner_by_address(ve_token_addr: address): address {
        if (!object::is_object(ve_token_addr)) return @0x0;
        object::owner(object::address_to_object<VeToken>(ve_token_addr))
    }

    #[view]
    public fun get_dao_address(legacy: Object<VeToken>): address acquires VeToken {
        borrow_global<VeToken>(object::object_address(&legacy)).dao_address
    }

    // Raw per-NFT summary for batch reads. Returns (false, 0, 0, false) when
    // the address does not host a VeToken of `target_dao`; otherwise
    // (true, locked_amount, end_epoch, is_delegated).
    // NOTE: returns a flat tuple because this Move flavor forbids tuples as
    // generic type arguments (no Option<(u64, u64, bool)>).
    // Companion of dao_factory::legacy_views::get_batch_nft_metadata, which
    // lives in the dao_views package to keep the core package small.
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

    // Max lock duration in epochs. Public so views outside the core package
    // (dao_views) can replicate the voting-power formula exactly.
    #[view]
    public fun max_lock_epochs(): u64 {
        MAX_LOCK_EPOCHS
    }

    // External Rewards (Harvest) 

    public entry fun claim_rewards(
        owner: &signer,
        legacy_addr: address,
    ) acquires VeToken, VeTokenRegistry, TotalLockedHistory {
        compound(owner, legacy_addr);
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

    // Pending rebase (protocol emission share) for a veToken. It is
    // COMPOUNDED into the lock by compound/claim_rewards never claimed
    // directly. Math lives in dao_libs::math to keep this view minimal.
    #[view]
    public fun pending_rebase(ve_addr: address): u64 acquires VeToken, VeTokenRegistry {
        let ve_data = borrow_global<VeToken>(ve_addr);
        let registry = borrow_global<VeTokenRegistry>(ve_data.dao_address);
        math::rebase_pending(ve_data.locked_amount, registry.acc_rebase_per_share, ve_data.rebase_debt)
    }

    // --- Helpers for Deduplication ---

    fun emit_delegate_changed(legacy: address, owner: address, old_delegate: Option<address>, new_delegate: Option<address>) {
        event::emit(DelegateChanged { legacy, owner, old_delegate, new_delegate });
    }

    // FIX (audit10 C3 + H-04): routes internal DAO transfers. With a TaxFreeRouter
    // (smart-token DAOs) the cap path bypasses the dispatch hooks; without
    // one (plain-FA DAOs like HOG) the normal owner-signed flow is used.
    // Internal protocol stores owned by the DAO use `withdraw_tax_free`;
    // external user stores (create_lock, increase_amount) use `withdraw_tax_free_by_owner`.
    fun transfer_tax_free(dao_address: address, owner: &signer, from_store: Object<FungibleStore>, to_store: Object<FungibleStore>, amount: u64) {
        let dao_signer = ledger::generate_signer(dao_address);
        if (tax_router::has_tax_free_router(dao_address)) {
            if (object::owner(from_store) == dao_address) {
                let fa = tax_router::withdraw_tax_free(dao_address, &dao_signer, from_store, amount);
                tax_router::deposit_tax_free(dao_address, &dao_signer, to_store, fa);
            } else {
                tax_router::transfer_tax_free_from_owner(dao_address, owner, from_store, to_store, amount);
            };
        } else {
            let fa = dispatchable_fungible_asset::withdraw(owner, from_store, amount);
            tax_router::deposit_tax_free(dao_address, &dao_signer, to_store, fa);
        };
    }

    // FIX (audit10 M3): internal DAO flows bypass the token's dispatch hooks
    // (TaxFreeCap), so the blacklist must be enforced explicitly. Shared
    // guard for every flow that accumulates voting power or extracts value.
    public fun assert_not_blacklisted(dao_address: address, account: address) acquires VeTokenRegistry {
        assert!(
            !smart_token::is_blacklisted(get_token_metadata_address(dao_address), account),
            error::permission_denied(E_BLACKLISTED),
        );
    }

    // Consolidated voter authorization: verifies the caller is the veToken
    // owner OR an authorized delegate, then enforces the blacklist on the
    // caller (always) and on the delegator (only for delegated votes).
    // FIX (audit10 M3 + audit10 #2): extracted from witness::cast_vote and
    // zeal::vote to deduplicate the security-critical pattern.
    public fun assert_authorized_voter(
        dao_address: address,
        voter_addr: address,
        ve_token_obj: Object<VeToken>,
    ) acquires VeToken, VeTokenRegistry {
        let is_owner = object::is_owner(ve_token_obj, voter_addr);
        let is_del = is_delegate(ve_token_obj, voter_addr);
        assert!(is_owner || is_del, error::permission_denied(E_NOT_OWNER));

        assert_not_blacklisted(dao_address, voter_addr);
        if (!is_owner) {
            assert_not_blacklisted(dao_address, get_delegator(ve_token_obj));
        };
    }

    // Extracted to save bytecode (~500 bytes saved by reusing strings and logic)
    fun create_ve_nft_object(registry: &mut VeTokenRegistry): (signer, signer, address, object::ConstructorRef) {
        registry.mint_count = registry.mint_count + 1;
        let token_name = format::format_ve_nft_name(registry.token_symbol, registry.mint_count);

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
