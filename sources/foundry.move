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
    use std::vector;
    use aptos_token_objects::token;
    use dao_factory::pilgrim;
    use dao_factory::boost_registry;
    use dao_factory::table;


    // Errors
    const E_ZERO_AMOUNT: u64 = 2;
    const E_INSUFFICIENT_BALANCE: u64 = 3;

    // Constants
    const REWARD_SCALE: u128 = 1_000_000_000_000_000_000;
    const MAX_U64: u128 = 18_446_744_073_709_551_615;
    const BPS_DENOMINATOR: u128 = 10000;

    // The Gauge Object State
    struct Gauge has key {
        extend_ref: ExtendRef,
        staking_token: Object<Metadata>,
        dao_token: Object<Metadata>,
        dao_address: address,

        reward_rate: u128,
        period_finish: u64,
        last_update_time: u64,
        reward_per_token_stored: u128,

        total_supply: u128,
        balances: SmartTable<address, u128>,
        user_reward_per_token_paid: SmartTable<address, u128>,
        rewards: SmartTable<address, u128>,

        // NFT Boost state (Curve-style "working balances").
        // The reward math below ONLY uses working_supply / working_balances.
        // total_supply / balances keep tracking real LP for withdrawals.
        working_supply: u128,
        working_balances: SmartTable<address, u128>,
        user_boosts: SmartTable<address, UserBoost>,
    }

    // Evidence of a user's applied NFT boost. The listed NFTs are ESCROWED
    // inside this gauge (NFT-staking standard): while deposited, the boost
    // cannot go stale, because the user cannot sell what the gauge holds.
    // The only mutation vector left is governance removing/re-pricing a
    // collection, which is healed by resync_user_boost / sync_boost.
    struct UserBoost has store, drop {
        boost_bps: u64,
        nfts: vector<address>,
    }

    // Events
    #[event]
    struct GaugeCreated has drop, store {
        gauge_address: address,
        staking_token: address,
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

    #[event]
    struct BoostUpdated has drop, store {
        gauge_address: address,
        user: address,
        boost_bps: u64,
    }

    // Creates a new Gauge Object for a specific LP Token.
    // Called by anchor.move when a Gauge proposal passes.
    public(friend) fun create_gauge(
        dao_signer: &signer,
        staking_token_addr: address,
        dao_token_addr: address
    ): address {
        let constructor_ref = object::create_object(signer::address_of(dao_signer));
        let gauge_signer = object::generate_signer(&constructor_ref);
        let gauge_address = signer::address_of(&gauge_signer);

        let staking_token = object::address_to_object<Metadata>(staking_token_addr);
        let dao_token = object::address_to_object<Metadata>(dao_token_addr);

        move_to(&gauge_signer, Gauge {
            extend_ref: object::generate_extend_ref(&constructor_ref),
            staking_token,
            dao_token,
            dao_address: signer::address_of(dao_signer),
            reward_rate: 0,
            period_finish: 0,
            last_update_time: 0,
            reward_per_token_stored: 0,
            total_supply: 0,
            balances: smart_table::new(),
            user_reward_per_token_paid: smart_table::new(),
            rewards: smart_table::new(),
            working_supply: 0,
            working_balances: smart_table::new(),
            user_boosts: smart_table::new(),
        });

        event::emit(GaugeCreated { gauge_address, staking_token: staking_token_addr });
        gauge_address
    }

    // Internal Math Updates

    // Computes the up-to-date reward_per_token WITHOUT mutating state.
    // Single source for the reward math, shared by update_reward (which
    // persists it), earned (view) and reward_per_token (view).
    fun current_reward_per_token(gauge: &Gauge): u128 {
        let current_time = timestamp::now_seconds();
        let last_time_reward_applicable = if (current_time < gauge.period_finish) {
            current_time
        } else {
            gauge.period_finish
        };

        if (gauge.working_supply == 0) {
            return gauge.reward_per_token_stored
        };

        let time_delta = ((last_time_reward_applicable - gauge.last_update_time) as u128);
        // We multiply time_delta * REWARD_SCALE first (which is around 6e23, safely inside u128).
        // Then math128::mul_div handles the multiplication with gauge.reward_rate using u256 internally.
        // This prevents u128 overflow even if the DAO token has 18 decimals and massive inflation!
        let reward_increment = math128::mul_div(time_delta * REWARD_SCALE, gauge.reward_rate, gauge.working_supply);
        gauge.reward_per_token_stored + reward_increment
    }

    fun update_reward(gauge: &mut Gauge, account: address) {
        gauge.reward_per_token_stored = current_reward_per_token(gauge);
        let current_time = timestamp::now_seconds();
        gauge.last_update_time = if (current_time < gauge.period_finish) {
            current_time
        } else {
            gauge.period_finish
        };

        // Update user
        if (account != @0x0) {
            let balance = get_working_balance(gauge, account);

            let user_paid = table::u128_or_zero(&gauge.user_reward_per_token_paid, account);
            let current_reward = table::u128_or_zero(&gauge.rewards, account);

            let earned = math128::mul_div(balance, gauge.reward_per_token_stored - user_paid, REWARD_SCALE);
            smart_table::upsert(&mut gauge.rewards, account, current_reward + earned);
            smart_table::upsert(&mut gauge.user_reward_per_token_paid, account, gauge.reward_per_token_stored);
        }
    }

    // =========================================================================
    // NFT Boost Helpers (working balances)
    // =========================================================================

    fun get_actual_balance(gauge: &Gauge, account: address): u128 {
        table::u128_or_zero(&gauge.balances, account)
    }

    fun get_working_balance(gauge: &Gauge, account: address): u128 {
        table::u128_or_zero(&gauge.working_balances, account)
    }

    fun get_stored_boost_bps(gauge: &Gauge, account: address): u64 {
        if (smart_table::contains(&gauge.user_boosts, account)) {
            smart_table::borrow(&gauge.user_boosts, account).boost_bps
        } else { 0 }
    }

    // Recomputes a user's working balance from their ACTUAL LP balance and
    // their stored boost: working = actual * (10000 + boost_bps) / 10000.
    // MUST be called right after update_reward (settlement), so already
    // accrued rewards are never affected by the mutation (claim -> mutate -> checkpoint).
    fun refresh_working_balance(gauge: &mut Gauge, account: address, actual_balance: u128) {
        let old_working = get_working_balance(gauge, account);
        let boost_bps = get_stored_boost_bps(gauge, account);
        let new_working = math128::mul_div(actual_balance, BPS_DENOMINATOR + (boost_bps as u128), BPS_DENOMINATOR);

        gauge.working_supply = gauge.working_supply - old_working + new_working;
        if (new_working > 0) {
            smart_table::upsert(&mut gauge.working_balances, account, new_working);
        } else if (smart_table::contains(&gauge.working_balances, account)) {
            smart_table::remove(&mut gauge.working_balances, account);
        };
    }

    // Returns escrowed NFTs to their owner using the gauge's extend signer.
    // Skips any NFT that no longer exists (e.g. burned by its creator while
    // escrowed), so withdrawals can never be bricked by external actions.
    fun return_escrowed_nfts(gauge: &Gauge, nfts: vector<address>, owner: address) {
        let gauge_signer = object::generate_signer_for_extending(&gauge.extend_ref);
        let i = 0;
        let len = vector::length(&nfts);
        while (i < len) {
            let nft_addr = *vector::borrow(&nfts, i);
            i = i + 1;
            if (object::object_exists<token::Token>(nft_addr)) {
                let token_obj = object::address_to_object<token::Token>(nft_addr);
                object::transfer(&gauge_signer, token_obj, owner);
            };
        };
    }

    // Re-prices a user's stored boost against the CURRENT registry. NFT
    // ownership CANNOT go stale (the gauge custodies the NFTs), so this only
    // reacts to governance actions: removed or re-priced collections.
    // NFTs whose collection was removed (or duplicates) are automatically
    // returned to the user. Settles pending rewards FIRST at the old rate.
    fun resync_user_boost(gauge_addr: address, gauge: &mut Gauge, account: address) {
        if (!smart_table::contains(&gauge.user_boosts, account)) return;

        let stored_nfts = *&smart_table::borrow(&gauge.user_boosts, account).nfts;
        let current_bps = get_stored_boost_bps(gauge, account);
        let dao_address = gauge.dao_address;

        let (new_bps, kept_nfts, returned_nfts) = boost_registry::compute_escrowed_boost(dao_address, stored_nfts);

        if (new_bps != current_bps || vector::length(&kept_nfts) != vector::length(&stored_nfts)) {
            // Settle at the OLD working balance before mutating.
            update_reward(gauge, account);

            if (vector::length(&returned_nfts) > 0) {
                return_escrowed_nfts(gauge, returned_nfts, account);
            };

            let user_boost_data = smart_table::borrow_mut(&mut gauge.user_boosts, account);
            user_boost_data.boost_bps = new_bps;
            user_boost_data.nfts = kept_nfts;

            let actual_balance = get_actual_balance(gauge, account);
            refresh_working_balance(gauge, account, actual_balance);

            event::emit(BoostUpdated { gauge_address: gauge_addr, user: account, boost_bps: new_bps });
        };
    }

    // User Entry Points
    public entry fun stake(user: &signer, gauge_addr: address, amount: u64) acquires Gauge {
        assert!(amount > 0, error::invalid_argument(E_ZERO_AMOUNT));
        let user_addr = signer::address_of(user);
        let gauge = borrow_global_mut<Gauge>(gauge_addr);

        resync_and_settle(gauge_addr, gauge, user_addr);

        let fa = primary_fungible_store::withdraw(user, gauge.staking_token, amount);
        primary_fungible_store::deposit(gauge_addr, fa);

        let new_balance = get_actual_balance(gauge, user_addr) + (amount as u128);
        let new_supply = gauge.total_supply + (amount as u128);
        update_balance_and_supply(gauge, user_addr, new_balance, new_supply);

        event::emit(Staked { gauge_address: gauge_addr, user: user_addr, amount });
    }

    public entry fun withdraw(user: &signer, gauge_addr: address, amount: u64) acquires Gauge {
        assert!(amount > 0, error::invalid_argument(E_ZERO_AMOUNT));
        let user_addr = signer::address_of(user);
        let gauge = borrow_global_mut<Gauge>(gauge_addr);
        
        let current_balance = get_actual_balance(gauge, user_addr);
        assert!(current_balance >= (amount as u128), error::invalid_state(E_INSUFFICIENT_BALANCE));

        resync_and_settle(gauge_addr, gauge, user_addr);

        let new_balance = current_balance - (amount as u128);
        let new_supply = gauge.total_supply - (amount as u128);
        update_balance_and_supply(gauge, user_addr, new_balance, new_supply);

        let staking_token = gauge.staking_token;
        withdraw_fa(gauge, staking_token, amount, user_addr);

        event::emit(Withdrawn { gauge_address: gauge_addr, user: user_addr, amount });
    }

    public entry fun get_reward(user: &signer, gauge_addr: address) acquires Gauge {
        let user_addr = signer::address_of(user);
        let gauge = borrow_global_mut<Gauge>(gauge_addr);

        resync_and_settle(gauge_addr, gauge, user_addr);

        let reward = table::u128_or_zero(&gauge.rewards, user_addr);

        if (reward > 0) {
            let claimable = if (reward > MAX_U64) { MAX_U64 } else { reward };
            smart_table::upsert(&mut gauge.rewards, user_addr, reward - claimable);
            
            let dao_token = gauge.dao_token;
            withdraw_reward_fa(gauge, (claimable as u64), user_addr);

            event::emit(RewardPaid { gauge_address: gauge_addr, user: user_addr, reward: (claimable as u64) });
        }
    }

    // =========================================================================
    // NFT Boost Entry Points
    // =========================================================================

    // Applies (or refreshes) the caller's NFT boost for this gauge by
    // ESCROWING the NFTs inside the gauge (NFT-staking standard).
    //
    // The caller submits the NFT object addresses they own (found off-chain
    // via the indexer); the contract verifies ownership and collection
    // approval on-chain, then takes custody of the valid ones. While
    // escrowed, the boost cannot go stale: the user cannot sell what the
    // gauge holds. Previously escrowed NFTs are returned first (full reset).
    //
    // Note: soulbound (non-transferable) NFTs cannot be escrowed; the
    // transfer aborts. Governance should not approve soulbound collections.
    //
    // Call `unboost` to withdraw the NFTs and clear the boost.
    // Helper to settle rewards and clear old boost state before applying new ones or unboosting.
    fun prepare_boost_mutation(gauge: &mut Gauge, user_addr: address) {
        update_reward(gauge, user_addr);
        remove_and_return_old_boost(gauge, user_addr);
    }

    public entry fun apply_boost(user: &signer, gauge_addr: address, nft_addrs: vector<address>) acquires Gauge {
        let user_addr = signer::address_of(user);
        let gauge = borrow_global_mut<Gauge>(gauge_addr);

        prepare_boost_mutation(gauge, user_addr);

        // Verify ownership and collection approval on-chain.
        let (boost_bps, valid_nfts) = boost_registry::compute_boost(gauge.dao_address, user_addr, nft_addrs);

        // Escrow the valid NFTs inside the gauge.
        let i = 0;
        let len = vector::length(&valid_nfts);
        while (i < len) {
            let token_obj = object::address_to_object<token::Token>(*vector::borrow(&valid_nfts, i));
            object::transfer(user, token_obj, gauge_addr);
            i = i + 1;
        };

        smart_table::upsert(&mut gauge.user_boosts, user_addr, UserBoost { boost_bps, nfts: valid_nfts });

        let actual_balance = get_actual_balance(gauge, user_addr);
        refresh_working_balance(gauge, user_addr, actual_balance);

        event::emit(BoostUpdated { gauge_address: gauge_addr, user: user_addr, boost_bps });
    }

    // Withdraws ALL escrowed NFTs and clears the boost.
    // NEVER depends on the boost registry and never reverts on governance
    // state: withdrawals are uncensorable, even if every collection was
    // removed. NFTs burned while escrowed are skipped safely.
    public entry fun unboost(user: &signer, gauge_addr: address) acquires Gauge {
        let user_addr = signer::address_of(user);
        let gauge = borrow_global_mut<Gauge>(gauge_addr);

        prepare_boost_mutation(gauge, user_addr);

        let actual_balance = get_actual_balance(gauge, user_addr);
        refresh_working_balance(gauge, user_addr, actual_balance);

        event::emit(BoostUpdated { gauge_address: gauge_addr, user: user_addr, boost_bps: 0 });
    }

    // Permissionless checkpoint: ANYONE can force the re-pricing of a user's
    // stored boost against the current registry. Heals boosts of inactive
    // users when governance removes or re-prices a collection (escrowed NFTs
    // of removed collections are automatically returned to their owner).
    public entry fun sync_boost(_caller: &signer, gauge_addr: address, user: address) acquires Gauge {
        let gauge = borrow_global_mut<Gauge>(gauge_addr);
        resync_user_boost(gauge_addr, gauge, user);
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
        table::u128_or_zero(&borrow_global<Gauge>(gauge_addr).balances, account)
    }

    #[view]
    public fun earned(gauge_addr: address, account: address): u64 acquires Gauge {
        if (!exists<Gauge>(gauge_addr)) return 0;
        let gauge = borrow_global<Gauge>(gauge_addr);

        let current_reward_per_token_stored = current_reward_per_token(gauge);

        let balance = get_working_balance(gauge, account);

        let user_paid = table::u128_or_zero(&gauge.user_reward_per_token_paid, account);
        let current_reward = table::u128_or_zero(&gauge.rewards, account);

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

    #[view]
    public fun reward_per_token(gauge_addr: address): u128 acquires Gauge {
        if (!exists<Gauge>(gauge_addr)) return 0;
        current_reward_per_token(borrow_global<Gauge>(gauge_addr))
    }

    // =========================================================================
    // NFT Boost Views
    // =========================================================================

    #[view]
    public fun working_supply(gauge_addr: address): u128 acquires Gauge {
        if (!exists<Gauge>(gauge_addr)) return 0;
        borrow_global<Gauge>(gauge_addr).working_supply
    }

    #[view]
    public fun working_balance_of(gauge_addr: address, account: address): u128 acquires Gauge {
        if (!exists<Gauge>(gauge_addr)) return 0;
        get_working_balance(borrow_global<Gauge>(gauge_addr), account)
    }

    #[view]
    public fun get_user_boost_bps(gauge_addr: address, account: address): u64 acquires Gauge {
        if (!exists<Gauge>(gauge_addr)) return 0;
        get_stored_boost_bps(borrow_global<Gauge>(gauge_addr), account)
    }

    #[view]
    public fun get_user_boost_nfts(gauge_addr: address, account: address): vector<address> acquires Gauge {
        if (!exists<Gauge>(gauge_addr)) return vector::empty();
        let gauge = borrow_global<Gauge>(gauge_addr);
        if (smart_table::contains(&gauge.user_boosts, account)) {
            *&smart_table::borrow(&gauge.user_boosts, account).nfts
        } else {
            vector::empty()
        }
    }

    #[view]
    public fun staking_token(gauge_addr: address): address acquires Gauge {
        object::object_address(&borrow_global<Gauge>(gauge_addr).staking_token)
    }

    // --- Helpers for Deduplication ---

    fun resync_and_settle(gauge_addr: address, gauge: &mut Gauge, user_addr: address) {
        resync_user_boost(gauge_addr, gauge, user_addr);
        update_reward(gauge, user_addr);
    }

    fun update_balance_and_supply(gauge: &mut Gauge, user_addr: address, new_balance: u128, new_supply: u128) {
        gauge.total_supply = new_supply;
        smart_table::upsert(&mut gauge.balances, user_addr, new_balance);
        refresh_working_balance(gauge, user_addr, new_balance);
    }

    fun remove_and_return_old_boost(gauge: &mut Gauge, user_addr: address) {
        if (smart_table::contains(&gauge.user_boosts, user_addr)) {
            let old_boost = smart_table::remove(&mut gauge.user_boosts, user_addr);
            return_escrowed_nfts(gauge, old_boost.nfts, user_addr);
        };
    }

    fun withdraw_fa(gauge: &Gauge, token: Object<Metadata>, amount: u64, to: address) {
        let gauge_signer = object::generate_signer_for_extending(&gauge.extend_ref);
        let fa = primary_fungible_store::withdraw(&gauge_signer, token, amount);
        primary_fungible_store::deposit(to, fa);
    }

    fun withdraw_reward_fa(gauge: &Gauge, amount: u64, to: address) {
        let gauge_signer = object::generate_signer_for_extending(&gauge.extend_ref);
        // Withdraw from Gauge (whitelisted, no sell tax)
        let fa = primary_fungible_store::withdraw(&gauge_signer, gauge.dao_token, amount);
        
        // Deposit to user (bypassing buy tax)
        let dest_store = primary_fungible_store::ensure_primary_store_exists(to, gauge.dao_token);
        dao_factory::tax_router::deposit_tax_free(gauge.dao_address, dest_store, fa);
    }
}
