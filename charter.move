module dao_factory::charter {
    friend dao_factory::herald;
    friend dao_factory::petra;
    friend dao_factory::anchor;

    use std::string::String;
    use std::option::Option;
    use std::error;
    use supra_framework::event;
    
    use dao_factory::jubilee;

    // Errors
    const E_INVALID_DELAY: u64 = 1;
    const E_INVALID_PERIOD: u64 = 2;
    const E_INVALID_QUORUM: u64 = 3;
    const E_INVALID_THRESHOLD: u64 = 4;
    const E_UNAUTHORIZED_LAUNCHER: u64 = 5;

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
        launcher_address: address
    ) {
        assert!(voting_delay >= MIN_DELAY_SECONDS && voting_delay <= MAX_DELAY_SECONDS, error::invalid_argument(E_INVALID_DELAY));
        assert!(voting_period >= MIN_PERIOD_SECONDS && voting_period <= MAX_DELAY_SECONDS, error::invalid_argument(E_INVALID_PERIOD));
        assert!(timelock_delay >= MIN_DELAY_SECONDS && timelock_delay <= MAX_DELAY_SECONDS, error::invalid_argument(E_INVALID_DELAY));
        assert!(quorum_numerator > 0 && quorum_numerator <= quorum_denominator, error::invalid_argument(E_INVALID_QUORUM));
        // Strict minimum bounds for safety
        assert!(quorum_numerator * 100 / quorum_denominator >= 1, error::invalid_argument(E_INVALID_QUORUM)); // At least 1%
        assert!(super_quorum_threshold > 0 && super_quorum_threshold <= quorum_denominator, error::invalid_argument(E_INVALID_QUORUM));
        assert!(super_quorum_threshold * 100 / quorum_denominator >= 50, error::invalid_argument(E_INVALID_QUORUM)); // At least 50%
        assert!(proposal_threshold > 0, error::invalid_argument(E_INVALID_THRESHOLD));

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
            is_active: (launcher_address == @0x0),
            launcher_address
        });
    }

    // Public view function to check if the DAO is active
    public fun is_active(dao_address: address): bool acquires DaoConfig {
        borrow_global<DaoConfig>(dao_address).is_active
    }

    // Function to activate the DAO (Can only be called by the configured launcher)
    public entry fun activate_dao(launcher_signer: &signer, dao_address: address) acquires DaoConfig {
        let config = borrow_global_mut<DaoConfig>(dao_address);
        assert!(std::signer::address_of(launcher_signer) == config.launcher_address, error::permission_denied(E_UNAUTHORIZED_LAUNCHER));
        config.is_active = true;
        
        // Fix: Reset the inflation clock so the DAO doesn't mint years of accumulated inflation instantly.
        jubilee::sync_clock(dao_address);

        event::emit(DaoActivated {
            dao_address,
            launcher_address: config.launcher_address,
        });
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
        if (config_key == 0) {
            assert!(config_value > 0 && config_value <= config.quorum_denominator, error::invalid_argument(E_INVALID_QUORUM));
            assert!(config_value * 100 / config.quorum_denominator >= 50, error::invalid_argument(E_INVALID_QUORUM)); // At least 50% super quorum
        } else if (config_key == 1) {
            assert!(config_value > 0 && config_value <= config.quorum_denominator, error::invalid_argument(E_INVALID_QUORUM));
            assert!(config_value * 100 / config.quorum_denominator >= 1, error::invalid_argument(E_INVALID_QUORUM)); // At least 1% quorum
        } else if (config_key == 2) {
            assert!(config_value >= config.quorum_numerator && config_value >= config.super_quorum_threshold, error::invalid_argument(E_INVALID_QUORUM));
        } else if (config_key == 3) {
            assert!(config_value <= MAX_DELAY_SECONDS, error::invalid_argument(E_INVALID_DELAY));
        } else if (config_key == 4) {
            assert!(config_value >= MIN_DELAY_SECONDS && config_value <= MAX_DELAY_SECONDS, error::invalid_argument(E_INVALID_DELAY));
        } else if (config_key == 5) {
            assert!(config_value >= MIN_PERIOD_SECONDS && config_value <= MAX_DELAY_SECONDS, error::invalid_argument(E_INVALID_PERIOD));
        } else if (config_key == 6) {
            assert!(config_value > 0, error::invalid_argument(E_INVALID_THRESHOLD));
        } else if (config_key == 7) {
            assert!(config_value >= MIN_DELAY_SECONDS && config_value <= MAX_DELAY_SECONDS, error::invalid_argument(E_INVALID_DELAY));
        } else if (config_key == 8) {
            assert!(config_value >= MIN_PERIOD_SECONDS && config_value <= MAX_DELAY_SECONDS, error::invalid_argument(E_INVALID_PERIOD));
        } else {
            abort error::invalid_argument(E_INVALID_DELAY) // or E_INVALID_CONFIG_KEY
        };
    }

    // Admin: Modify Quorum (must be called by the DAO itself through execute_proposal)
    public(friend) fun update_super_quorum(dao_signer: &signer, new_quorum: u64) acquires DaoConfig {
        let dao_address = std::signer::address_of(dao_signer);
        validate_config_value(dao_address, 0, new_quorum);
        let config = borrow_global_mut<DaoConfig>(dao_address);
        config.super_quorum_threshold = new_quorum;
        event::emit(DaoConfigUpdated { dao_address, config_key: 0, config_value: new_quorum });
    }

    public(friend) fun update_quorum_numerator(dao_signer: &signer, new_numerator: u64) acquires DaoConfig {
        let dao_address = std::signer::address_of(dao_signer);
        validate_config_value(dao_address, 1, new_numerator);
        let config = borrow_global_mut<DaoConfig>(dao_address);
        config.quorum_numerator = new_numerator;
        event::emit(DaoConfigUpdated { dao_address, config_key: 1, config_value: new_numerator });
    }

    public(friend) fun update_quorum_denominator(dao_signer: &signer, new_denominator: u64) acquires DaoConfig {
        let dao_address = std::signer::address_of(dao_signer);
        validate_config_value(dao_address, 2, new_denominator);
        let config = borrow_global_mut<DaoConfig>(dao_address);
        config.quorum_denominator = new_denominator;
        event::emit(DaoConfigUpdated { dao_address, config_key: 2, config_value: new_denominator });
    }

    public(friend) fun update_late_quorum_extension(dao_signer: &signer, new_extension: u64) acquires DaoConfig {
        let dao_address = std::signer::address_of(dao_signer);
        validate_config_value(dao_address, 3, new_extension);
        let config = borrow_global_mut<DaoConfig>(dao_address);
        config.late_quorum_extension = new_extension;
        event::emit(DaoConfigUpdated { dao_address, config_key: 3, config_value: new_extension });
    }

    public(friend) fun update_voting_delay(dao_signer: &signer, new_delay: u64) acquires DaoConfig {
        let dao_address = std::signer::address_of(dao_signer);
        validate_config_value(dao_address, 4, new_delay);
        let config = borrow_global_mut<DaoConfig>(dao_address);
        config.voting_delay = new_delay;
        event::emit(DaoConfigUpdated { dao_address, config_key: 4, config_value: new_delay });
    }

    public(friend) fun update_voting_period(dao_signer: &signer, new_period: u64) acquires DaoConfig {
        let dao_address = std::signer::address_of(dao_signer);
        validate_config_value(dao_address, 5, new_period);
        let config = borrow_global_mut<DaoConfig>(dao_address);
        config.voting_period = new_period;
        event::emit(DaoConfigUpdated { dao_address, config_key: 5, config_value: new_period });
    }

    public(friend) fun update_proposal_threshold(dao_signer: &signer, new_threshold: u64) acquires DaoConfig {
        let dao_address = std::signer::address_of(dao_signer);
        validate_config_value(dao_address, 6, new_threshold);
        let config = borrow_global_mut<DaoConfig>(dao_address);
        config.proposal_threshold = new_threshold;
        event::emit(DaoConfigUpdated { dao_address, config_key: 6, config_value: new_threshold });
    }

    public(friend) fun update_timelock_delay(dao_signer: &signer, new_delay: u64) acquires DaoConfig {
        let dao_address = std::signer::address_of(dao_signer);
        validate_config_value(dao_address, 7, new_delay);
        let config = borrow_global_mut<DaoConfig>(dao_address);
        config.timelock_delay = new_delay;
        event::emit(DaoConfigUpdated { dao_address, config_key: 7, config_value: new_delay });
    }

    public(friend) fun update_grace_period(dao_signer: &signer, new_grace_period: u64) acquires DaoConfig {
        let dao_address = std::signer::address_of(dao_signer);
        validate_config_value(dao_address, 8, new_grace_period);
        let config = borrow_global_mut<DaoConfig>(dao_address);
        config.grace_period = new_grace_period;
        event::emit(DaoConfigUpdated { dao_address, config_key: 8, config_value: new_grace_period });
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

    // ==========================================
    // VIEW FUNCTIONS (For the Frontend)
    // ==========================================

    #[view]
    public fun get_proposal_count(dao_address: address): u64 acquires DaoConfig {
        borrow_global<DaoConfig>(dao_address).proposal_count
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
