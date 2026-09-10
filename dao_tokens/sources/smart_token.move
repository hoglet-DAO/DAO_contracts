module dao_tokens::smart_token {
    use std::option::{Self};
    use std::string;
    use supra_framework::object::{Self, Object, ConstructorRef, object_address};
    use supra_framework::fungible_asset::{Self, FungibleAsset, Metadata, TransferRef};
    use supra_framework::primary_fungible_store;
    use supra_framework::dispatchable_fungible_asset;
    use supra_framework::function_info::{Self, FunctionInfo};
    use supra_framework::event;
    use std::vector;
    use std::error;

    // ========================================================================
    // ERRORS
    // ========================================================================
    const E_NOT_AUTHORIZED: u64 = 1;
    const E_BLACKLISTED: u64 = 2;
    const E_MAX_TX_EXCEEDED: u64 = 3;
    const E_MAX_WALLET_EXCEEDED: u64 = 4;
    const E_INVALID_FEE: u64 = 5;
    const E_INVALID_ADDRESS: u64 = 6;
    const E_MAX_LIST_SIZE_EXCEEDED: u64 = 7;

    const DEAD_ADDRESS: address = @0x000000000000000000000000000000000000000000000000000000000000dead;

    // ========================================================================
    // EVENTS
    // ========================================================================
    
    #[event]
    struct AdminChangedEvent has drop, store {
        token_addr: address,
        old_admin: address,
        new_admin: address,
    }

    #[event]
    struct TreasuryUpdatedEvent has drop, store {
        token_addr: address,
        old_treasury: address,
        new_treasury: address,
    }

    #[event]
    struct ParameterUpdatedEvent has drop, store {
        token_addr: address,
        param_type: u8,
        new_value: u64,
    }

    #[event]
    struct BlacklistUpdatedEvent has drop, store {
        token_addr: address,
        target_address: address,
        is_blacklisted: bool,
    }

    /// Capability Object retornado al Launcher.
    /// The Launcher should pass it to the DAO safely durante la migracion.
    struct SmartTokenCap has store, drop {
        token_addr: address,
    }

    /// Capability para enrutamiento libre de impuestos. 
    /// Almacenado de forma segura en el DAO Factory.
    struct TaxFreeCap has store {
        token_addr: address,
    }

    struct HookRefs has key {
        withdraw_func: FunctionInfo,
        deposit_func: FunctionInfo,
    }

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    struct TokenRefs has key {
        transfer_ref: option::Option<TransferRef>,
    }

    fun init_module(sender: &signer) {
        let withdraw_func = function_info::new_function_info(
            sender,
            string::utf8(b"smart_token"),
            string::utf8(b"withdraw_hook")
        );
        let deposit_func = function_info::new_function_info(
            sender,
            string::utf8(b"smart_token"),
            string::utf8(b"deposit_hook")
        );
        move_to(sender, HookRefs { withdraw_func, deposit_func });
    }

    // Centralized configuration for the Smart Token
    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    struct DaoTokenConfig has key {
        dao_admin_address: address, 
        treasury_address: address,

        // Toggles
        is_tax_active: bool,
        is_anti_whale_active: bool,
        is_blacklist_active: bool,
        is_reflections_active: bool,

        // Parameters
        buy_tax_bps: u64,
        sell_tax_bps: u64,
        auto_burn_bps: u64,
        max_tx_amount: u64,
        max_wallet_amount: u64,

        // Lista Negra
        blacklist: vector<address>,

        // Exenciones (Whitelist)
        exempt_addresses: vector<address>,
    }

    /// Initializes the Smart Token. Does not require 'friends', is natively protected by Move 
    /// since only the one who creates the token owns the `&ConstructorRef`.
    public fun initialize(constructor_ref: &ConstructorRef): SmartTokenCap acquires HookRefs {
        let token_addr = object::address_from_constructor_ref(constructor_ref);
        
        let config = DaoTokenConfig {
            dao_admin_address: @0x0,
            treasury_address: @0x0,
            is_tax_active: false,
            is_anti_whale_active: false,
            is_blacklist_active: false,
            is_reflections_active: false,
            buy_tax_bps: 0,
            sell_tax_bps: 0,
            auto_burn_bps: 0,
            max_tx_amount: 0,
            max_wallet_amount: 0,
            blacklist: vector::empty<address>(),
            exempt_addresses: vector::empty<address>(),
        };

        let token_signer = object::generate_signer(constructor_ref);
        move_to(&token_signer, config);
        move_to(&token_signer, TokenRefs { transfer_ref: option::none() });

        let hook_refs = borrow_global<HookRefs>(@dao_tokens);

        dispatchable_fungible_asset::register_dispatch_functions(
            constructor_ref,
            option::some(hook_refs.withdraw_func),
            option::some(hook_refs.deposit_func),
            option::none()
        );

        SmartTokenCap { token_addr }
    }

    // ========================================================================
    // HOOK IMPLEMENTATIONS
    // ========================================================================

    public fun withdraw_hook<T: key>(
        store: Object<T>,
        amount: u64,
        transfer_ref: &TransferRef,
    ): FungibleAsset acquires DaoTokenConfig {
        let metadata = fungible_asset::store_metadata(store);
        let token_addr = object_address(&metadata);
        let sender_address = object::owner(store);
        
        let fa_to_transfer = fungible_asset::withdraw_with_ref(transfer_ref, store, amount);

        if (exists<DaoTokenConfig>(token_addr)) {
            let config = borrow_global<DaoTokenConfig>(token_addr);
            
            // SECURITY FIX: Exemption bypasses blacklist, anti-whale AND taxes.
            let is_exempt = vector::contains(&config.exempt_addresses, &sender_address);
            if (!is_exempt) {
                if (config.is_blacklist_active) {
                    assert!(!vector::contains(&config.blacklist, &sender_address), error::permission_denied(E_BLACKLISTED));
                };

                if (config.is_anti_whale_active && config.max_tx_amount > 0) {
                    assert!(amount <= config.max_tx_amount, error::out_of_range(E_MAX_TX_EXCEEDED));
                };

                if (config.is_tax_active) {
                    let amount_u128 = (amount as u128);
                    let tax_amount = (((amount_u128 * (config.sell_tax_bps as u128)) / 10000) as u64);
                    let burn_amount = (((amount_u128 * (config.auto_burn_bps as u128)) / 10000) as u64);

                    if (tax_amount > 0 && config.treasury_address != @0x0) {
                        let tax_fa = fungible_asset::extract(&mut fa_to_transfer, tax_amount);
                        let treasury_store = primary_fungible_store::ensure_primary_store_exists(config.treasury_address, metadata);
                        fungible_asset::deposit_with_ref(transfer_ref, treasury_store, tax_fa);
                    };

                    if (burn_amount > 0) {
                        let burn_fa = fungible_asset::extract(&mut fa_to_transfer, burn_amount);
                        let dead_store = primary_fungible_store::ensure_primary_store_exists(DEAD_ADDRESS, metadata);
                        fungible_asset::deposit_with_ref(transfer_ref, dead_store, burn_fa);
                    };
                };
            };
        };
        
        fa_to_transfer
    }

    public fun deposit_hook<T: key>(
        store: Object<T>,
        fa: FungibleAsset,
        transfer_ref: &TransferRef,
    ) acquires DaoTokenConfig {
        let metadata = fungible_asset::store_metadata(store);
        let token_addr = object_address(&metadata);
        let receiver_address = object::owner(store);
        let amount = fungible_asset::amount(&fa);
        
        if (exists<DaoTokenConfig>(token_addr)) {
            let config = borrow_global<DaoTokenConfig>(token_addr);
            
            // SECURITY FIX: Exemption bypasses blacklist, anti-whale AND taxes.
            let is_exempt = vector::contains(&config.exempt_addresses, &receiver_address);
            if (!is_exempt) {
                if (config.is_blacklist_active) {
                    assert!(!vector::contains(&config.blacklist, &receiver_address), error::permission_denied(E_BLACKLISTED));
                };

                if (config.is_anti_whale_active && config.max_wallet_amount > 0) {
                    let current_balance = primary_fungible_store::balance(receiver_address, metadata);
                    assert!(current_balance + amount <= config.max_wallet_amount, error::out_of_range(E_MAX_WALLET_EXCEEDED));
                };

                if (config.is_tax_active && config.buy_tax_bps > 0) {
                    let amount_u128 = (amount as u128);
                    let tax_amount = (((amount_u128 * (config.buy_tax_bps as u128)) / 10000) as u64);

                    if (tax_amount > 0 && config.treasury_address != @0x0) {
                        let mut_fa = &mut fa;
                        let tax_fa = fungible_asset::extract(mut_fa, tax_amount);
                        let treasury_store = primary_fungible_store::ensure_primary_store_exists(config.treasury_address, metadata);
                        fungible_asset::deposit_with_ref(transfer_ref, treasury_store, tax_fa);
                    };
                };
            };
        };

        fungible_asset::deposit_with_ref(transfer_ref, store, fa)
    }

    // ========================================================================
    // DAO ADMIN FUNCTIONS
    // ========================================================================

    /// Consume the Capability to set the DAO Admin permanently.
    /// This destroys the Cap, transferring the absolute power to the `new_admin`.
    public fun set_dao_admin(cap: SmartTokenCap, new_admin: address) acquires DaoTokenConfig {
        assert!(new_admin != @0x0, error::invalid_argument(E_INVALID_ADDRESS));
        let SmartTokenCap { token_addr } = cap; // Destruimos el Cap
        let config = borrow_global_mut<DaoTokenConfig>(token_addr);
        
        let old_admin = config.dao_admin_address;
        config.dao_admin_address = new_admin;
        config.treasury_address = new_admin;

        event::emit(AdminChangedEvent {
            token_addr,
            old_admin,
            new_admin,
        });
    }

    public fun update_treasury_address(
        token_addr: address,
        caller: &signer,
        treasury_address: address
    ) acquires DaoTokenConfig {
        let config = borrow_global_mut<DaoTokenConfig>(token_addr);
        assert!(std::signer::address_of(caller) == config.dao_admin_address, error::permission_denied(E_NOT_AUTHORIZED));
        
        let old_treasury = config.treasury_address;
        config.treasury_address = treasury_address;

        event::emit(TreasuryUpdatedEvent {
            token_addr,
            old_treasury,
            new_treasury: treasury_address,
        });
    }

    /// DAO Admin function to add or remove an address from the tax/anti-whale exempt list
    public fun set_exemption(
        token_addr: address,
        caller: &signer,
        target_address: address,
        is_exempt: bool
    ) acquires DaoTokenConfig {
        let config = borrow_global_mut<DaoTokenConfig>(token_addr);
        assert!(std::signer::address_of(caller) == config.dao_admin_address, error::permission_denied(E_NOT_AUTHORIZED));
        
        let (contains, index) = vector::index_of(&config.exempt_addresses, &target_address);
        if (is_exempt && !contains) {
            // SECURITY FIX (L-02): Cap vector size to prevent gas exhaustion
            assert!(vector::length(&config.exempt_addresses) < 100, error::out_of_range(E_MAX_LIST_SIZE_EXCEEDED));
            vector::push_back(&mut config.exempt_addresses, target_address);
        } else if (!is_exempt && contains) {
            vector::remove(&mut config.exempt_addresses, index);
        };
    }

    #[view]
    public fun is_initialized(token_addr: address): bool {
        exists<DaoTokenConfig>(token_addr)
    }

    /// FIX (audit10 M3): read-only blacklist check for trusted modules.
    /// The DAO's internal flows (locks, claims, votes) bypass the dispatch
    /// hooks via the TaxFreeCap, so dao_factory must enforce the blacklist
    /// explicitly. Returns false for tokens without a DaoTokenConfig (plain
    /// FungibleAssets like HOG have no blacklist feature).
    #[view]
    public fun is_blacklisted(token_addr: address, account: address): bool acquires DaoTokenConfig {
        if (!exists<DaoTokenConfig>(token_addr)) return false;
        let config = borrow_global<DaoTokenConfig>(token_addr);
        config.is_blacklist_active && vector::contains(&config.blacklist, &account)
    }

    /// Transfers the admin role of the token to a new address (e.g. the DAO)
    public fun transfer_admin(
        token_addr: address,
        caller: &signer,
        new_admin: address
    ) acquires DaoTokenConfig {
        assert!(new_admin != @0x0, error::invalid_argument(E_INVALID_ADDRESS));
        let config = borrow_global_mut<DaoTokenConfig>(token_addr);
        assert!(std::signer::address_of(caller) == config.dao_admin_address, error::permission_denied(E_NOT_AUTHORIZED));
        
        let old_admin = config.dao_admin_address;
        config.dao_admin_address = new_admin;

        event::emit(AdminChangedEvent {
            token_addr,
            old_admin,
            new_admin
        });
    }

    public fun update_single_param(
        token_addr: address,
        caller: &signer,
        param_type: u8,
        value: u64
    ) acquires DaoTokenConfig {
        let config = borrow_global_mut<DaoTokenConfig>(token_addr);
        assert!(std::signer::address_of(caller) == config.dao_admin_address, error::permission_denied(E_NOT_AUTHORIZED));
        
        if (param_type == 0) { // toggle tax
            config.is_tax_active = value > 0;
        } else if (param_type == 1) { // toggle anti_whale
            config.is_anti_whale_active = value > 0;
        } else if (param_type == 2) { // toggle blacklist
            config.is_blacklist_active = value > 0;
        } else if (param_type == 3) { // buy_tax_bps
            assert!(value <= 1000, error::invalid_argument(E_INVALID_FEE));
            config.buy_tax_bps = value;
        } else if (param_type == 4) { // sell_tax_bps
            assert!(value <= 1000, error::invalid_argument(E_INVALID_FEE));
            config.sell_tax_bps = value;
        } else if (param_type == 5) { // auto_burn_bps
            assert!(value <= 1000, error::invalid_argument(E_INVALID_FEE));
            config.auto_burn_bps = value;
        } else if (param_type == 6) { // max_tx_amount
            let metadata = supra_framework::object::address_to_object<Metadata>(token_addr);
            let supply_opt = supra_framework::fungible_asset::supply(metadata);
            if (std::option::is_some(&supply_opt)) {
                let total_supply = (std::option::extract(&mut supply_opt) as u64);
                let min_tx_limit = (total_supply * 5) / 1000; // Minimum 0.5% of supply
                assert!(value >= min_tx_limit || value == 0, error::out_of_range(E_MAX_TX_EXCEEDED));
            };
            config.max_tx_amount = value;
        } else if (param_type == 7) { // max_wallet_amount
            let metadata = supra_framework::object::address_to_object<Metadata>(token_addr);
            let supply_opt = supra_framework::fungible_asset::supply(metadata);
            if (std::option::is_some(&supply_opt)) {
                let total_supply = (std::option::extract(&mut supply_opt) as u64);
                let min_wallet_limit = (total_supply * 10) / 1000; // Minimum 1% of supply
                assert!(value >= min_wallet_limit || value == 0, error::out_of_range(E_MAX_WALLET_EXCEEDED));
            };
            config.max_wallet_amount = value;
        } else {
            abort error::invalid_argument(E_INVALID_FEE)
        };

        // SECURITY FIX (M-05): Check combined tax cap (max 15% combined tax impact)
        assert!(config.buy_tax_bps + config.sell_tax_bps + config.auto_burn_bps <= 1500, error::invalid_argument(E_INVALID_FEE));

        event::emit(ParameterUpdatedEvent {
            token_addr,
            param_type,
            new_value: value,
        });
    }

    public fun update_blacklist(
        token_addr: address,
        caller: &signer,
        target: address,
        add_to_blacklist: bool
    ) acquires DaoTokenConfig {
        let config = borrow_global_mut<DaoTokenConfig>(token_addr);
        assert!(std::signer::address_of(caller) == config.dao_admin_address, error::permission_denied(E_NOT_AUTHORIZED));
        let (found, index) = vector::index_of(&config.blacklist, &target);
        if (add_to_blacklist && !found) {
            // SECURITY FIX (L-02): Cap vector size to prevent gas exhaustion
            assert!(vector::length(&config.blacklist) < 100, error::out_of_range(E_MAX_LIST_SIZE_EXCEEDED));
            vector::push_back(&mut config.blacklist, target);
        } else if (!add_to_blacklist && found) {
            vector::remove(&mut config.blacklist, index);
        };

        event::emit(BlacklistUpdatedEvent {
            token_addr,
            target_address: target,
            is_blacklisted: add_to_blacklist,
        });
    }

    // ========================================================================
    // TAX FREE ROUTING (OPTION A)
    // ========================================================================

    /// Permits the DAO Factory to enable tax-free routing by permanently locking the TransferRef
    /// inside this module, yielding a TaxFreeCap in return.
    public fun enable_tax_free_routing(
        admin: &signer,
        token_addr: address,
        transfer_ref: TransferRef
    ): TaxFreeCap acquires DaoTokenConfig, TokenRefs {
        let config = borrow_global<DaoTokenConfig>(token_addr);
        assert!(config.dao_admin_address == std::signer::address_of(admin), error::permission_denied(E_NOT_AUTHORIZED));
        
        let refs = borrow_global_mut<TokenRefs>(token_addr);
        assert!(std::option::is_none(&refs.transfer_ref), error::invalid_state(100)); // already enabled
        refs.transfer_ref = std::option::some(transfer_ref);
        
        TaxFreeCap { token_addr }
    }

    /// Executes a tax-free withdraw using the secured TransferRef.
    /// Can only be called by a trusted DAO module holding the TaxFreeCap.
    public fun withdraw_tax_free(
        cap: &TaxFreeCap,
        store: Object<supra_framework::fungible_asset::FungibleStore>,
        amount: u64
    ): supra_framework::fungible_asset::FungibleAsset acquires TokenRefs {
        let refs = borrow_global<TokenRefs>(cap.token_addr);
        let transfer_ref = std::option::borrow(&refs.transfer_ref);
        
        fungible_asset::withdraw_with_ref(transfer_ref, store, amount)
    }

    /// Executes a tax-free deposit using the secured TransferRef.
    /// Can only be called by a trusted DAO module holding the TaxFreeCap.
    public fun deposit_tax_free(
        cap: &TaxFreeCap,
        store: Object<supra_framework::fungible_asset::FungibleStore>,
        fa: supra_framework::fungible_asset::FungibleAsset
    ) acquires TokenRefs {
        let refs = borrow_global<TokenRefs>(cap.token_addr);
        let transfer_ref = std::option::borrow(&refs.transfer_ref);
        
        fungible_asset::deposit_with_ref(transfer_ref, store, fa);
    }

    // ========================================================================
    // TESTS (Proving the Capability Architecture)
    // ========================================================================

    #[test_only]
    use supra_framework::account;

    #[test(framework = @supra_framework, deployer = @dao_tokens, dao = @0xDA0, hacker = @0xBAD)]
    public fun test_capability_flow(
        framework: &signer,
        deployer: &signer,
        dao: &signer,
        hacker: &signer
    ) acquires HookRefs, DaoTokenConfig {
        // Setup environment
        let deployer_addr = std::signer::address_of(deployer);
        account::create_account_for_test(deployer_addr);
        init_module(deployer);

        // Create a fake token
        let token_constructor_ref = object::create_named_object(deployer, b"TEST_TOKEN");
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &token_constructor_ref,
            std::option::none(),
            string::utf8(b"Test"),
            string::utf8(b"TST"),
            8,
            string::utf8(b"icon"),
            string::utf8(b"project")
        );
        let token_addr = object::address_from_constructor_ref(&token_constructor_ref);

        // 1. LAUNCHER PHASE: Initialize and get the Cap
        let cap = initialize(&token_constructor_ref);
        
        // Verify default admin is 0x0
        let config = borrow_global<DaoTokenConfig>(token_addr);
        assert!(config.dao_admin_address == @0x0, 100);

        // 2. MIGRATION PHASE: Transfer absolute power to the DAO
        let dao_addr = std::signer::address_of(dao);
        set_dao_admin(cap, dao_addr);

        // Verify admin is now DAO
        let config_after = borrow_global<DaoTokenConfig>(token_addr);
        assert!(config_after.dao_admin_address == dao_addr, 101);

        // 3. GOVERNANCE PHASE: DAO updates a parameter (Toggle Tax = true)
        update_single_param(token_addr, dao, 0, 1);
        
        let config_final = borrow_global<DaoTokenConfig>(token_addr);
        assert!(config_final.is_tax_active == true, 102);
    }

    #[test(deployer = @dao_tokens, hacker = @0xBAD)]
    #[expected_failure(abort_code = E_NOT_AUTHORIZED)]
    public fun test_hacker_fails(deployer: &signer, hacker: &signer) acquires HookRefs, DaoTokenConfig {
        let deployer_addr = std::signer::address_of(deployer);
        account::create_account_for_test(deployer_addr);
        init_module(deployer);

        let token_constructor_ref = object::create_named_object(deployer, b"TEST_TOKEN");
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &token_constructor_ref,
            std::option::none(),
            string::utf8(b"Test"),
            string::utf8(b"TST"),
            8,
            string::utf8(b"icon"),
            string::utf8(b"project")
        );
        let token_addr = object::address_from_constructor_ref(&token_constructor_ref);
        let cap = initialize(&token_constructor_ref);
        
        // Transfer to legitimate DAO
        set_dao_admin(cap, @0xDA0);

        // Hacker tries to change buy tax
        update_single_param(token_addr, hacker, 3, 500); // Should abort!
    }
}
