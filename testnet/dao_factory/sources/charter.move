module dao_factory::charter {
    friend dao_factory::herald;
    friend dao_factory::petra;
    friend dao_factory::anchor;

    use std::string::String;
    use std::option::{Self, Option};
    use std::signer;
    use std::error;
    use supra_framework::event;
    use dao_libs::math;

    // Errors
    const E_INVALID_DELAY: u64 = 1;
    const E_INVALID_PERIOD: u64 = 2;
    const E_INVALID_QUORUM: u64 = 3;
    const E_INVALID_THRESHOLD: u64 = 4;
    const E_UNAUTHORIZED_LAUNCHER: u64 = 5;
    const E_ALREADY_BLESSED: u64 = 6;
    const E_NOT_CURATOR: u64 = 7;

    const MAX_DELAY_SECONDS: u64 = 2592000; // 30 days
    const MIN_PERIOD_SECONDS: u64 = 86400;   // 1 day (Prevents flash-governance)
    const MIN_DELAY_SECONDS: u64 = 43200;   // 12 hours

    public fun min_delay_seconds(): u64 { MIN_DELAY_SECONDS }
    public fun max_delay_seconds(): u64 { MAX_DELAY_SECONDS }
    public fun min_period_seconds(): u64 { MIN_PERIOD_SECONDS }

    // Base configuration of a DAO
    struct DaoConfig has key, store {
        name: String,
        voting_delay: u64,
        voting_period: u64,
        proposal_threshold: u64,
        quorum_numerator: u64,
        quorum_denominator: u64,
        super_quorum_threshold: u64,
        late_quorum_extension: u64,
        timelock_delay: u64,
        grace_period: u64,
        proposal_count: u64,
        guardian: Option<address>,
        is_active: bool,
        launcher_address: address,
        // Type of DAO: true = inflationary ve(3,3) engine (jubilee minter,
        // zeal gauges, restore bribes, boost_registry); false = static
        // (pure governance). Set once at creation by petra and immutable.
        // SINGLE SOURCE OF TRUTH for the DAO type across all modules.
        is_inflationary: bool,
        is_blessed: bool,
    }

    #[event]
    struct GuardianUpdated has drop, store {
        dao_address: address,
        old_guardian: Option<address>,
        new_guardian: Option<address>,
    }

    #[event]
    struct DaoConfigUpdated has drop, store {
        dao_address: address,
        config_key: u8,
        config_value: u64,
    }

    #[event]
    struct DaoActivated has drop, store {
        dao_address: address,
        launcher_address: address,
    }

    #[event]
    struct StaticDaoBlessed has drop, store {
        dao_address: address,
        curator: address,
    }

    // Constructor function (only callable by our internal module)
    public(friend) fun initialize(
        dao_signer: &signer,
        name: String,
        voting_delay: u64,
        voting_period: u64,
        proposal_threshold: u64,
        quorum_numerator: u64,
        quorum_denominator: u64,
        super_quorum_threshold: u64,
        late_quorum_extension: u64,
        timelock_delay: u64,
        grace_period: u64,
        guardian: Option<address>,
        launcher_address: address,
        is_inflationary: bool
    ) {
                math::validate_charter_genesis(
            voting_delay,
            voting_period,
            timelock_delay,
            quorum_numerator,
            quorum_denominator,
            super_quorum_threshold,
            proposal_threshold
        );
        assert!(grace_period >= 86400 && grace_period <= 31536000, error::invalid_argument(2));
        assert!(late_quorum_extension <= 2592000, error::invalid_argument(1));

        move_to(dao_signer, DaoConfig {
            name,
            voting_delay,
            voting_period,
            proposal_threshold,
            quorum_numerator,
            quorum_denominator,
            super_quorum_threshold,
            late_quorum_extension,
            timelock_delay,
            grace_period,
            proposal_count: 0, // Starts with 0 proposals
            guardian,
            // M-06 Defense: DAOs created permissionlessly without a launcher (@0x0)
            // or inflationary DAOs start active immediately.
            is_active: (launcher_address == @0x0 || is_inflationary),
            launcher_address,
            is_inflationary,
            is_blessed: is_inflationary
        });
    }

    // Single source of truth for the DAO type. Returns true if the DAO was
    // created with the inflationary ve(3,3) engine (jubilee, zeal, restore,
    // boost_registry). Returns false for static DAOs and for addresses
    // without a DaoConfig.
    #[view]
    public fun is_inflationary(dao_address: address): bool acquires DaoConfig {
        if (!exists<DaoConfig>(dao_address)) return false;
        borrow_global<DaoConfig>(dao_address).is_inflationary
    }

    // Single source of truth for the blessed status of a DAO. Returns true
    // for inflationary DAOs (born blessed) and blessed static DAOs.
    // Returns false for static DAOs still under curatorship or non-existent DAOs.
    #[view]
    public fun is_blessed(dao_address: address): bool acquires DaoConfig {
        if (!exists<DaoConfig>(dao_address)) return false;
        borrow_global<DaoConfig>(dao_address).is_blessed
    }

    // Curatorship Blessing: The curator validates the static DAO and grants permanent emancipation.
    // 100% IRREVOCABLE: Once blessed, is_blessed cannot be reversed to false.
    public entry fun bless_dao(curator: &signer, dao_address: address) acquires DaoConfig {
        let curator_addr = signer::address_of(curator);
        let config = borrow_global_mut<DaoConfig>(dao_address);
        assert!(!config.is_blessed, error::invalid_state(E_ALREADY_BLESSED));
        assert!(
            option::is_some(&config.guardian) && *option::borrow(&config.guardian) == curator_addr,
            error::permission_denied(E_NOT_CURATOR)
        );
        config.is_blessed = true;

        event::emit(StaticDaoBlessed {
            dao_address,
            curator: curator_addr,
        });
    }

    // Function to activate the DAO (Called by petra)
    public(friend) fun set_active(launcher_signer: &signer, dao_address: address) acquires DaoConfig {
        let config = borrow_global_mut<DaoConfig>(dao_address);
        assert!(std::signer::address_of(launcher_signer) == config.launcher_address, error::permission_denied(E_UNAUTHORIZED_LAUNCHER));
        config.is_active = true;

        event::emit(DaoActivated {
            dao_address,
            launcher_address: config.launcher_address,
        });
    }


    // The launcher that created this DAO (@0x0 for DAOs created directly,
    // without a launcher). Used by petra to validate launcher-scoped actions.
    #[view]
    public fun get_launcher_address(dao_address: address): address acquires DaoConfig {
        if (!exists<DaoConfig>(dao_address)) return @0x0;
        borrow_global<DaoConfig>(dao_address).launcher_address
    }

    // Function to increment the proposal ID (Extension: GovernorSequentialProposalId)
    public(friend) fun increment_proposal_count(dao_address: address): u64 acquires DaoConfig {
        let config = borrow_global_mut<DaoConfig>(dao_address);
        config.proposal_count = config.proposal_count + 1;
        config.proposal_count
    }



    #[view]
    public fun get_guardian(dao_address: address): Option<address> acquires DaoConfig {
        borrow_global<DaoConfig>(dao_address).guardian
    }

        // Validates a configuration value without modifying state. Used by herald to validate proposals.
    public fun validate_config_value(dao_address: address, config_key: u8, config_value: u64) acquires DaoConfig {
        let config = borrow_global<DaoConfig>(dao_address);
        math::validate_charter_config(
            config_key,
            config_value,
            config.quorum_numerator,
            config.quorum_denominator,
            config.super_quorum_threshold,
            config.proposal_threshold,
        );
    }

    // Factory: Recalculate proposal threshold from actual circulating supply (bypasses user-proposal 10x guard)
    public(friend) fun update_proposal_threshold_by_factory(dao_signer: &signer, new_threshold: u64) acquires DaoConfig {
        assert!(new_threshold > 0, error::invalid_argument(4));
        let dao_address = std::signer::address_of(dao_signer);
        let config = borrow_global_mut<DaoConfig>(dao_address);
        config.proposal_threshold = new_threshold;
        event::emit(DaoConfigUpdated { dao_address, config_key: 6, config_value: new_threshold });
    }

    // Admin: Modify Configuration (must be called by the DAO itself through execute_proposal)
    public(friend) fun update_config(dao_signer: &signer, config_key: u8, config_value: u64) acquires DaoConfig {
        let dao_address = prepare_update(dao_signer, config_key, config_value);
        let config = borrow_global_mut<DaoConfig>(dao_address);
        
        if (config_key == 0) config.super_quorum_threshold = config_value
        else if (config_key == 1) config.quorum_numerator = config_value
        else if (config_key == 2) config.quorum_denominator = config_value
        else if (config_key == 3) config.late_quorum_extension = config_value
        else if (config_key == 4) config.voting_delay = config_value
        else if (config_key == 5) config.voting_period = config_value
        else if (config_key == 6) config.proposal_threshold = config_value
        else if (config_key == 7) config.timelock_delay = config_value
        else if (config_key == 8) config.grace_period = config_value
        else abort error::invalid_argument(E_INVALID_DELAY);
    }

    // --- Helpers for Deduplication ---

    fun prepare_update(dao_signer: &signer, config_key: u8, config_value: u64): address acquires DaoConfig {
        let dao_address = std::signer::address_of(dao_signer);
        validate_config_value(dao_address, config_key, config_value);
        event::emit(DaoConfigUpdated { dao_address, config_key, config_value });
        dao_address
    }

    public(friend) fun update_guardian(dao_signer: &signer, new_guardian: Option<address>) acquires DaoConfig {
        let dao_address = std::signer::address_of(dao_signer);
        let config = borrow_global_mut<DaoConfig>(dao_address);
        let old_guardian = config.guardian;
        config.guardian = new_guardian;

        event::emit(GuardianUpdated {
            dao_address,
            old_guardian,
            new_guardian,
        });
    }

    // Factory: Allows the Factory Admin to reassign the curator if compromised BEFORE blessing
    public(friend) fun update_guardian_by_factory(dao_address: address, new_guardian: Option<address>) acquires DaoConfig {
        let config = borrow_global_mut<DaoConfig>(dao_address);
        let old_guardian = config.guardian;
        config.guardian = new_guardian;

        event::emit(GuardianUpdated {
            dao_address,
            old_guardian,
            new_guardian,
        });
    }

    // ==========================================
    // VIEW FUNCTIONS (For the Frontend)
    // ==========================================
    
    #[view]
    public fun get_proposal_count(dao_address: address): u64 acquires DaoConfig {
        borrow_global<DaoConfig>(dao_address).proposal_count
    }
    
    #[view]
    public fun is_active(dao_address: address): bool acquires DaoConfig {
        borrow_global<DaoConfig>(dao_address).is_active
    }

    #[view]
    public fun get_dao_config_view(dao_address: address): (String, u64, u64, u64, u64, u64, u64, u64) acquires DaoConfig {
        let config = borrow_global<DaoConfig>(dao_address);
        (
            config.name,
            config.voting_delay,
            config.voting_period,
            config.proposal_threshold,
            config.quorum_numerator,
            config.quorum_denominator,
            config.super_quorum_threshold,
            config.timelock_delay
        )
    }

    #[view]
    public fun get_late_quorum_extension(dao_address: address): u64 acquires DaoConfig {
        borrow_global<DaoConfig>(dao_address).late_quorum_extension
    }

    #[view]
    public fun get_timelock_delay(dao_address: address): u64 acquires DaoConfig {
        borrow_global<DaoConfig>(dao_address).timelock_delay
    }

    #[view]
    public fun get_grace_period(dao_address: address): u64 acquires DaoConfig {
        borrow_global<DaoConfig>(dao_address).grace_period
    }
}
