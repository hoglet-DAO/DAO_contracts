// Reward Distribution Module - Synthetix Model.
//
// Accumulates rewards (AMM fees, Staking fees, Minter inflation)
// and distributes them PROPORTIONALLY to veToken holders based on their
// locked amount.
//
// Refactor: This module does NOT depend on `legacy` to avoid circular
// dependencies. It works as an agnostic reward vault. `legacy` 
// is responsible for calling `checkpoint` and `claim_rewards`.
module dao_factory::harvest {
    friend dao_factory::petra;
    friend dao_factory::legacy;
    use supra_framework::fungible_asset::{Self, FungibleAsset, FungibleStore, Metadata};
    use supra_framework::object::Object;
    use supra_framework::primary_fungible_store;
    use supra_framework::event;
    use aptos_std::smart_table::{Self, SmartTable};

    // Constants 
    // Precision factor to avoid truncation in division.
    const PRECISION: u256 = 1_000_000_000_000;

    // Structs 
    // The DAO's reward vault.
    struct RewardVault has key {
        // The physical store where rewards are accumulated.
        store: Object<FungibleStore>,
        // ExtendRef to sign transactions for the vault.
        extend_ref: supra_framework::object::ExtendRef,
        // Metadata of the reward token (usually the same governance token).
        reward_token: Object<Metadata>,
        // Global accumulator of rewards per locked unit.
        acc_reward_per_share: u128,
        // Reward debt of each veToken (indexed by the veToken's Object Address).
        // Prevents someone from claiming past rewards that do not belong to them.
        user_debt: SmartTable<address, u128>,
    }

    // Events 
    #[event]
    struct RewardsInjected has drop, store {
        dao_address: address,
        amount: u64,
        new_acc: u128,
    }

    #[event]
    struct RewardsClaimed has drop, store {
        dao_address: address,
        claimer: address,
        legacy: address,
        amount: u64,
    }

    // Initialization 
    // Initializes the reward vault. Called by petra when creating the DAO.
    public(friend) fun initialize(
        dao_signer: &signer,
        reward_token: Object<Metadata>,
        constructor_ref: &supra_framework::object::ConstructorRef,
    ) {
        let store = fungible_asset::create_store(constructor_ref, reward_token);
        let extend_ref = supra_framework::object::generate_extend_ref(constructor_ref);
        move_to(dao_signer, RewardVault {
            store,
            extend_ref,
            reward_token,
            acc_reward_per_share: 0,
            user_debt: smart_table::new(),
        });
    }

    // Core Functions 
    // Injects new rewards into the vault (AMM fees, Staking, or inflation).
    // Updates the global accumulator. `total_locked` is provided by the caller.
    public(friend) fun inject_rewards(
        dao_address: address, 
        reward: FungibleAsset,
        total_locked: u64
    ) acquires RewardVault {
        let vault = borrow_global_mut<RewardVault>(dao_address);
        let amount = fungible_asset::amount(&reward);

        if (total_locked > 0 && amount > 0) {
            let increment = (((amount as u256) * PRECISION / (total_locked as u256)) as u128);
            vault.acc_reward_per_share = vault.acc_reward_per_share + increment;
        };

        fungible_asset::deposit(vault.store, reward);

        event::emit(RewardsInjected {
            dao_address,
            amount,
            new_acc: vault.acc_reward_per_share,
        });
    }

    // Updates a user's debt when their balance changes in `legacy`.
    // Must be called by `legacy` AFTER updating the balance,
    // but passing the `new_locked` amount.
    public(friend) fun checkpoint(
        dao_address: address,
        ve_token_addr: address,
        new_locked: u64,
    ) acquires RewardVault {
        if (!exists<RewardVault>(dao_address)) return;

        let vault = borrow_global_mut<RewardVault>(dao_address);
        let new_debt = (((new_locked as u256) * (vault.acc_reward_per_share as u256) / PRECISION) as u128);
        smart_table::upsert(&mut vault.user_debt, ve_token_addr, new_debt);
    }

    // Claims pending rewards.
    // Called by `legacy` (which verifies ownership).
    public(friend) fun claim_rewards_internal(
        dao_address: address,
        owner_addr: address,
        ve_addr: address,
        locked_amount: u64,
    ) acquires RewardVault {
        let vault = borrow_global_mut<RewardVault>(dao_address);

        let debt: u128 = if (smart_table::contains(&vault.user_debt, ve_addr)) {
            *smart_table::borrow(&vault.user_debt, ve_addr)
        } else {
            0
        };

        // Pending = (locked * acc_per_share / PRECISION) - debt
        let earned_u128 = (((locked_amount as u256) * (vault.acc_reward_per_share as u256) / PRECISION) as u128);
        let pending_u128 = if (earned_u128 > debt) { earned_u128 - debt } else { 0 };
        let pending = (pending_u128 as u64);
        if (pending == 0) return;

        // Update debt to the current accumulator.
        smart_table::upsert(&mut vault.user_debt, ve_addr, earned_u128);

        // Transfer rewards to the owner.
        let vault_signer = supra_framework::object::generate_signer_for_extending(&vault.extend_ref);
        let dest_store = primary_fungible_store::ensure_primary_store_exists(
            owner_addr,
            vault.reward_token,
        );
        fungible_asset::transfer(&vault_signer, vault.store, dest_store, pending);

        event::emit(RewardsClaimed {
            dao_address,
            claimer: owner_addr,
            legacy: ve_addr,
            amount: pending,
        });
    }

    // View Functions 
    #[view]
    public fun calculate_pending(
        dao_address: address,
        ve_addr: address,
        locked_amount: u64,
    ): u64 acquires RewardVault {
        if (!exists<RewardVault>(dao_address)) return 0;

        let vault = borrow_global<RewardVault>(dao_address);

        let debt: u128 = if (smart_table::contains(&vault.user_debt, ve_addr)) {
            *smart_table::borrow(&vault.user_debt, ve_addr)
        } else {
            0
        };

        let earned_u128 = (((locked_amount as u256) * (vault.acc_reward_per_share as u256) / PRECISION) as u128);
        if (earned_u128 > debt) { ((earned_u128 - debt) as u64) } else { 0 }
    }
}
