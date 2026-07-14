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

    // Errors 
    const E_NOT_ADMIN: u64 = 1;
    const E_INSUFFICIENT_FEE: u64 = 2;
    const E_ADMIN_EXPIRED: u64 = 3;
    const E_ALREADY_RENOUNCED: u64 = 4;
    const E_DAO_ALREADY_EXISTS: u64 = 5;
    const E_NOT_OBJECT: u64 = 6;
    const E_DECAY_TOO_HIGH: u64 = 7;
    const E_GAUGE_SPLIT_TOO_LOW: u64 = 8;
    const E_DECIMALS_TOO_HIGH: u64 = 9;
    const E_NO_SUPPLY_TRACKING: u64 = 10;
    const E_SUPPLY_ZERO: u64 = 11;
    const E_NAME_TOO_LONG: u64 = 12;
    const E_SYMBOL_TOO_LONG: u64 = 13;
    const E_UNAUTHORIZED_LAUNCHER: u64 = 14;
    const E_TOKEN_CLAIMED_BY_LAUNCHER: u64 = 15;

    // Constants 
    // The admin MUST transfer to a DAO.

    // Global State (Anti-Spam and Admin) 
    
    struct FactoryConfig has key {
        creation_fee: u64,
        fee_receiver: address,
        admin_address: address,

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
            default_voting_delay: charter::min_delay_seconds(), // Using SSOT from charter
            default_voting_period: 604800, // 1 week is standard
            default_proposal_threshold_ppm: 137, // 137 PPM = 0.0137% of Supply
            default_quorum_numerator: 7, // 7% Quorum
            default_quorum_denominator: 100,
            default_super_quorum_threshold: 73, // 73% Super Quorum
            default_late_quorum_extension: 86400,
            default_timelock_delay: 86400,
            default_grace_period: 1209600, // 14 days
            default_initial_emission_ppm: 13700, // 13700 PPM = 1.37%
            default_decay_bps: 137, // 1.37% decay
            default_tail_emission_ppm: 137, // 137 PPM = 0.0137%
            default_gauge_split_bps: 10000,
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
    
    fun pow_10(exp: u8): u64 {
        let res = 1;
        let i = 0;
        while (i < exp) {
            res = res * 10;
            i = i + 1;
        };
        res
    }

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

    // Transfers the admin to a new address (typically a DAO).
    // This is the correct way to complete the Ouroboros pattern.
    public entry fun transfer_admin(admin: &signer, new_admin: address) acquires FactoryConfig {
        assert_admin(admin);
        let config = borrow_global_mut<FactoryConfig>(@dao_factory);
        let old_admin = config.admin_address;
        config.admin_address = new_admin;
        event::emit(AdminTransferred { old_admin, new_admin });
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
        let config = borrow_global_mut<FactoryConfig>(@dao_factory);
        config.creation_fee = new_fee;
    }

    public entry fun set_fee_receiver(admin: &signer, new_receiver: address) acquires FactoryConfig {
        assert_admin(admin);
        let config = borrow_global_mut<FactoryConfig>(@dao_factory);
        config.fee_receiver = new_receiver;
    }

    public entry fun set_default_voting_delay(admin: &signer, value: u64) acquires FactoryConfig {
        assert_admin(admin);
        borrow_global_mut<FactoryConfig>(@dao_factory).default_voting_delay = value;
    }

    public entry fun set_default_voting_period(admin: &signer, value: u64) acquires FactoryConfig {
        assert_admin(admin);
        borrow_global_mut<FactoryConfig>(@dao_factory).default_voting_period = value;
    }

    public entry fun set_default_proposal_threshold_ppm(admin: &signer, value: u64) acquires FactoryConfig {
        assert_admin(admin);
        borrow_global_mut<FactoryConfig>(@dao_factory).default_proposal_threshold_ppm = value;
    }

    public entry fun set_default_quorum_numerator(admin: &signer, value: u64) acquires FactoryConfig {
        assert_admin(admin);
        borrow_global_mut<FactoryConfig>(@dao_factory).default_quorum_numerator = value;
    }

    public entry fun set_default_quorum_denominator(admin: &signer, value: u64) acquires FactoryConfig {
        assert_admin(admin);
        borrow_global_mut<FactoryConfig>(@dao_factory).default_quorum_denominator = value;
    }

    public entry fun set_default_super_quorum_threshold(admin: &signer, value: u64) acquires FactoryConfig {
        assert_admin(admin);
        borrow_global_mut<FactoryConfig>(@dao_factory).default_super_quorum_threshold = value;
    }

    public entry fun set_default_late_quorum_extension(admin: &signer, value: u64) acquires FactoryConfig {
        assert_admin(admin);
        borrow_global_mut<FactoryConfig>(@dao_factory).default_late_quorum_extension = value;
    }

    public entry fun set_default_timelock_delay(admin: &signer, value: u64) acquires FactoryConfig {
        assert_admin(admin);
        borrow_global_mut<FactoryConfig>(@dao_factory).default_timelock_delay = value;
    }

    public entry fun set_default_initial_emission_ppm(admin: &signer, value: u64) acquires FactoryConfig {
        assert_admin(admin);
        borrow_global_mut<FactoryConfig>(@dao_factory).default_initial_emission_ppm = value;
    }

    public entry fun set_default_decay_bps(admin: &signer, value: u64) acquires FactoryConfig {
        assert_admin(admin);
        assert!(value <= 500, error::invalid_argument(E_DECAY_TOO_HIGH));
        borrow_global_mut<FactoryConfig>(@dao_factory).default_decay_bps = value;
    }

    public entry fun set_default_tail_emission_ppm(admin: &signer, value: u64) acquires FactoryConfig {
        assert_admin(admin);
        borrow_global_mut<FactoryConfig>(@dao_factory).default_tail_emission_ppm = value;
    }

    public entry fun set_default_gauge_split_bps(admin: &signer, value: u64) acquires FactoryConfig {
        assert_admin(admin);
        assert!(value >= 8000 && value <= 10000, error::invalid_argument(E_GAUGE_SPLIT_TOO_LOW));
        borrow_global_mut<FactoryConfig>(@dao_factory).default_gauge_split_bps = value;
    }

    // The admin can renounce, burning the admin key.
    // This is irreversible - once renounced, no one is admin.
    public entry fun renounce_admin(admin: &signer) acquires FactoryConfig {
        assert_admin(admin);
        let config = borrow_global_mut<FactoryConfig>(@dao_factory);
        let old_admin = config.admin_address;
        config.admin_address = @0x0;
        event::emit(AdminRenounced { admin: old_admin, epoch: pilgrim::now() });
    }

    // Static DAO (For tokens with fixed supply) 

    public entry fun create_dao_static(
        creator: &signer,
        governance_token: Object<Metadata>
    ) acquires FactoryConfig, DaoRegistry, LauncherRegistry {
        let governance_token_addr = object::object_address(&governance_token);
        charge_creation_fee(creator);

        let config = borrow_global<FactoryConfig>(@dao_factory);
        let registry = borrow_global_mut<DaoRegistry>(@dao_factory);

        assert!(
            !smart_table::contains(&registry.registered_tokens, governance_token),
            error::already_exists(E_DAO_ALREADY_EXISTS)
        );

        let launcher_registry = borrow_global<LauncherRegistry>(@dao_factory);
        assert!(
            !smart_table::contains(&launcher_registry.claimed_tokens, governance_token),
            error::permission_denied(E_TOKEN_CLAIMED_BY_LAUNCHER)
        );

        let name = fungible_asset::name(governance_token);
        let symbol = fungible_asset::symbol(governance_token);
        assert!(string::length(&name) <= 60, error::invalid_argument(E_NAME_TOO_LONG));
        assert!(string::length(&symbol) <= 20, error::invalid_argument(E_SYMBOL_TOO_LONG));
        
        string::append_utf8(&mut name, b" DAO");
        let seed = bcs::to_bytes(&governance_token_addr);
        let time_micros = timestamp::now_microseconds();
        vector::append(&mut seed, bcs::to_bytes(&time_micros));
        let (dao_signer, signer_cap) = account::create_resource_account(creator, seed);
        let dao_address = signer::address_of(&dao_signer);

        let decimals = fungible_asset::decimals(governance_token);
        assert!(decimals <= 8, error::invalid_argument(E_DECIMALS_TOO_HIGH));

        let supply_opt = fungible_asset::supply(governance_token);
        assert!(option::is_some(&supply_opt), error::invalid_argument(E_NO_SUPPLY_TRACKING));
        let current_supply = *option::borrow(&supply_opt);
        assert!(current_supply > 0, error::invalid_argument(E_SUPPLY_ZERO));

        let dynamic_threshold = (((current_supply * (config.default_proposal_threshold_ppm as u128)) / 1000000) as u64);

        charter::initialize(
            &dao_signer, name, config.default_voting_delay, config.default_voting_period, dynamic_threshold,
            config.default_quorum_numerator, config.default_quorum_denominator, config.default_super_quorum_threshold,
            config.default_late_quorum_extension, config.default_timelock_delay, config.default_grace_period, option::none(),
            @0x0
        );

        ledger::initialize(&dao_signer, signer_cap);

        legacy::initialize_registry(&dao_signer, governance_token, name);
        witness::initialize(&dao_signer);
        herald::initialize(&dao_signer);

        let constructor_ref = object::create_object(dao_address);
        harvest::initialize(&dao_signer, governance_token, &constructor_ref);
        sentinel::initialize(&dao_signer);

        smart_table::add(&mut registry.registered_tokens, governance_token, dao_address);

        event::emit(DaoCreated {
            creator: signer::address_of(creator),
            dao_address,
            governance_token: governance_token_addr,
            name,
            is_inflationary: false,
        });
    }

    // Static DAO (Called exclusively by an approved Launcher)
    public fun create_dao_static_from_launcher(
        creator: &signer,
        launcher_signer: &signer,
        governance_token: Object<Metadata>
    ) acquires FactoryConfig, DaoRegistry, LauncherRegistry {
        let launcher_address = signer::address_of(launcher_signer);
        let launcher_registry = borrow_global<LauncherRegistry>(@dao_factory);
        assert!(
            smart_table::contains(&launcher_registry.approved_launchers, launcher_address) && 
            *smart_table::borrow(&launcher_registry.approved_launchers, launcher_address),
            error::permission_denied(E_UNAUTHORIZED_LAUNCHER)
        );

        let governance_token_addr = object::object_address(&governance_token);
        charge_creation_fee(creator);

        let config = borrow_global<FactoryConfig>(@dao_factory);
        let registry = borrow_global_mut<DaoRegistry>(@dao_factory);

        assert!(
            !smart_table::contains(&registry.registered_tokens, governance_token),
            error::already_exists(E_DAO_ALREADY_EXISTS)
        );

        let name = fungible_asset::name(governance_token);
        let symbol = fungible_asset::symbol(governance_token);
        assert!(string::length(&name) <= 60, error::invalid_argument(E_NAME_TOO_LONG));
        assert!(string::length(&symbol) <= 20, error::invalid_argument(E_SYMBOL_TOO_LONG));
        
        string::append_utf8(&mut name, b" DAO");
        let seed = bcs::to_bytes(&governance_token_addr);
        let time_micros = timestamp::now_microseconds();
        vector::append(&mut seed, bcs::to_bytes(&time_micros));
        let (dao_signer, signer_cap) = account::create_resource_account(creator, seed);
        let dao_address = signer::address_of(&dao_signer);

        let decimals = fungible_asset::decimals(governance_token);
        assert!(decimals <= 8, error::invalid_argument(E_DECIMALS_TOO_HIGH));

        let supply_opt = fungible_asset::supply(governance_token);
        assert!(option::is_some(&supply_opt), error::invalid_argument(E_NO_SUPPLY_TRACKING));
        let current_supply = *option::borrow(&supply_opt);
        assert!(current_supply > 0, error::invalid_argument(E_SUPPLY_ZERO));

        let dynamic_threshold = (((current_supply * (config.default_proposal_threshold_ppm as u128)) / 1000000) as u64);

        charter::initialize(
            &dao_signer, name, config.default_voting_delay, config.default_voting_period, dynamic_threshold,
            config.default_quorum_numerator, config.default_quorum_denominator, config.default_super_quorum_threshold,
            config.default_late_quorum_extension, config.default_timelock_delay, config.default_grace_period, option::none(),
            launcher_address
        );

        ledger::initialize(&dao_signer, signer_cap);

        legacy::initialize_registry(&dao_signer, governance_token, name);
        witness::initialize(&dao_signer);
        herald::initialize(&dao_signer);

        let constructor_ref = object::create_object(dao_address);
        harvest::initialize(&dao_signer, governance_token, &constructor_ref);
        sentinel::initialize(&dao_signer);

        smart_table::add(&mut registry.registered_tokens, governance_token, dao_address);

        event::emit(DaoCreated {
            creator: signer::address_of(creator),
            dao_address,
            governance_token: governance_token_addr,
            name,
            is_inflationary: false,
        });
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
        create_dao_inflationary_internal(creator, governance_token, mint_ref, config, @0x0)
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

    // Inflationary DAO (Called exclusively by an approved Launcher)
    public fun create_dao_inflationary_from_launcher(
        creator: &signer,
        launcher_signer: &signer,
        governance_token: Object<Metadata>,
        mint_ref: MintRef
    ): address acquires FactoryConfig, DaoRegistry, LauncherRegistry {
        let launcher_address = signer::address_of(launcher_signer);
        let launcher_registry = borrow_global<LauncherRegistry>(@dao_factory);
        assert!(
            smart_table::contains(&launcher_registry.approved_launchers, launcher_address) && 
            *smart_table::borrow(&launcher_registry.approved_launchers, launcher_address),
            error::permission_denied(E_UNAUTHORIZED_LAUNCHER)
        );

        charge_creation_fee(creator);
        let config = borrow_global<FactoryConfig>(@dao_factory);
        create_dao_inflationary_internal(creator, governance_token, mint_ref, config, launcher_address)
    }

    fun create_dao_inflationary_internal(
        creator: &signer,
        governance_token: Object<Metadata>,
        mint_ref: MintRef,
        config: &FactoryConfig,
        launcher_address: address
    ): address acquires DaoRegistry {
        let registry = borrow_global_mut<DaoRegistry>(@dao_factory);
        assert!(
            !smart_table::contains(&registry.registered_tokens, governance_token),
            error::already_exists(E_DAO_ALREADY_EXISTS)
        );

        let governance_token_addr = object::object_address(&governance_token);
        let name = fungible_asset::name(governance_token);
        let symbol = fungible_asset::symbol(governance_token);
        assert!(string::length(&name) <= 60, error::invalid_argument(E_NAME_TOO_LONG));
        assert!(string::length(&symbol) <= 20, error::invalid_argument(E_SYMBOL_TOO_LONG));
        
        string::append_utf8(&mut name, b" DAO");
        let seed = bcs::to_bytes(&governance_token_addr);
        let time_micros = timestamp::now_microseconds();
        vector::append(&mut seed, bcs::to_bytes(&time_micros));
        let (dao_signer, signer_cap) = account::create_resource_account(creator, seed);
        let dao_address = signer::address_of(&dao_signer);

        let decimals = fungible_asset::decimals(governance_token);
        assert!(decimals <= 8, error::invalid_argument(E_DECIMALS_TOO_HIGH));

        let supply_opt = fungible_asset::supply(governance_token);
        assert!(option::is_some(&supply_opt), error::invalid_argument(E_NO_SUPPLY_TRACKING));
        let current_supply = *option::borrow(&supply_opt);
        assert!(current_supply > 0, error::invalid_argument(E_SUPPLY_ZERO));

        let dynamic_threshold = (((current_supply * (config.default_proposal_threshold_ppm as u128)) / 1000000) as u64);
        let dynamic_initial_emission = (((current_supply * (config.default_initial_emission_ppm as u128)) / 1000000) as u64);
        let dynamic_tail_emission = (((current_supply * (config.default_tail_emission_ppm as u128)) / 1000000) as u64);

        charter::initialize(
            &dao_signer, name, config.default_voting_delay, config.default_voting_period, dynamic_threshold,
            config.default_quorum_numerator, config.default_quorum_denominator, config.default_super_quorum_threshold,
            config.default_late_quorum_extension, config.default_timelock_delay, config.default_grace_period, option::none(),
            launcher_address
        );

        ledger::initialize(&dao_signer, signer_cap);

        legacy::initialize_registry(&dao_signer, governance_token, name);
        witness::initialize(&dao_signer);
        herald::initialize(&dao_signer);

        let constructor_ref = object::create_object(dao_address);
        harvest::initialize(&dao_signer, governance_token, &constructor_ref);

        zeal::initialize(&dao_signer, dao_address);
        restore::initialize(&dao_signer);
        sentinel::initialize(&dao_signer);
        jubilee::initialize(
            &dao_signer,
            mint_ref,
            dynamic_initial_emission,
            config.default_decay_bps,
            dynamic_tail_emission,
            config.default_gauge_split_bps
        );

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
}
