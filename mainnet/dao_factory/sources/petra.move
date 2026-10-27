// Factory Module - The global orchestrator of the ecosystem
//
// Implements the Ouroboros pattern: the admin has a limited period (sunset)
// to transfer control to a DAO. After the deadline, they lose power
// automatically and irreversibly.
module dao_factory::petra {
    use std::string::{Self, String};
    use std::option;
    use std::bcs;
    use std::signer;
    use supra_framework::account;
    use supra_framework::fungible_asset::{Self, Metadata, MintRef};
    use supra_framework::object::{Self, Object};
    use supra_framework::event;
    use supra_framework::smart_table::{Self, SmartTable};
    use supra_framework::supra_coin::SupraCoin;
    use supra_framework::coin;
    use std::error;
    use supra_framework::timestamp;
    use std::vector;
    
    use dao_factory::charter;
    use dao_factory::ledger;
    use dao_factory::witness;
    use dao_factory::herald;
    use dao_factory::harvest;
    use dao_factory::legacy;
    use dao_factory::jubilee;
    use dao_factory::zeal;
    use dao_factory::restore;
    use dao_libs::pilgrim;
    use dao_factory::sentinel;
    use dao_boost::boost_registry;
    use dao_libs::math;
    use dao_libs::table;
    use dao_tax_router::tax_router;
    use dao_tokens::smart_token;

    // Errors 
    const E_NOT_ADMIN: u64 = 1;
    const E_INSUFFICIENT_FEE: u64 = 2;
    // (3, 4, 6 reserved: E_ADMIN_EXPIRED / E_ALREADY_RENOUNCED / E_NOT_OBJECT removed as dead code)
    const E_DAO_ALREADY_EXISTS: u64 = 5;
    const E_DECAY_TOO_HIGH: u64 = 7;
    const E_GAUGE_SPLIT_TOO_LOW: u64 = 8;
    const E_DECIMALS_TOO_HIGH: u64 = 9;
    const E_NO_SUPPLY_TRACKING: u64 = 10;
    const E_SUPPLY_ZERO: u64 = 11;
    const E_NAME_TOO_LONG: u64 = 12;
    const E_SYMBOL_TOO_LONG: u64 = 13;
    const E_UNAUTHORIZED_LAUNCHER: u64 = 14;
    const E_INVALID_RATIO: u64 = 15;
    const E_TOKEN_CLAIMED_BY_LAUNCHER: u64 = 15;
    const E_INVALID_ADDRESS: u64 = 16;
    const E_FEE_TOO_HIGH: u64 = 17;
    const E_INVALID_VOTING_DELAY: u64 = 18;
    const E_INVALID_VOTING_PERIOD: u64 = 19;
    const E_INVALID_THRESHOLD_PPM: u64 = 20;
    const E_INVALID_QUORUM: u64 = 21;
    const E_INVALID_TIMELOCK: u64 = 22;
    const E_INVALID_EMISSION_PPM: u64 = 23;
    const E_INVALID_EXTENSION: u64 = 24;
    const E_NOT_INFLATIONARY: u64 = 25;
    const E_INVALID_GRACE_PERIOD: u64 = 26;
    const E_INFLATIONARY_REQUIRES_SMART_TOKEN: u64 = 27;
    // (28, 29 reserved: E_DAO_ALREADY_ACTIVE / E_DAO_NOT_FOUND removed)
    const E_ALREADY_BLESSED: u64 = 30;
    const E_SMART_TOKEN_NOT_SUPPORTED_FOR_STATIC_DAO: u64 = 31;
    const E_INVALID_WRAPPER: u64 = 32;

    const DAO_ROUTER: address = @dao_router;
    const WRAPPER_SEED: vector<u8> = b"HOGLET_DAO_GOV_WRAPPER";

    // Constants 
    const MAX_CREATION_FEE: u64 = 1_370_000_000_000; // 13_700 SUPRA (8 decimals)
    // The admin MUST transfer to a DAO.

    // Global State (Anti-Spam and Admin) 
    
    struct FactoryConfig has key {
        creation_fee: u64,
        fee_receiver: address,
        admin_address: address,
        // Two-step admin transfer: the candidate must accept before taking over.
        // Prevents permanent loss of control from a typo in transfer_admin.
        pending_admin_address: address,
        curator_address: address,

        // Default DAO Parameters
        default_voting_delay: u64,
        default_voting_period: u64,
        default_proposal_threshold_ppm: u64,
        default_quorum_numerator: u64,
        default_quorum_denominator: u64,
        default_super_quorum_threshold: u64,
        default_late_quorum_extension: u64,
        default_timelock_delay: u64,
        default_grace_period: u64,

        // Inflationary Defaults
        default_initial_emission_ppm: u64,
        default_decay_bps: u64,
        default_tail_emission_ppm: u64,
        default_gauge_split_bps: u64,

        // Platform Whitelist
        default_bribe_tokens: vector<address>,
    }

    struct DaoRegistry has key {
        registered_tokens: SmartTable<Object<Metadata>, address>,
    }



    struct LauncherRegistry has key {
        approved_launchers: SmartTable<address, bool>,
        claimed_tokens: SmartTable<Object<Metadata>, address>,
    }

    // Events 
    #[event]
    struct DaoCreated has drop, store {
        creator: address,
        dao_address: address,
        governance_token: address,
        name: String,
        is_inflationary: bool,
    }

    #[event]
    struct AdminTransferred has drop, store {
        old_admin: address,
        new_admin: address,
    }

    #[event]
    struct AdminRenounced has drop, store {
        admin: address,
        epoch: u64,
    }

    // Initialization 

    // Runs automatically when publishing the contract
    fun init_module(admin: &signer) {
        move_to(admin, FactoryConfig {
            creation_fee: 1_370_000_000, // 13.7 APT/SUPRA
            fee_receiver: @HOGL,
            admin_address: @dao_genesis,
            pending_admin_address: @0x0,
            curator_address: @HOGL,
            default_voting_delay: charter::min_delay_seconds(), // Using SSOT from charter
            default_voting_period: 604800, // 1 week is standard
            default_proposal_threshold_ppm: 137, // 137 PPM = 0.0137% of Supply
            default_quorum_numerator: 7, // 7% Quorum
            default_quorum_denominator: 100,
            default_super_quorum_threshold: 62, // 62% Super Quorum (Standard Qualified Majority)
            default_late_quorum_extension: 86400,
            default_timelock_delay: 86400,
            default_grace_period: 1209600, // 14 days
            default_initial_emission_ppm: 30000, // 3% of initial supply (Aerodrome 2% / Velodrome 3.75% band)
            default_decay_bps: 100, // 1%
            default_tail_emission_ppm: 3000, // 0.3%/week floor (~15%/yr) Velodrome standard tailEmissionRate=30bp
            default_gauge_split_bps: 8000, // 80% to gauges

            default_bribe_tokens: vector::empty<address>(),
        });

        move_to(admin, DaoRegistry {
            registered_tokens: smart_table::new(),
        });

        move_to(admin, LauncherRegistry {
            approved_launchers: smart_table::new(),
            claimed_tokens: smart_table::new(),
        });
    }

    // Internal Helpers 

    // Verifies that the caller is admin.
    fun assert_admin(admin: &signer) acquires FactoryConfig {
        let config = borrow_global<FactoryConfig>(@dao_factory);
        assert!(
            signer::address_of(admin) == config.admin_address, 
            error::permission_denied(E_NOT_ADMIN)
        );
    }

    fun charge_creation_fee(creator: &signer) acquires FactoryConfig {
        let config = borrow_global<FactoryConfig>(@dao_factory);
        if (config.creation_fee > 0) {
            let user_balance = coin::balance<SupraCoin>(signer::address_of(creator));
            assert!(user_balance >= config.creation_fee, error::invalid_state(E_INSUFFICIENT_FEE));
            coin::transfer<SupraCoin>(creator, config.fee_receiver, config.creation_fee);
        }
    }

    // Administrative Functions 
    // All verify sunset. After admin_sunset_epoch, NO ONE can execute them.

    // Initiates an admin transfer (typically to a DAO).
    // This is the correct way to complete the Ouroboros pattern.
    // SECURITY FIX (VULN-05): Two-step transfer. The candidate must call
    // accept_admin() to complete the handover, preventing permanent loss of
    // control if new_admin contains a typo.
    // SECURITY FIX (audit10 #6): calling with new_admin = @0x0 cancels an
    // unclaimed pending (disarmed state, same as init/renounce). Harmless by
    // design: a wrong pending can never take power, and the current admin
    // keeps full authority until the candidate actually accepts.
    public entry fun transfer_admin(admin: &signer, new_admin: address) acquires FactoryConfig {
        assert_admin(admin);
        let config = borrow_global_mut<FactoryConfig>(@dao_factory);
        config.pending_admin_address = new_admin;
    }

    // Completes the admin transfer. Only the pending candidate can call this.
    public entry fun accept_admin(candidate: &signer) acquires FactoryConfig {
        do_accept_admin(signer::address_of(candidate));
    }

    // SECURITY FIX: the pending admin may be an account whose signer only exists inside ledger,
    // making accept_admin unreachable for it via normal private key transaction.
    // This permissionless crank completes the handover when the pending admin is a DAO.
    public entry fun accept_admin_for_dao(dao_address: address) acquires FactoryConfig {
        let dao_signer = ledger::generate_signer(dao_address);
        do_accept_admin(signer::address_of(&dao_signer));
    }

    fun do_accept_admin(candidate_addr: address) acquires FactoryConfig {
        let config = borrow_global_mut<FactoryConfig>(@dao_factory);
        assert!(
            config.pending_admin_address != @0x0 && candidate_addr == config.pending_admin_address,
            error::permission_denied(E_NOT_ADMIN)
        );
        let old_admin = config.admin_address;
        config.admin_address = candidate_addr;
        config.pending_admin_address = @0x0;
        event::emit(AdminTransferred { old_admin, new_admin: candidate_addr });
    }

    public entry fun set_curator(admin: &signer, new_curator: address) acquires FactoryConfig {
        assert_admin(admin);
        let config = borrow_global_mut<FactoryConfig>(@dao_factory);
        config.curator_address = new_curator;
    }

    // Rescue function: If the curator assigned to an unblessed static DAO fails or is compromised,
    // the Factory Admin can reassign it before blessing. Once blessed, the DAO is sovereign
    // and reassign_curator aborts with E_ALREADY_BLESSED.
    public entry fun reassign_curator(admin: &signer, dao_address: address, new_curator: address) acquires FactoryConfig {
        assert_admin(admin);
        assert!(!charter::is_blessed(dao_address), error::invalid_state(E_ALREADY_BLESSED));
        charter::update_guardian_by_factory(dao_address, option::some(new_curator));
    }

    fun set_launcher_status(admin: &signer, launcher: address, status: bool) acquires FactoryConfig, LauncherRegistry {
        assert_admin(admin);
        let registry = borrow_global_mut<LauncherRegistry>(@dao_factory);
        smart_table::upsert(&mut registry.approved_launchers, launcher, status);
    }

    public entry fun approve_launcher(admin: &signer, launcher: address) acquires FactoryConfig, LauncherRegistry {
        set_launcher_status(admin, launcher, true);
    }

    public entry fun revoke_launcher(admin: &signer, launcher: address) acquires FactoryConfig, LauncherRegistry {
        set_launcher_status(admin, launcher, false);
    }

    public entry fun set_creation_fee(admin: &signer, new_fee: u64) acquires FactoryConfig {
        assert_admin(admin);
        assert!(new_fee <= MAX_CREATION_FEE, error::invalid_argument(E_FEE_TOO_HIGH));
        let config = borrow_global_mut<FactoryConfig>(@dao_factory);
        config.creation_fee = new_fee;
    }

    public entry fun set_fee_receiver(admin: &signer, new_receiver: address) acquires FactoryConfig {
        assert_admin(admin);
        let config = borrow_global_mut<FactoryConfig>(@dao_factory);
        config.fee_receiver = new_receiver;
    }

    public entry fun add_default_bribe_token(admin: &signer, token_addr: address) acquires FactoryConfig {
        assert_admin(admin);
        let config = borrow_global_mut<FactoryConfig>(@dao_factory);
        table::push_unique(&mut config.default_bribe_tokens, token_addr);
    }

    public entry fun remove_default_bribe_token(admin: &signer, token_addr: address) acquires FactoryConfig {
        assert_admin(admin);
        let config = borrow_global_mut<FactoryConfig>(@dao_factory);
        table::remove_if_present(&mut config.default_bribe_tokens, token_addr);
    }

    // SECURITY FIX (VULN-05): All default setters now enforce the same bounds
    // that charter::initialize asserts. Previously, an admin could set invalid
    // defaults (e.g. voting_period < 1 day, quorum_numerator > denominator)
    // causing every new DAO creation to abort, or producing governance
    // parameters outside safe limits.
    
        public entry fun set_default_config(admin: &signer, config_key: u8, value: u64) acquires FactoryConfig {
        assert_admin(admin);
        let config = borrow_global_mut<FactoryConfig>(@dao_factory);
        math::validate_factory_default(
            config_key,
            value,
            config.default_quorum_numerator,
            config.default_quorum_denominator,
            config.default_super_quorum_threshold
        );
        if (config_key == 0) config.default_super_quorum_threshold = value
        else if (config_key == 1) config.default_quorum_numerator = value
        else if (config_key == 2) config.default_quorum_denominator = value
        else if (config_key == 3) config.default_late_quorum_extension = value
        else if (config_key == 4) config.default_voting_delay = value
        else if (config_key == 5) config.default_voting_period = value
        else if (config_key == 6) config.default_proposal_threshold_ppm = value
        else if (config_key == 7) config.default_timelock_delay = value
        else if (config_key == 8) config.default_grace_period = value
        else if (config_key == 9) config.default_decay_bps = value
        else if (config_key == 10) {
            assert!(value <= config.default_initial_emission_ppm, error::invalid_argument(E_INVALID_RATIO));
            config.default_tail_emission_ppm = value;
        }
        else if (config_key == 11) config.default_gauge_split_bps = value
        else if (config_key == 12) {
            assert!(value >= config.default_tail_emission_ppm, error::invalid_argument(E_INVALID_RATIO));
            config.default_initial_emission_ppm = value;
        };
    }

    // The admin can renounce, burning the admin key.

    // This is irreversible - once renounced, no one is admin.
    public entry fun renounce_admin(admin: &signer) acquires FactoryConfig {
        assert_admin(admin);
        let config = borrow_global_mut<FactoryConfig>(@dao_factory);
        let old_admin = config.admin_address;
        config.admin_address = @0x0;
        config.pending_admin_address = @0x0; // Clear any pending transfer too
        event::emit(AdminRenounced { admin: old_admin, epoch: pilgrim::now() });
    }

    // Static DAO (For tokens with fixed supply) 

    fun assert_token_not_registered(governance_token: Object<Metadata>) acquires DaoRegistry {
        let registry = borrow_global<DaoRegistry>(@dao_factory);
        assert!(
            !smart_table::contains(&registry.registered_tokens, governance_token),
            error::already_exists(E_DAO_ALREADY_EXISTS)
        );
    }

    fun assert_token_not_claimed(governance_token: Object<Metadata>) acquires LauncherRegistry {
        let launcher_registry = borrow_global<LauncherRegistry>(@dao_factory);
        assert!(
            !smart_table::contains(&launcher_registry.claimed_tokens, governance_token),
            error::permission_denied(E_TOKEN_CLAIMED_BY_LAUNCHER)
        );
    }

    public entry fun create_dao_static(
        creator: &signer,
        governance_token: Object<Metadata>
    ) acquires FactoryConfig, DaoRegistry, LauncherRegistry {
        charge_creation_fee(creator);
        assert_token_not_claimed(governance_token);
        create_dao_internal(creator, governance_token, option::none(), @0x0, option::none(), vector::empty<address>(), false);
    }

    public entry fun create_dao_static_for_wrapper(
        creator: &signer,
        wrapped_token: Object<Metadata>,
        native_token: Object<Metadata>,
    ) acquires FactoryConfig, DaoRegistry, LauncherRegistry {
        let native_supply = verify_and_get_wrapper_supply(creator, wrapped_token, native_token);
        let dao_address = create_dao_internal(creator, wrapped_token, option::none(), @0x0, option::some(native_supply), vector::empty<address>(), false);

        // Register the native token as well so nobody can frontrun or duplicate this DAO
        let registry = borrow_global_mut<DaoRegistry>(@dao_factory);
        smart_table::add(&mut registry.registered_tokens, native_token, dao_address);
    }

    fun verify_launcher_and_charge_fee(_creator: &signer, launcher_signer: &signer, governance_token: Object<Metadata>): address acquires LauncherRegistry {
        let launcher_address = signer::address_of(launcher_signer);
        assert_launcher(launcher_address);
        let launcher_registry = borrow_global<LauncherRegistry>(@dao_factory);
        if (smart_table::contains(&launcher_registry.claimed_tokens, governance_token)) {
            let claiming_launcher = *smart_table::borrow(&launcher_registry.claimed_tokens, governance_token);
            assert!(claiming_launcher == launcher_address, error::permission_denied(E_UNAUTHORIZED_LAUNCHER));
        };
        // Exonerated: Whitelisted launchers do not pay creation fee
        launcher_address
    }

    fun verify_and_get_wrapper_supply(creator: &signer, wrapped_token: Object<Metadata>, native_token: Object<Metadata>): u128 acquires FactoryConfig, DaoRegistry, LauncherRegistry {
        charge_creation_fee(creator);
        assert_token_not_claimed(wrapped_token);
        assert_token_not_claimed(native_token);
        assert_token_not_registered(native_token);

        math::validate_wrapper_token(
            DAO_ROUTER,
            WRAPPER_SEED,
            object::object_address(&wrapped_token),
            object::object_address(&native_token),
            fungible_asset::supply(native_token),
            fungible_asset::supply(wrapped_token),
            fungible_asset::decimals(wrapped_token),
            fungible_asset::decimals(native_token),
            E_INVALID_WRAPPER,
            E_SUPPLY_ZERO,
            E_DECIMALS_TOO_HIGH
        )
    }

    fun assert_not_dispatchable(_creator: &signer, governance_token: Object<Metadata>) {
        assert!(
            !smart_token::is_initialized(object::object_address(&governance_token)),
            error::invalid_argument(E_SMART_TOKEN_NOT_SUPPORTED_FOR_STATIC_DAO)
        );
    }

    fun assert_launcher(launcher_address: address) acquires LauncherRegistry {
        let launcher_registry = borrow_global<LauncherRegistry>(@dao_factory);
        assert!(
            smart_table::contains(&launcher_registry.approved_launchers, launcher_address) && 
            *smart_table::borrow(&launcher_registry.approved_launchers, launcher_address),
            error::permission_denied(E_UNAUTHORIZED_LAUNCHER)
        );
    }

    fun assert_valid_dao(dao_address: address, governance_token: Object<Metadata>) acquires DaoRegistry {
        let registry = borrow_global<DaoRegistry>(@dao_factory);
        let registered_dao = *smart_table::borrow(&registry.registered_tokens, governance_token);
        assert!(registered_dao == dao_address, error::invalid_argument(E_UNAUTHORIZED_LAUNCHER));
    }

    public fun create_dao_static_from_launcher(
        creator: &signer,
        launcher_signer: &signer,
        governance_token: Object<Metadata>,
        expected_supply: u128
    ): address acquires FactoryConfig, DaoRegistry, LauncherRegistry {
        let launcher_address = verify_launcher_and_charge_fee(creator, launcher_signer, governance_token);
        let dao_address = create_dao_internal(
            creator, governance_token, option::none(), launcher_address, option::some(expected_supply), vector::empty<address>(), false
        );

        // SECURITY FIX (VULN-02): Static DAOs created through a launcher (e.g.
        // delayed meme DAOs via spike_fun::activate_delayed_dao) are born
        // INACTIVE because launcher_address != @0x0, but nothing in the
        // launcher flow ever calls petra::activate_dao for them afterwards
        // (migration only activates DAOs that already exist at that time).
        // That left governance permanently frozen. Since the launcher only
        // creates this DAO once its own activation conditions are already met
        // (HODL period finished / migration done), we activate it immediately.
        charter::set_active(launcher_signer, dao_address);
        dao_address
    }

    fun prepare_dao_creation(creator: &signer, governance_token: Object<Metadata>, expected_supply_opt: option::Option<u128>): (signer, account::SignerCapability, address, string::String, u128) {
        let governance_token_addr = object::object_address(&governance_token);
        let name = fungible_asset::name(governance_token);
        let symbol = fungible_asset::symbol(governance_token);
        let decimals = fungible_asset::decimals(governance_token);
        let supply_opt = fungible_asset::supply(governance_token);

        let current_supply = math::validate_token_metadata_and_supply(
            string::length(&name),
            string::length(&symbol),
            decimals,
            &supply_opt,
            &expected_supply_opt,
            E_NAME_TOO_LONG,
            E_SYMBOL_TOO_LONG,
            E_DECIMALS_TOO_HIGH,
            E_NO_SUPPLY_TRACKING,
            E_SUPPLY_ZERO
        );

        let seed = bcs::to_bytes(&governance_token_addr);
        let time_micros = timestamp::now_microseconds();
        vector::append(&mut seed, bcs::to_bytes(&time_micros));
        let (dao_signer, signer_cap) = account::create_resource_account(creator, seed);
        let dao_address = signer::address_of(&dao_signer);

        (dao_signer, signer_cap, dao_address, name, current_supply) // keep u128 to prevent truncation
    }

    // Inflationary DAO ve(3,3) (For Launcher tokens) 

    public fun create_dao_inflationary(
        creator: &signer,
        governance_token: Object<Metadata>,
        mint_ref: MintRef
    ): address acquires FactoryConfig, DaoRegistry, LauncherRegistry {
        assert_token_not_claimed(governance_token);
        charge_creation_fee(creator);
        create_dao_internal(creator, governance_token, option::some(mint_ref), @0x0, option::none(), vector::empty<address>(), true)
    }

    public fun claim_token_for_launcher(
        launcher_signer: &signer,
        governance_token: Object<Metadata>
    ) acquires LauncherRegistry {
        let launcher_address = signer::address_of(launcher_signer);
        assert_launcher(launcher_address);
        let launcher_registry = borrow_global_mut<LauncherRegistry>(@dao_factory);
        smart_table::add(&mut launcher_registry.claimed_tokens, governance_token, launcher_address);
    }

    public entry fun claim_token_by_admin(
        admin: &signer,
        launcher_address: address,
        governance_token: Object<Metadata>
    ) acquires FactoryConfig, LauncherRegistry {
        assert_admin(admin);
        assert_launcher(launcher_address);
        let launcher_registry = borrow_global_mut<LauncherRegistry>(@dao_factory);
        smart_table::upsert(&mut launcher_registry.claimed_tokens, governance_token, launcher_address);
    }

    public entry fun unclaim_token(
        admin: &signer,
        governance_token: Object<Metadata>
    ) acquires FactoryConfig, LauncherRegistry {
        assert_admin(admin);
        let launcher_registry = borrow_global_mut<LauncherRegistry>(@dao_factory);
        smart_table::remove(&mut launcher_registry.claimed_tokens, governance_token);
    }

    // Inflationary DAO (Called exclusively by an approved Launcher)
    public fun create_dao_inflationary_from_launcher(
        creator: &signer,
        launcher_signer: &signer,
        governance_token: Object<Metadata>,
        expected_supply: u128,
        amm_pool_addresses: vector<address>
    ): address acquires FactoryConfig, DaoRegistry, LauncherRegistry {
        let launcher_address = verify_launcher_and_charge_fee(creator, launcher_signer, governance_token);
        create_dao_internal(creator, governance_token, option::none(), launcher_address, option::some(expected_supply), amm_pool_addresses, true)
    }

    fun create_dao_internal(
        creator: &signer,
        governance_token: Object<Metadata>,
        mint_ref_opt: option::Option<MintRef>,
        launcher_address: address,
        expected_supply_opt: option::Option<u128>,
        amm_pool_addresses: vector<address>,
        is_inflationary: bool,
    ): address acquires FactoryConfig, DaoRegistry {
        assert_token_not_registered(governance_token);

        let config = borrow_global<FactoryConfig>(@dao_factory);

        if (is_inflationary) {
            if (launcher_address != @0x0) {
                assert!(
                    smart_token::is_initialized(object::object_address(&governance_token)),
                    error::invalid_argument(E_INFLATIONARY_REQUIRES_SMART_TOKEN)
                );
            };
        } else {
            assert_not_dispatchable(creator, governance_token);
        };

        let (dao_signer, signer_cap, dao_address, name, current_supply) = prepare_dao_creation(creator, governance_token, expected_supply_opt);

        initialize_core_modules(&dao_signer, signer_cap, name, config, current_supply, launcher_address, is_inflationary, governance_token);
        sentinel::initialize(&dao_signer);

        if (is_inflationary) {
            zeal::initialize(&dao_signer, dao_address, amm_pool_addresses);
            restore::initialize(&dao_signer, object::object_address(&governance_token), config.default_bribe_tokens);
            boost_registry::initialize(&dao_signer);
            if (option::is_some(&mint_ref_opt)) {
                let mint_ref = option::extract(&mut mint_ref_opt);
                init_jubilee_internal(&dao_signer, mint_ref, config, current_supply);
            };
        };

        let registry = borrow_global_mut<DaoRegistry>(@dao_factory);
        smart_table::add(&mut registry.registered_tokens, governance_token, dao_address);

        event::emit(DaoCreated { creator: signer::address_of(creator), dao_address, governance_token: object::object_address(&governance_token), name, is_inflationary });

        dao_address
    }

    // Function to activate the DAO (Can only be called by the configured launcher)
    public entry fun activate_dao(launcher_signer: &signer, dao_address: address) {
        charter::set_active(launcher_signer, dao_address);
        jubilee::sync_clock(dao_address);
    }


    // Activates ONLY the gauge of the pool that received seed liquidity at
    // migration time. Birth gauges start inactive (at deploy it is not yet
    // known which pool the migration will seed); the launcher calls this in
    // the same migration transaction that adds liquidity, so exactly one
    // gauge becomes votable. The empty pool's gauge stays inactive unable
    // to receive votes/emissions until governance activates it (anchor,
    // gauge action_type == 2) once its pool has organic liquidity.
    public entry fun activate_seeded_gauge(
        launcher_signer: &signer,
        dao_address: address,
        staking_token_addr: address,
    ) acquires LauncherRegistry {
        assert_launcher_of_dao(launcher_signer, dao_address);
        // Only inflationary DAOs (born with the zeal registry) have gauges.
        assert!(zeal::is_initialized(dao_address), error::invalid_state(E_NOT_INFLATIONARY));

        zeal::activate_gauge_by_staking_token(dao_address, staking_token_addr);
    }

    // Stores the TaxFreeCap produced by the launcher's migration flow into
    // the DAO's account so tax_router can route internal DAO transfers
    // tax-free (audit10 C1b/C2).
    //
    // FIX (audit13 R-1): `routers` registers the protocol objects (the
    // launchpad Pool) allowed to produce the signer-proof for tax-free
    // routes. Registered at creation, while the DAO resource signer is
    // available there is no post-registration signer path at all.
    //
    // SECURITY: double gate the caller must be an approved launcher AND
    // the launcher registered for THIS DAO (charter binds it at creation).
    // A TaxFreeCap can only be obtained from
    // smart_token::enable_tax_free_routing by the token's admin, so this
    // cannot be used to inject a foreign cap into a victim DAO.
    public fun store_tax_free_cap(
        launcher_signer: &signer,
        dao_address: address,
        cap: smart_token::TaxFreeCap,
        routers: vector<address>,
    ) acquires LauncherRegistry {
        assert_launcher_of_dao(launcher_signer, dao_address);
        // Requires the DAO's resource signer: tax_router::store_tax_free_cap
        // does move_to(dao_signer, ...).
        tax_router::store_tax_free_cap(&ledger::generate_signer(dao_address), cap, routers);
    }

    // FIX (audit13 R-2) Launched-after-migration registration: the launcher
    // whitelists a NEW bonding-curve Pool into an EARLIER DAO's TaxFreeRouter
    // (a later launch using that DAO's token as a QUOTE). Same identity
    // pattern as activate_dao: the caller must be the launcher bound to
    // THIS DAO at creation; the DAO master signer is produced internally.
    public fun add_tax_router(
        launcher_signer: &signer,
        dao_address: address,
        router_address: address,
    ) acquires LauncherRegistry {
        assert_launcher_of_dao(launcher_signer, dao_address);
        tax_router::add_router(&ledger::generate_signer(dao_address), router_address);
    }

    public fun update_static_dao_threshold(
        launcher_signer: &signer,
        dao_address: address,
        governance_token: Object<Metadata>
    ) acquires FactoryConfig, DaoRegistry, LauncherRegistry {
        assert_launcher_of_dao(launcher_signer, dao_address);
        assert_valid_dao(dao_address, governance_token);
        assert!(!charter::is_inflationary(dao_address), error::invalid_state(E_NOT_INFLATIONARY));
        assert!(!charter::is_blessed(dao_address), error::invalid_state(E_ALREADY_BLESSED));

        let config = borrow_global<FactoryConfig>(@dao_factory);
        recalculate_threshold(dao_address, governance_token, config.default_proposal_threshold_ppm);
    }

    public fun activate_dao_inflationary(
        launcher_signer: &signer,
        dao_address: address,
        governance_token: Object<Metadata>,
        mint_ref: MintRef
    ) acquires FactoryConfig, DaoRegistry, LauncherRegistry {

        // Only DAOs born inflationary (with the zeal gauge registry) may
        // receive the minter. Prevents turning a static DAO into a broken
        // "minter-only" DAO whose advance_epoch would always abort when
        // routing emissions to the (nonexistent) gauges.
        assert!(zeal::is_initialized(dao_address), error::invalid_state(E_NOT_INFLATIONARY));

        // SECURITY FIX (M6): Validate caller is approved launcher of this DAO
        assert_launcher_of_dao(launcher_signer, dao_address);

        // SECURITY FIX (M6): Validate the DAO actually belongs to the governance token
        assert_valid_dao(dao_address, governance_token);

        // SECURITY FIX (M6): Validate the MintRef belongs to the governance token
        // We guarantee this by minting 0 tokens and asserting its metadata
        let test_mint = fungible_asset::mint(&mint_ref, 0);
        let test_metadata = fungible_asset::asset_metadata(&test_mint);
        assert!(test_metadata == governance_token, error::invalid_argument(E_UNAUTHORIZED_LAUNCHER));
        fungible_asset::destroy_zero(test_mint);

        let config = borrow_global<FactoryConfig>(@dao_factory);
        let current_supply = recalculate_threshold(dao_address, governance_token, config.default_proposal_threshold_ppm);

        init_jubilee_internal(&ledger::generate_signer(dao_address), mint_ref, config, current_supply);

        charter::set_active(launcher_signer, dao_address);
    }

    // Views 

    #[view]
    public fun is_admin_active(): bool acquires FactoryConfig {
        let config = borrow_global<FactoryConfig>(@dao_factory);
        config.admin_address != @0x0
    }

    #[view]
    public fun get_creation_fee(): u64 acquires FactoryConfig {
        borrow_global<FactoryConfig>(@dao_factory).creation_fee
    }

    #[view]
    public fun get_curator(): address acquires FactoryConfig {
        borrow_global<FactoryConfig>(@dao_factory).curator_address
    }

    #[view]
    public fun get_dao_for_token(token: Object<Metadata>): option::Option<address> acquires DaoRegistry {
        let registry = borrow_global<DaoRegistry>(@dao_factory);
        if (smart_table::contains(&registry.registered_tokens, token)) {
            option::some(*smart_table::borrow(&registry.registered_tokens, token))
        } else {
            option::none()
        }
    }

    #[view]
    public fun get_dao_token_metadata(token_addr: address): (String, String, u8, String, String) {
        let token_metadata = object::address_to_object<Metadata>(token_addr);
        (
            fungible_asset::name(token_metadata),
            fungible_asset::symbol(token_metadata),
            fungible_asset::decimals(token_metadata),
            fungible_asset::icon_uri(token_metadata),
            fungible_asset::project_uri(token_metadata)
        )
    }
    // --- Deduplication Helpers ---

    fun initialize_core_modules(
        dao_signer: &signer,
        signer_cap: account::SignerCapability,
        name: String,
        config: &FactoryConfig,
        current_supply: u128,
        launcher_address: address,
        is_inflationary: bool,
        governance_token: Object<Metadata>
    ) {
        let dao_address = signer::address_of(dao_signer);
        let dynamic_threshold = math::compute_dynamic_threshold(current_supply, config.default_proposal_threshold_ppm);

        charter::initialize(
            dao_signer, name, config.default_voting_delay, config.default_voting_period, dynamic_threshold,
            config.default_quorum_numerator, config.default_quorum_denominator, config.default_super_quorum_threshold,
            config.default_late_quorum_extension, config.default_timelock_delay, config.default_grace_period, if (is_inflationary) { option::none() } else { option::some(config.curator_address) },
            launcher_address,
            is_inflationary
        );

        ledger::initialize(dao_signer, signer_cap);
        legacy::initialize_registry(dao_signer, governance_token, name);
        witness::initialize(dao_signer);
        herald::initialize(dao_signer);

        let constructor_ref = object::create_object(dao_address);
        // H-02 Defense: Disable ungated transfers on Harvest vault object to prevent theft via Type 5 proposals
        let transfer_ref = object::generate_transfer_ref(&constructor_ref);
        object::disable_ungated_transfer(&transfer_ref);
        harvest::initialize(dao_signer, governance_token, &constructor_ref);
    }



    // Shared by create_dao_inflationary_internal and activate_dao_inflationary.
    fun init_jubilee_internal(dao_signer: &signer, mint_ref: MintRef, config: &FactoryConfig, current_supply: u128) {
        jubilee::initialize(
            dao_signer,
            mint_ref,
            math::apply_ppm(current_supply, config.default_initial_emission_ppm),
            config.default_decay_bps,
            math::apply_ppm(current_supply, config.default_tail_emission_ppm),
            config.default_gauge_split_bps
        );
    }

    // Shared threshold recalculation from live supply (used by
    // update_static_dao_threshold and activate_dao_inflationary).
    fun recalculate_threshold(dao_address: address, governance_token: Object<Metadata>, threshold_ppm: u64): u128 {
        let supply_opt = fungible_asset::supply(governance_token);
        assert!(option::is_some(&supply_opt), error::invalid_argument(E_NO_SUPPLY_TRACKING));
        let current_supply = *option::borrow(&supply_opt);
        let dynamic_threshold = math::compute_dynamic_threshold(current_supply, threshold_ppm);
        let dao_signer = ledger::generate_signer(dao_address);
        charter::update_proposal_threshold_by_factory(&dao_signer, dynamic_threshold);
        current_supply
    }

    // SECURITY: the caller must be an approved launcher AND the launcher
    // registered for THIS DAO (charter binds it at creation).
    fun assert_launcher_of_dao(launcher_signer: &signer, dao_address: address) acquires LauncherRegistry {
        let launcher_addr = signer::address_of(launcher_signer);
        assert_launcher(launcher_addr);
        assert!(
            charter::get_launcher_address(dao_address) == launcher_addr,
            error::permission_denied(E_UNAUTHORIZED_LAUNCHER)
        );
    }
}
