// Synthetix-style Staking Rewards (Gauge)
// Stream rewards evenly over a 7-day Epoch.
module dao_factory::foundry {
    friend dao_factory::zeal;
    friend dao_factory::anchor;

    use std::signer;
    use supra_framework::object::{Self, Object, ExtendRef};
    use supra_framework::fungible_asset::{Self, Metadata, FungibleAsset};
    use supra_framework::primary_fungible_store;
    use aptos_std::smart_table::{Self, SmartTable};
    use aptos_std::math128;
    use supra_framework::timestamp;
    use std::error;
    use supra_framework::event;
    use dao_factory::pilgrim;

    // Errors
    const E_NOT_AUTHORIZED: u64 = 1;
    const E_ZERO_AMOUNT: u64 = 2;
    const E_INSUFFICIENT_BALANCE: u64 = 3;

    // Constants
    const REWARD_SCALE: u128 = 1_000_000_000_000_000_000;
    const MAX_U64: u128 = 18_446_744_073_709_551_615;

    // The Gauge Object State
    struct Gauge has key {
        extend_ref: ExtendRef,
        lp_token: Object<Metadata>,
        dao_token: Object<Metadata>,
        
        reward_rate: u128,
        period_finish: u64,
        last_update_time: u64,
        reward_per_token_stored: u128,
        
        total_supply: u128,
        balances: SmartTable<address, u128>,
        user_reward_per_token_paid: SmartTable<address, u128>,
        rewards: SmartTable<address, u128>,
    }

    // Events
    #[event]
    struct GaugeCreated has drop, store {
        gauge_address: address,
        lp_token: address,
    }

    #[event]
    struct Staked has drop, store {
        gauge_address: address,
        user: address,
        amount: u64,
    }

    #[event]
    struct Withdrawn has drop, store {
        gauge_address: address,
        user: address,
        amount: u64,
    }

    #[event]
    struct RewardPaid has drop, store {
        gauge_address: address,
        user: address,
        reward: u64,
    }

    #[event]
    struct RewardAdded has drop, store {
        gauge_address: address,
        amount: u64,
    }

    // Creates a new Gauge Object for a specific LP Token.
    // Called by anchor.move when a Gauge proposal passes.
    public(friend) fun create_gauge(
        dao_signer: &signer,
        lp_token_addr: address,
        dao_token_addr: address
    ): address {
        let constructor_ref = object::create_object(signer::address_of(dao_signer));
        let gauge_signer = object::generate_signer(&constructor_ref);
        let gauge_address = signer::address_of(&gauge_signer);

        let lp_token = object::address_to_object<Metadata>(lp_token_addr);
        let dao_token = object::address_to_object<Metadata>(dao_token_addr);

        move_to(&gauge_signer, Gauge {
            extend_ref: object::generate_extend_ref(&constructor_ref),
            lp_token,
            dao_token,
            reward_rate: 0,
            period_finish: 0,
            last_update_time: 0,
            reward_per_token_stored: 0,
            total_supply: 0,
            balances: smart_table::new(),
            user_reward_per_token_paid: smart_table::new(),
            rewards: smart_table::new(),
        });

        event::emit(GaugeCreated { gauge_address, lp_token: lp_token_addr });
        gauge_address
    }

    // Internal Math Updates
    fun update_reward(gauge: &mut Gauge, account: address) {
        let current_time = timestamp::now_seconds();
        
        // Calculate reward per token
        let last_time_reward_applicable = if (current_time < gauge.period_finish) {
            current_time
        } else {
            gauge.period_finish
        };

        if (gauge.total_supply > 0) {
            let time_delta = ((last_time_reward_applicable - gauge.last_update_time) as u128);
            // We multiply time_delta * REWARD_SCALE first (which is around 6e23, safely inside u128).
            // Then math128::mul_div handles the multiplication with gauge.reward_rate using u256 internally.
            // This prevents u128 overflow even if the DAO token has 18 decimals and massive inflation!
            let reward_increment = math128::mul_div(time_delta * REWARD_SCALE, gauge.reward_rate, gauge.total_supply);
            gauge.reward_per_token_stored = gauge.reward_per_token_stored + reward_increment;
        };
        gauge.last_update_time = last_time_reward_applicable;

        // Update user
        if (account != @0x0) {
            let balance = if (smart_table::contains(&gauge.balances, account)) {
                *smart_table::borrow(&gauge.balances, account)
            } else { 0 };

            let user_paid = if (smart_table::contains(&gauge.user_reward_per_token_paid, account)) {
                *smart_table::borrow(&gauge.user_reward_per_token_paid, account)
            } else { 0 };

            let current_reward = if (smart_table::contains(&gauge.rewards, account)) {
                *smart_table::borrow(&gauge.rewards, account)
            } else { 0 };

            let earned = math128::mul_div(balance, gauge.reward_per_token_stored - user_paid, REWARD_SCALE);
            smart_table::upsert(&mut gauge.rewards, account, current_reward + earned);
            smart_table::upsert(&mut gauge.user_reward_per_token_paid, account, gauge.reward_per_token_stored);
        }
    }

    // User Entry Points
    public entry fun stake(user: &signer, gauge_addr: address, amount: u64) acquires Gauge {
        assert!(amount > 0, error::invalid_argument(E_ZERO_AMOUNT));
        let user_addr = signer::address_of(user);
        let gauge = borrow_global_mut<Gauge>(gauge_addr);
        
        update_reward(gauge, user_addr);

        let fa = primary_fungible_store::withdraw(user, gauge.lp_token, amount);
        primary_fungible_store::deposit(gauge_addr, fa);

        let current_balance = if (smart_table::contains(&gauge.balances, user_addr)) {
            *smart_table::borrow(&gauge.balances, user_addr)
        } else { 0 };

        gauge.total_supply = gauge.total_supply + (amount as u128);
        smart_table::upsert(&mut gauge.balances, user_addr, current_balance + (amount as u128));

        event::emit(Staked { gauge_address: gauge_addr, user: user_addr, amount });
    }

    public entry fun withdraw(user: &signer, gauge_addr: address, amount: u64) acquires Gauge {
        assert!(amount > 0, error::invalid_argument(E_ZERO_AMOUNT));
        let user_addr = signer::address_of(user);
        let gauge = borrow_global_mut<Gauge>(gauge_addr);
        
        let current_balance = if (smart_table::contains(&gauge.balances, user_addr)) {
            *smart_table::borrow(&gauge.balances, user_addr)
        } else { 0 };

        assert!(current_balance >= (amount as u128), error::invalid_state(E_INSUFFICIENT_BALANCE));
        
        update_reward(gauge, user_addr);

        gauge.total_supply = gauge.total_supply - (amount as u128);
        smart_table::upsert(&mut gauge.balances, user_addr, current_balance - (amount as u128));

        let gauge_signer = object::generate_signer_for_extending(&gauge.extend_ref);
        let fa = primary_fungible_store::withdraw(&gauge_signer, gauge.lp_token, amount);
        primary_fungible_store::deposit(user_addr, fa);

        event::emit(Withdrawn { gauge_address: gauge_addr, user: user_addr, amount });
    }

    public entry fun get_reward(user: &signer, gauge_addr: address) acquires Gauge {
        let user_addr = signer::address_of(user);
        let gauge = borrow_global_mut<Gauge>(gauge_addr);
        
        update_reward(gauge, user_addr);

        let reward = if (smart_table::contains(&gauge.rewards, user_addr)) {
            *smart_table::borrow(&gauge.rewards, user_addr)
        } else { 0 };

        if (reward > 0) {
            let claimable = if (reward > MAX_U64) { MAX_U64 } else { reward };

            smart_table::upsert(&mut gauge.rewards, user_addr, reward - claimable);
            
            let gauge_signer = object::generate_signer_for_extending(&gauge.extend_ref);
            let fa = primary_fungible_store::withdraw(&gauge_signer, gauge.dao_token, (claimable as u64));
            primary_fungible_store::deposit(user_addr, fa);

            event::emit(RewardPaid { gauge_address: gauge_addr, user: user_addr, reward: (claimable as u64) });
        }
    }

    // Called internally by zeal.move when claim_gauge_emission is executed.
    public(friend) fun notify_reward_amount(gauge_addr: address, fa: FungibleAsset) acquires Gauge {
        let amount = (fungible_asset::amount(&fa) as u128);
        if (amount == 0) {
            fungible_asset::destroy_zero(fa);
            return
        };

        let gauge = borrow_global_mut<Gauge>(gauge_addr);
        update_reward(gauge, @0x0);

        let current_time = timestamp::now_seconds();
        
        if (current_time >= gauge.period_finish) {
            gauge.reward_rate = amount / (pilgrim::duration() as u128);
        } else {
            let remaining = gauge.period_finish - current_time;
            let leftover = (remaining as u128) * gauge.reward_rate;
            gauge.reward_rate = (amount + leftover) / (pilgrim::duration() as u128);
        };

        gauge.last_update_time = current_time;
        gauge.period_finish = current_time + pilgrim::duration();

        primary_fungible_store::deposit(gauge_addr, fa);

        event::emit(RewardAdded { gauge_address: gauge_addr, amount: (amount as u64) });
    }

    // =========================================================================
    // View Functions for Frontend and Indexers
    // =========================================================================

    #[view]
    public fun total_supply(gauge_addr: address): u128 acquires Gauge {
        if (!exists<Gauge>(gauge_addr)) return 0;
        borrow_global<Gauge>(gauge_addr).total_supply
    }

    #[view]
    public fun balance_of(gauge_addr: address, account: address): u128 acquires Gauge {
        if (!exists<Gauge>(gauge_addr)) return 0;
        let gauge = borrow_global<Gauge>(gauge_addr);
        if (smart_table::contains(&gauge.balances, account)) {
            *smart_table::borrow(&gauge.balances, account)
        } else {
            0
        }
    }

    #[view]
    public fun earned(gauge_addr: address, account: address): u64 acquires Gauge {
        if (!exists<Gauge>(gauge_addr)) return 0;
        let gauge = borrow_global<Gauge>(gauge_addr);
        
        let current_time = timestamp::now_seconds();
        let last_time_reward_applicable = if (current_time < gauge.period_finish) {
            current_time
        } else {
            gauge.period_finish
        };

        let current_reward_per_token_stored = gauge.reward_per_token_stored;
        if (gauge.total_supply > 0) {
            let time_delta = ((last_time_reward_applicable - gauge.last_update_time) as u128);
            let reward_increment = math128::mul_div(time_delta * REWARD_SCALE, gauge.reward_rate, gauge.total_supply);
            current_reward_per_token_stored = current_reward_per_token_stored + reward_increment;
        };

        let balance = if (smart_table::contains(&gauge.balances, account)) {
            *smart_table::borrow(&gauge.balances, account)
        } else { 0 };

        let user_paid = if (smart_table::contains(&gauge.user_reward_per_token_paid, account)) {
            *smart_table::borrow(&gauge.user_reward_per_token_paid, account)
        } else { 0 };

        let current_reward = if (smart_table::contains(&gauge.rewards, account)) {
            *smart_table::borrow(&gauge.rewards, account)
        } else { 0 };

        let newly_earned = math128::mul_div(balance, current_reward_per_token_stored - user_paid, REWARD_SCALE);
        (current_reward + newly_earned as u64)
    }

    #[view]
    public fun reward_rate(gauge_addr: address): u128 acquires Gauge {
        if (!exists<Gauge>(gauge_addr)) return 0;
        borrow_global<Gauge>(gauge_addr).reward_rate
    }

    #[view]
    public fun period_finish(gauge_addr: address): u64 acquires Gauge {
        if (!exists<Gauge>(gauge_addr)) return 0;
        borrow_global<Gauge>(gauge_addr).period_finish
    }
}
