// Minter Module - The economic engine (Inflation)
//
// Handles the emission of new governance tokens.
// - Works based on epochs (emits once a week).
// - Implements a decay curve (decay_bps) and a guaranteed minimum emission (tail_emission).
// - Divides the emission into two parts:
//   1. Rebase (~20%): Goes directly to the veToken contract to protect lockers from dilution.
//   2. Gauges (~80%): (For now goes to the fee distributor, in Phase 3 it will go to the Gauges to be directed by voters).
module dao_factory::jubilee {
    friend dao_factory::petra;
    friend dao_factory::anchor;
    friend dao_factory::herald;
    use std::signer;
    use supra_framework::fungible_asset::{Self, MintRef};
    use supra_framework::event;
    use std::error;

    use dao_factory::pilgrim;
    use dao_factory::legacy;
    use dao_factory::zeal;
    use dao_factory::charter;
    use dao_factory::sentinel;
    use dao_factory::math;

    // Errors 
    const E_ALREADY_MINTED: u64 = 1;
    const E_INVALID_BPS: u64    = 2;
    const E_MINT_EXCEEDED: u64  = 3;
    const E_TOO_MANY_EPOCHS: u64 = 4;
    const E_NOT_ACTIVE: u64     = 5;
    const E_PAUSED: u64         = 6;

    // Constants 
    // 1 Quintillion (10,000,000,000 with 8 decimals). Physical limit to prevent exploits.
    const MAX_MINT_PER_EPOCH: u64 = 1_000_000_000_000_000_000;

    // Structs 
    struct MinterConfig has key {
        mint_ref: MintRef,
        // Emission corresponding to the current epoch
        weekly_emission: u64,
        // The last epoch in which tokens were minted
        last_epoch: u64,
        // Decay percentage per epoch (in basis points, e.g., 100 = 1%)
        decay_bps: u64,
        // Guaranteed minimum emission (tail emission)
        tail_emission: u64,
        // Percentage of emission going to gauges (in basis points, e.g., 8000 = 80%)
        // The remainder (10000 - gauge_split_bps) goes to rebase.
        gauge_split_bps: u64,
    }

    // Events 
    #[event]
    struct EpochAdvanced has drop, store {
        dao_address: address,
        pilgrim: u64,
        total_minted: u64,
        gauge_amount: u64,
        rebase_amount: u64,
    }

    // Initialization 

    public(friend) fun initialize(
        dao_signer: &signer,
        mint_ref: MintRef,
        initial_emission: u64,
        decay_bps: u64,
        tail_emission: u64,
        gauge_split_bps: u64,
    ) {
        assert!(gauge_split_bps <= 10000, error::invalid_argument(E_INVALID_BPS));
        assert!(decay_bps <= 10000, error::invalid_argument(E_INVALID_BPS));

        move_to(dao_signer, MinterConfig {
            mint_ref,
            weekly_emission: initial_emission,
            last_epoch: pilgrim::now(),
            decay_bps,
            tail_emission,
            gauge_split_bps,
        });
    }

    // Resets the inflation clock to the current epoch.
    // Called when a delayed DAO is finally activated by its launcher.
    public(friend) fun sync_clock(dao_address: address) acquires MinterConfig {
        if (exists<MinterConfig>(dao_address)) {
            let config = borrow_global_mut<MinterConfig>(dao_address);
            config.last_epoch = pilgrim::now();
        }
    }

    // Core Functions 

    // Advances the epoch for the DAO, emitting inflation and distributing.
    // Anyone can call this function (Keeper or Bot).
    public entry fun advance_epoch(dao_address: address) acquires MinterConfig {
        assert!(charter::is_active(dao_address), error::invalid_state(E_NOT_ACTIVE));
        assert!(!sentinel::is_paused(dao_address), error::invalid_state(E_PAUSED));
        let current_epoch = pilgrim::now();
        let config = borrow_global_mut<MinterConfig>(dao_address);
        
        assert!(current_epoch > config.last_epoch, error::invalid_state(E_ALREADY_MINTED));

        let mut_epochs_passed = current_epoch - config.last_epoch;
        
        // Pagination: Limit processing to a maximum of 50 epochs per call
        // to prevent Out Of Gas blocks, allowing catch-up via successive calls.
        let epochs_to_process = if (mut_epochs_passed > 50) { 50 } else { mut_epochs_passed };
        let total_minted: u64 = 0;
        let total_gauge: u64 = 0;
        let total_rebase: u64 = 0;
        let start_epoch = config.last_epoch;
        
        let actual_epochs_processed = 0;
        while (actual_epochs_processed < epochs_to_process) {
            let emission_this_epoch = config.weekly_emission;
            assert!(emission_this_epoch <= MAX_MINT_PER_EPOCH, error::invalid_state(E_MINT_EXCEEDED));
            
            // SECURITY FIX (M5): Prevents that the fixed pagination causes an overflow 
            // permanente of u64 (18.44e18) if the weekly emission is high.
            // If the next epoch would cause an overflow, we stop the iteration.
            if ((18446744073709551615u64 - total_minted) < emission_this_epoch) {
                break
            };

            total_minted = total_minted + emission_this_epoch;
            
            let gauge_this_epoch = math::apply_bps(emission_this_epoch, config.gauge_split_bps);
            let rebase_this_epoch = emission_this_epoch - gauge_this_epoch;

            total_gauge = total_gauge + gauge_this_epoch;
            total_rebase = total_rebase + rebase_this_epoch;

            if (gauge_this_epoch > 0) {
                let gauge_fa = fungible_asset::mint(&config.mint_ref, gauge_this_epoch);
                zeal::distribute_emissions(dao_address, start_epoch + actual_epochs_processed, gauge_fa);
            };
            
            // Calculate decay for the next epoch
            // We use u128 to prevent overflow in multiplication
            let decay = math::apply_bps(config.weekly_emission, config.decay_bps);
            let next_emission = if (config.weekly_emission > decay) {
                config.weekly_emission - decay
            } else {
                0
            };

            // Tail emission
            if (next_emission < config.tail_emission) {
                next_emission = config.tail_emission;
            };
            config.weekly_emission = next_emission;
            actual_epochs_processed = actual_epochs_processed + 1;
        };

        // Update last_epoch by adding the processed amount, instead of setting to current_epoch,
        // guaranteeing that if it was capped at 50, it can be called again to complete the rest.
        config.last_epoch = start_epoch + actual_epochs_processed;

        if (total_rebase > 0) {
            let rebase_fa = fungible_asset::mint(&config.mint_ref, total_rebase);
            legacy::inject_rebase(dao_address, rebase_fa);
        };

        if (total_minted > 0) {
            event::emit(EpochAdvanced {
                dao_address,
                pilgrim: config.last_epoch,
                total_minted,
                gauge_amount: total_gauge,
                rebase_amount: total_rebase,
            });
        };
    }

    // Administrative Functions (DAO Only) 

    // Validates an emission parameter at proposal time (fail-fast for herald).
    // Keys mirror the config keys routed by anchor::execute_action:
    // 9 = decay_bps, 10 = tail_emission, 11 = gauge_split_bps.
    // The same bounds are enforced again at execution by the update_* functions.
    public(friend) fun assert_valid_emission_param(dao_address: address, config_key: u64, value: u64) acquires MinterConfig {
        if (config_key == 9) {
            assert!(value <= 500, error::invalid_argument(E_INVALID_BPS)); // Max 5% decay
        } else if (config_key == 10) {
            let config = borrow_global<MinterConfig>(dao_address);
            assert!(value <= config.weekly_emission, error::invalid_argument(E_INVALID_BPS));
        } else if (config_key == 11) {
            assert!(value >= 8000 && value <= 10000, error::invalid_argument(E_INVALID_BPS)); // Min 80% to gauges
        } else {
            abort error::invalid_argument(E_INVALID_BPS)
        };
    }

    public(friend) fun update_config(dao_signer: &signer, config_key: u64, value: u64) acquires MinterConfig {
        let dao_address = signer::address_of(dao_signer);
        assert_valid_emission_param(dao_address, config_key, value);
        let config = borrow_global_mut<MinterConfig>(dao_address);
        if (config_key == 9) {
            config.decay_bps = value;
        } else if (config_key == 10) {
            config.tail_emission = value;
        } else if (config_key == 11) {
            config.gauge_split_bps = value;
        } else {
            abort error::invalid_argument(E_INVALID_BPS)
        };
    }

    // Views 
    
    #[view]
    public fun get_weekly_emission(dao_address: address): u64 acquires MinterConfig {
        if (exists<MinterConfig>(dao_address)) {
            borrow_global<MinterConfig>(dao_address).weekly_emission
        } else {
            0
        }
    }
    
    #[view]
    public fun get_last_epoch(dao_address: address): u64 acquires MinterConfig {
        if (exists<MinterConfig>(dao_address)) {
            borrow_global<MinterConfig>(dao_address).last_epoch
        } else {
            0
        }
    }

    #[view]
    public fun get_weekly_gauge_emission(dao_address: address): u64 acquires MinterConfig {
        if (exists<MinterConfig>(dao_address)) {
            let config = borrow_global<MinterConfig>(dao_address);
            let total_emission = config.weekly_emission;
            math::apply_bps(total_emission, config.gauge_split_bps)
        } else {
            0
        }
    }

    #[view]
    public fun get_gauge_split_bps(dao_address: address): u64 acquires MinterConfig {
        if (exists<MinterConfig>(dao_address)) {
            borrow_global<MinterConfig>(dao_address).gauge_split_bps
        } else {
            0
        }
    }
}
