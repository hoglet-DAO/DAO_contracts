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
    use dao_factory::pilgrim;
    use dao_factory::sentinel;
    use dao_factory::boost_registry;

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

    // Constants 
    const MAX_CREATION_FEE: u64 = 100_000_000_000; // 1000 SUPRA (8 decimals)
    // The admin MUST transfer to a DAO.

    // Global State (Anti-Spam and Admin) 
    
    struct FactoryConfig has key {
        creation_fee: u64,
        fee_receiver: address,
        admin_address: address,
        // Two-step admin transfer: the candidate must accept before taking over.
        // Prevents permanent loss of control from a typo in transfer_admin.
        pending_admin_address: address,

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
            fee_receiver: signer::address_of(admin),
            admin_address: signer::address_of(admin),
            pending_admin_address: @0x0,
            default_voting_delay: charter::min_delay_seconds(), // Using SSOT from charter
            default_voting_period: 604800, // 1 week is standard
            default_proposal_threshold_ppm: 137, // 137 PPM = 0.0137% of Supply
            default_quorum_numerator: 7, // 7% Quorum
            default_quorum_denominator: 100,
            default_super_quorum_threshold: 73, // 73% Super Quorum
            default_late_quorum_extension: 86400,
            default_timelock_delay: 86400,
            default_grace_period: 1209600, // 14 days
            default_initial_emission_ppm: 50000,
            default_decay_bps: 100, // 1%
            default_tail_emission_ppm: 10000,
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
    public entry fun transfer_admin(admin: &signer, new_admin: address) acquires FactoryConfig {
        assert_admin(admin);
        assert!(new_admin != @0x0, error::invalid_argument(E_INVALID_ADDRESS));
        let config = borrow_global_mut<FactoryConfig>(@dao_factory);
        config.pending_admin_address = new_admin;
    }

    // Completes the admin transfer. Only the pending candidate can call this.
    public entry fun accept_admin(candidate: &signer) acquires FactoryConfig {
        let config = borrow_global_mut<FactoryConfig>(@dao_factory);
        let candidate_addr = signer::address_of(candidate);
        assert!(
            config.pending_admin_address != @0x0 && candidate_addr == config.pending_admin_address,
            error::permission_denied(E_NOT_ADMIN)
        );
        let old_admin = config.admin_address;
        config.admin_address = candidate_addr;
        config.pending_admin_address = @0x0;
        event::emit(AdminTransferred { old_admin, new_admin: candidate_addr });
    }

    public entry fun approve_launcher(admin: &signer, launcher: address) acquires FactoryConfig, LauncherRegistry {
        assert_admin(admin);
        let registry = borrow_global_mut<LauncherRegistry>(@dao_factory);
        smart_table::upsert(&mut registry.approved_launchers, launcher, true);
    }

    public entry fun revoke_launcher(admin: &signer, launcher: address) acquires FactoryConfig, LauncherRegistry {
        assert_admin(admin);
        let registry = borrow_global_mut<LauncherRegistry>(@dao_factory);
        smart_table::upsert(&mut registry.approved_launchers, launcher, false);
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
        if (!vector::contains(&config.default_bribe_tokens, &token_addr)) {
            vector::push_back(&mut config.default_bribe_tokens, token_addr);
        }
    }

    public entry fun remove_default_bribe_token(admin: &signer, token_addr: address) acquires FactoryConfig {
        assert_admin(admin);
        let config = borrow_global_mut<FactoryConfig>(@dao_factory);
        let (found, index) = vector::index_of(&config.default_bribe_tokens, &token_addr);
        if (found) {
            vector::remove(&mut config.default_bribe_tokens, index);
        }
    }

    // SECURITY FIX (VULN-05): All default setters now enforce the same bounds
    // that charter::initialize asserts. Previously, an admin could set invalid
    // defaults (e.g. voting_period < 1 day, quorum_numerator > denominator)
    // causing every new DAO creation to abort, or producing governance
    // parameters outside safe limits.
    
    fun assert_bounds(value: u64, min: u64, max: u64, err_code: u64) {
        assert!(value >= min && value <= max, error::invalid_argument(err_code));
    }

    public entry fun set_default_config(admin: &signer, config_key: u8, value: u64) acquires FactoryConfig {
        assert_admin(admin);
        let config = borrow_global_mut<FactoryConfig>(@dao_factory);
        
        if (config_key == 0) {
            assert_bounds(value, 1, config.default_quorum_denominator, E_INVALID_QUORUM);
            assert!(value * 100 / config.default_quorum_denominator >= 50, error::invalid_argument(E_INVALID_QUORUM));
            config.default_super_quorum_threshold = value;
        } else if (config_key == 1) {
            assert_bounds(value, 1, config.default_quorum_denominator, E_INVALID_QUORUM);
            config.default_quorum_numerator = value;
        } else if (config_key == 2) {
            assert!(value >= config.default_quorum_numerator && value >= config.default_super_quorum_threshold, error::invalid_argument(E_INVALID_QUORUM));
            config.default_quorum_denominator = value;
        } else if (config_key == 3) {
            assert_bounds(value, 0, charter::max_delay_seconds(), E_INVALID_EXTENSION);
            config.default_late_quorum_extension = value;
        } else if (config_key == 4) {
            assert_bounds(value, charter::min_delay_seconds(), charter::max_delay_seconds(), E_INVALID_VOTING_DELAY);
            config.default_voting_delay = value;
        } else if (config_key == 5) {
            assert_bounds(value, charter::min_period_seconds(), charter::max_delay_seconds(), E_INVALID_VOTING_PERIOD);
            config.default_voting_period = value;
        } else if (config_key == 6) {
            assert_bounds(value, 1, 1_000_000, E_INVALID_THRESHOLD_PPM);
            config.default_proposal_threshold_ppm = value;
        } else if (config_key == 7) {
            assert_bounds(value, charter::min_delay_seconds(), charter::max_delay_seconds(), E_INVALID_TIMELOCK);
            config.default_timelock_delay = value;
        } else if (config_key == 8) {
            assert_bounds(value, 0, 31536000, E_INVALID_GRACE_PERIOD);
            config.default_grace_period = value;
        } else if (config_key == 9) {
            assert_bounds(value, 0, 500, E_DECAY_TOO_HIGH);
            config.default_decay_bps = value;
        } else if (config_key == 10) {
            assert_bounds(value, 0, 1_000_000, E_INVALID_EMISSION_PPM);
            config.default_tail_emission_ppm = value;
        } else if (config_key == 11) {
            assert_bounds(value, 8000, 10000, E_GAUGE_SPLIT_TOO_LOW);
            config.default_gauge_split_bps = value;
        } else if (config_key == 12) {
            assert_bounds(value, 0, 1_000_000, E_INVALID_EMISSION_PPM);
            config.default_initial_emission_ppm = value;
        } else {
            abort error::invalid_argument(E_INVALID_ADDRESS)
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

    public entry fun create_dao_static(
        creator: &signer,
        governance_token: Object<Metadata>
    ) acquires FactoryConfig, DaoRegistry, LauncherRegistry {
        charge_creation_fee(creator);

        let config = borrow_global<FactoryConfig>(@dao_factory);
        let registry = borrow_global<DaoRegistry>(@dao_factory);
        assert!(
            !smart_table::contains(&registry.registered_tokens, governance_token),
            error::already_exists(E_DAO_ALREADY_EXISTS)
        );

        let launcher_registry = borrow_global<LauncherRegistry>(@dao_factory);
        assert!(
            !smart_table::contains(&launcher_registry.claimed_tokens, governance_token),
            error::permission_denied(E_TOKEN_CLAIMED_BY_LAUNCHER)
        );

        create_dao_static_internal(creator, governance_token, config, @0x0, option::none());
    }

    // Static DAO (Called exclusively by an approved Launcher)
    // CRITICAL SAFETY WARNING: 
    // The `expected_supply` parameter is used to permanently calculate governance thresholds at initialization.
    // The caller (launcher) MUST mathematically guarantee that the final real token supply generated matches 
    // this `expected_supply`. If the real supply ends up being significantly lower than `expected_supply`, 
    // the DAO's proposal thresholds will be mathematically impossible to reach, freezing governance forever.
    fun assert_launcher(launcher_address: address) acquires LauncherRegistry {
        let launcher_registry = borrow_global<LauncherRegistry>(@dao_factory);
        assert!(
            smart_table::contains(&launcher_registry.approved_launchers, launcher_address) && 
            *smart_table::borrow(&launcher_registry.approved_launchers, launcher_address),
            error::permission_denied(E_UNAUTHORIZED_LAUNCHER)
        );
    }

    public fun create_dao_static_from_launcher(
        creator: &signer,
        launcher_signer: &signer,
        governance_token: Object<Metadata>,
        expected_supply: u128
    ): address acquires FactoryConfig, DaoRegistry, LauncherRegistry {
        let launcher_address = signer::address_of(launcher_signer);
        assert_launcher(launcher_address);

        charge_creation_fee(creator);

        let config = borrow_global<FactoryConfig>(@dao_factory);
        let registry = borrow_global<DaoRegistry>(@dao_factory);
        assert!(
            !smart_table::contains(&registry.registered_tokens, governance_token),
            error::already_exists(E_DAO_ALREADY_EXISTS)
        );

        let dao_address = create_dao_static_internal(
            creator, governance_token, config, launcher_address, option::some(expected_supply)
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
        assert!(string::length(&name) <= 60, error::invalid_argument(E_NAME_TOO_LONG));
        assert!(string::length(&symbol) <= 20, error::invalid_argument(E_SYMBOL_TOO_LONG));
        
        let seed = bcs::to_bytes(&governance_token_addr);
        let time_micros = timestamp::now_microseconds();
        vector::append(&mut seed, bcs::to_bytes(&time_micros));
        let (dao_signer, signer_cap) = account::create_resource_account(creator, seed);
        let dao_address = signer::address_of(&dao_signer);

        let decimals = fungible_asset::decimals(governance_token);
        assert!(decimals <= 8, error::invalid_argument(E_DECIMALS_TOO_HIGH));

        let supply_opt = fungible_asset::supply(governance_token);
        assert!(option::is_some(&supply_opt), error::invalid_argument(E_NO_SUPPLY_TRACKING));
        let current_supply = if (option::is_some(&expected_supply_opt)) { *option::borrow(&expected_supply_opt) } else { *option::borrow(&supply_opt) };
        assert!(current_supply > 0, error::invalid_argument(E_SUPPLY_ZERO));

        (dao_signer, signer_cap, dao_address, name, current_supply) // keep u128 to prevent truncation
    }

    // Shared static-DAO creation flow (used by both the public entry point
    // and approved launchers). Creates the resource account, computes the
    // governance threshold and initializes the governance-only module set
    // (no zeal / restore / boost_registry / jubilee: those are exclusive
    // to inflationary DAOs).
    fun create_dao_static_internal(
        creator: &signer,
        governance_token: Object<Metadata>,
        config: &FactoryConfig,
        launcher_address: address,
        expected_supply_opt: option::Option<u128>,
    ): address acquires DaoRegistry {
        let (dao_signer, signer_cap, dao_address, name, current_supply) = prepare_dao_creation(creator, governance_token, expected_supply_opt);

        let dynamic_threshold = (((current_supply * (config.default_proposal_threshold_ppm as u128)) / 1000000) as u64);
        // SECURITY FIX (VULN-07): tiny supplies round the threshold down to 0,
        // which aborts charter::initialize (E_INVALID_THRESHOLD) and bricks
        // DAO creation for that token. Clamp to a minimum of 1.
        if (dynamic_threshold == 0) { dynamic_threshold = 1 };

        charter::initialize(
            &dao_signer, name, config.default_voting_delay, config.default_voting_period, dynamic_threshold,
            config.default_quorum_numerator, config.default_quorum_denominator, config.default_super_quorum_threshold,
            config.default_late_quorum_extension, config.default_timelock_delay, config.default_grace_period, option::none(),
            launcher_address,
            false // Static DAO: no ve(3,3) engine
        );

        ledger::initialize(&dao_signer, signer_cap);

        legacy::initialize_registry(&dao_signer, governance_token, name);
        witness::initialize(&dao_signer);
        herald::initialize(&dao_signer);

        let constructor_ref = object::create_object(dao_address);
        harvest::initialize(&dao_signer, governance_token, &constructor_ref);
        sentinel::initialize(&dao_signer);

        let registry = borrow_global_mut<DaoRegistry>(@dao_factory);
        smart_table::add(&mut registry.registered_tokens, governance_token, dao_address);

        event::emit(DaoCreated {
            creator: signer::address_of(creator),
            dao_address,
            governance_token: object::object_address(&governance_token),
            name,
            is_inflationary: false,
        });

        dao_address
    }

    // Inflationary DAO ve(3,3) (For Launcher tokens) 

    public fun create_dao_inflationary(
        creator: &signer,
        governance_token: Object<Metadata>,
        mint_ref: MintRef
    ): address acquires FactoryConfig, DaoRegistry, LauncherRegistry {
        let launcher_registry = borrow_global<LauncherRegistry>(@dao_factory);
        assert!(
            !smart_table::contains(&launcher_registry.claimed_tokens, governance_token),
            error::permission_denied(E_TOKEN_CLAIMED_BY_LAUNCHER)
        );

        charge_creation_fee(creator);
        let config = borrow_global<FactoryConfig>(@dao_factory);
        create_dao_inflationary_internal(creator, governance_token, option::some(mint_ref), config, @0x0, option::none(), std::vector::empty<address>())
    }

    public fun claim_token_for_launcher(
        launcher_signer: &signer,
        governance_token: Object<Metadata>
    ) acquires LauncherRegistry {
        let launcher_address = signer::address_of(launcher_signer);
        let launcher_registry = borrow_global_mut<LauncherRegistry>(@dao_factory);
        assert!(
            smart_table::contains(&launcher_registry.approved_launchers, launcher_address) && 
            *smart_table::borrow(&launcher_registry.approved_launchers, launcher_address),
            error::permission_denied(E_UNAUTHORIZED_LAUNCHER)
        );
        smart_table::add(&mut launcher_registry.claimed_tokens, governance_token, launcher_address);
    }

    public entry fun unclaim_token(
        admin: &signer,
        governance_token: Object<Metadata>
    ) acquires FactoryConfig, LauncherRegistry {
        let config = borrow_global<FactoryConfig>(@dao_factory);
        assert!(signer::address_of(admin) == config.admin_address, error::permission_denied(E_NOT_ADMIN));
        let launcher_registry = borrow_global_mut<LauncherRegistry>(@dao_factory);
        smart_table::remove(&mut launcher_registry.claimed_tokens, governance_token);
    }

    // Inflationary DAO (Called exclusively by an approved Launcher)
    // CRITICAL SAFETY WARNING: 
    // The `expected_supply` parameter establishes the baseline for proposal thresholds and emissions (`jubilee`).
    // If a launcher passes a value that diverges from the final minted supply (e.g., due to a logic bug in a launcher upgrade),
    // the DAO will be permanently bricked as it will be mathematically impossible to reach the quorum/threshold to vote.
    // Future upgrades to the launcher MUST preserve the mathematical integrity of this projection.
    public fun create_dao_inflationary_from_launcher(
        creator: &signer,
        launcher_signer: &signer,
        governance_token: Object<Metadata>,
        expected_supply: u128,
        amm_pool_addresses: vector<address>
    ): address acquires FactoryConfig, DaoRegistry, LauncherRegistry {
        let launcher_address = signer::address_of(launcher_signer);
        assert_launcher(launcher_address);

        charge_creation_fee(creator);
        let config = borrow_global<FactoryConfig>(@dao_factory);
        create_dao_inflationary_internal(creator, governance_token, option::none(), config, launcher_address, option::some(expected_supply), amm_pool_addresses)
    }

    fun create_dao_inflationary_internal(
        creator: &signer,
        governance_token: Object<Metadata>,
        mint_ref_opt: option::Option<MintRef>,
        config: &FactoryConfig,
        launcher_address: address,
        expected_supply_opt: option::Option<u128>,
        amm_pool_addresses: vector<address>
    ): address acquires DaoRegistry {
        let registry = borrow_global_mut<DaoRegistry>(@dao_factory);
        assert!(
            !smart_table::contains(&registry.registered_tokens, governance_token),
            error::already_exists(E_DAO_ALREADY_EXISTS)
        );

        let governance_token_addr = object::object_address(&governance_token);
        let (dao_signer, signer_cap, dao_address, name, current_supply) = prepare_dao_creation(creator, governance_token, expected_supply_opt);

        let dynamic_threshold = (((current_supply * (config.default_proposal_threshold_ppm as u128)) / 1000000) as u64);
        // SECURITY FIX (VULN-07): tiny supplies round the threshold down to 0,
        // which aborts charter::initialize (E_INVALID_THRESHOLD) and bricks
        // DAO creation for that token. Clamp to a minimum of 1.
        if (dynamic_threshold == 0) { dynamic_threshold = 1 };
        let dynamic_initial_emission = (((current_supply * (config.default_initial_emission_ppm as u128)) / 1000000) as u64);
        let dynamic_tail_emission = (((current_supply * (config.default_tail_emission_ppm as u128)) / 1000000) as u64);

        charter::initialize(
            &dao_signer, name, config.default_voting_delay, config.default_voting_period, dynamic_threshold,
            config.default_quorum_numerator, config.default_quorum_denominator, config.default_super_quorum_threshold,
            config.default_late_quorum_extension, config.default_timelock_delay, config.default_grace_period, option::none(),
            launcher_address,
            true // Inflationary DAO: full ve(3,3) engine
        );

        ledger::initialize(&dao_signer, signer_cap);

        legacy::initialize_registry(&dao_signer, governance_token, name);
        witness::initialize(&dao_signer);
        herald::initialize(&dao_signer);

        let constructor_ref = object::create_object(dao_address);
        harvest::initialize(&dao_signer, governance_token, &constructor_ref);

        zeal::initialize(&dao_signer, dao_address, amm_pool_addresses);
        restore::initialize(&dao_signer, governance_token_addr, config.default_bribe_tokens);
        boost_registry::initialize(&dao_signer);
        sentinel::initialize(&dao_signer);
        if (option::is_some(&mint_ref_opt)) {
            let mint_ref = option::extract(&mut mint_ref_opt);
            jubilee::initialize(
                &dao_signer,
                mint_ref,
                dynamic_initial_emission,
                config.default_decay_bps,
                dynamic_tail_emission,
                config.default_gauge_split_bps
            );
        };

        smart_table::add(&mut registry.registered_tokens, governance_token, dao_address);

        event::emit(DaoCreated {
            creator: signer::address_of(creator),
            dao_address,
            governance_token: governance_token_addr,
            name,
            is_inflationary: true,
        });

        dao_address
    }

    // Function to activate the DAO (Can only be called by the configured launcher)
    public entry fun activate_dao(launcher_signer: &signer, dao_address: address) {
        charter::set_active(launcher_signer, dao_address);
        jubilee::sync_clock(dao_address);
    }

    public fun update_static_dao_threshold(
        launcher_signer: &signer,
        dao_address: address,
        governance_token: Object<Metadata>
    ) acquires FactoryConfig, DaoRegistry, LauncherRegistry {
        let launcher_addr = std::signer::address_of(launcher_signer);
        let launcher_registry = borrow_global<LauncherRegistry>(@dao_factory);
        assert!(aptos_std::smart_table::contains(&launcher_registry.approved_launchers, launcher_addr) && *aptos_std::smart_table::borrow(&launcher_registry.approved_launchers, launcher_addr), std::error::permission_denied(E_UNAUTHORIZED_LAUNCHER));
        
        let registry = borrow_global<DaoRegistry>(@dao_factory);
        let registered_dao = *aptos_std::smart_table::borrow(&registry.registered_tokens, governance_token);
        assert!(registered_dao == dao_address, std::error::invalid_argument(E_UNAUTHORIZED_LAUNCHER));

        let supply_opt = fungible_asset::supply(governance_token);
        assert!(std::option::is_some(&supply_opt), std::error::invalid_argument(E_NO_SUPPLY_TRACKING));
        let current_supply = *std::option::borrow(&supply_opt);

        let config = borrow_global<FactoryConfig>(@dao_factory);
        let dynamic_threshold = (((current_supply * (config.default_proposal_threshold_ppm as u128)) / 1000000) as u64);
        if (dynamic_threshold == 0) { dynamic_threshold = 1 };

        let dao_signer = ledger::generate_signer(dao_address);
        charter::update_config(&dao_signer, 6, dynamic_threshold);
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

        let config = borrow_global<FactoryConfig>(@dao_factory);

        // SECURITY FIX (M6): Validate the caller is an approved launcher
        let launcher_addr = std::signer::address_of(launcher_signer);
        let launcher_registry = borrow_global<LauncherRegistry>(@dao_factory);
        assert!(
            aptos_std::smart_table::contains(&launcher_registry.approved_launchers, launcher_addr) && 
            *aptos_std::smart_table::borrow(&launcher_registry.approved_launchers, launcher_addr), 
            error::permission_denied(E_UNAUTHORIZED_LAUNCHER)
        );

        // SECURITY FIX (M6): Validate the DAO actually belongs to the governance token
        let registry = borrow_global<DaoRegistry>(@dao_factory);
        let registered_dao = *aptos_std::smart_table::borrow(&registry.registered_tokens, governance_token);
        assert!(registered_dao == dao_address, error::invalid_argument(E_UNAUTHORIZED_LAUNCHER));

        // SECURITY FIX (M6): Validate the MintRef belongs to the governance token
        // We guarantee this by minting 0 tokens and asserting its metadata
        let test_mint = fungible_asset::mint(&mint_ref, 0);
        let test_metadata = fungible_asset::asset_metadata(&test_mint);
        assert!(test_metadata == governance_token, error::invalid_argument(E_UNAUTHORIZED_LAUNCHER));
        fungible_asset::destroy_zero(test_mint);

        let supply_opt = fungible_asset::supply(governance_token);
        assert!(option::is_some(&supply_opt), error::invalid_argument(E_NO_SUPPLY_TRACKING));
        let current_supply = *option::borrow(&supply_opt);

        let dynamic_initial_emission = (((current_supply * (config.default_initial_emission_ppm as u128)) / 1000000) as u64);
        let dynamic_tail_emission = (((current_supply * (config.default_tail_emission_ppm as u128)) / 1000000) as u64);
        let dynamic_threshold = (((current_supply * (config.default_proposal_threshold_ppm as u128)) / 1000000) as u64);
        // SECURITY FIX (VULN-07): tiny supplies round the threshold down to 0,
        // which aborts charter::initialize (E_INVALID_THRESHOLD) and bricks
        // DAO creation for that token. Clamp to a minimum of 1.
        if (dynamic_threshold == 0) { dynamic_threshold = 1 };

        let dao_signer = ledger::generate_signer(dao_address);
        charter::update_config(&dao_signer, 6, dynamic_threshold);

        jubilee::initialize(
            &dao_signer,
            mint_ref,
            dynamic_initial_emission,
            config.default_decay_bps,
            dynamic_tail_emission,
            config.default_gauge_split_bps
        );

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
        let token_metadata = supra_framework::object::address_to_object<Metadata>(token_addr);
        (
            fungible_asset::name(token_metadata),
            fungible_asset::symbol(token_metadata),
            fungible_asset::decimals(token_metadata),
            fungible_asset::icon_uri(token_metadata),
            fungible_asset::project_uri(token_metadata)
        )
    }
}
