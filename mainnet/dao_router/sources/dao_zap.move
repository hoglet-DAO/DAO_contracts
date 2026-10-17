// Zap router  one door to buy governance tokens with any quote and lock them
// into a fresh veNFT, atomically.
//
// Formerly `zap_buy_lock_router`. This is the standard ve-tokenomics
// one-click flow (Aerodrome/Velodrome "buy & lock", Convex-style zap): the
// user pays with a native Coin or any FA and ends up with a lock, without an
// intermediate manual step.
//
// Supports wrapped static DAOs: automatically wraps native tokens bought on the AMM
// before depositing into veNFT escrow.
module dao_router::dao_zap {
    use std::error;
    use std::option;
    use std::signer;
    use std::vector;
    use dao_factory::petra;
    use dao_factory::legacy;
    use dao_router::dao_wrapper;
    use supra_framework::object::{Self, Object};
    use supra_framework::fungible_asset::{Self, Metadata};
    use supra_framework::primary_fungible_store;
    use supra_framework::dispatchable_fungible_asset;
    use spike_amm::amm_router;

    const E_DAO_NOT_FOUND: u64 = 1;
    const E_INVALID_PATH: u64 = 2;
    const E_ZERO_AMOUNT: u64 = 3;
    const E_NOTHING_TO_LOCK: u64 = 4;

    // Owner's primary-store balance; 0 when no store exists yet
    // (first-time buyers), so the delta captures the full deposit.
    inline fun read_balance(owner: address, token: Object<Metadata>): u64 {
        if (primary_fungible_store::primary_store_exists(owner, token)) {
            primary_fungible_store::balance(owner, token)
        } else {
            0u64
        }
    }

    // Resolves the DAO that owns `gov_token`.
    // If `gov_token` is already the DAO token, returns that DAO.
    // If `gov_token` has no direct DAO, but is registered in `dao_wrapper` and its wrapped FA owns a DAO,
    // returns (dao_address, wrapped_metadata, true).
    fun resolve_dao_and_token(gov_token: Object<Metadata>): (address, Object<Metadata>, bool) {
        let dao_opt = petra::get_dao_for_token(gov_token);
        if (option::is_some(&dao_opt)) {
            (option::extract(&mut dao_opt), gov_token, false)
        } else if (dao_wrapper::is_wrapper_registered_for_native(gov_token)) {
            let wrapped_meta = dao_wrapper::get_wrapper_for_fa(gov_token);
            let wrapped_dao_opt = petra::get_dao_for_token(wrapped_meta);
            if (option::is_some(&wrapped_dao_opt)) {
                (option::extract(&mut wrapped_dao_opt), wrapped_meta, true)
            } else {
                abort error::not_found(E_DAO_NOT_FOUND)
            }
        } else {
            abort error::not_found(E_DAO_NOT_FOUND)
        }
    }

    fun resolve_dao(gov_token: Object<Metadata>): address {
        let (dao_addr, _, _) = resolve_dao_and_token(gov_token);
        dao_addr
    }

    // The route must END at the governance token: the last hop is always the
    // buy leg. The frontend may add intermediate hops (e.g. via the wrapped
    // SUPRA) to find the best route.
    inline fun assert_path_ends_at(path: &vector<address>, gov_addr: address) {
        assert!(
            !vector::is_empty(path)
                && *vector::borrow(path, vector::length(path) - 1) == gov_addr,
            error::invalid_argument(E_INVALID_PATH)
        );
    }

    // Claims `amount` of `gov_token` with the native Coin `CoinType` and locks
    // the net result into a fresh veNFT for `lock_epochs`, atomically.
    //
    // `path` follows the amm_router convention; the wrapped-coin start is
    // injected by the AMM router itself. Typically `[gov]`.
    public entry fun buy_and_lock_coin<CoinType>(
        user: &signer,
        gov_token: Object<Metadata>,
        amount: u64,
        amount_out_min: u64,
        path: vector<address>,
        deadline: u64,
        lock_epochs: u64,
    ) {
        assert!(amount > 0, error::invalid_argument(E_ZERO_AMOUNT));
        let gov_addr = object::object_address(&gov_token);
        assert_path_ends_at(&path, gov_addr);
        let (dao_address, target_token, needs_wrap) = resolve_dao_and_token(gov_token);

        let user_addr = signer::address_of(user);
        let before = read_balance(user_addr, gov_token);

        amm_router::swap_exact_coin_for_tokens_beta<CoinType>(
            user,
            amount,
            amount_out_min,
            path,
            user_addr,
            deadline
        );

        let delta = read_balance(user_addr, gov_token) - before;
        assert!(delta > 0, error::out_of_range(E_NOTHING_TO_LOCK));

        let lock_amount = if (needs_wrap) {
            let from_store = primary_fungible_store::ensure_primary_store_exists(user_addr, gov_token);
            let native_fa = dispatchable_fungible_asset::withdraw(user, from_store, delta);
            let wrapped_fa = dao_wrapper::wrap_fa(native_fa);
            let actual_minted = fungible_asset::amount(&wrapped_fa);
            let to_store = primary_fungible_store::ensure_primary_store_exists(user_addr, target_token);
            dispatchable_fungible_asset::deposit(to_store, wrapped_fa);
            actual_minted
        } else {
            delta
        };

        let _nft_object = legacy::create_lock(user, dao_address, lock_amount, lock_epochs);
    }

    // Claims `amount` of `gov_token` paying with any FA in `path` and locks
    // the net result into a fresh veNFT for `lock_epochs`, atomically.
    //
    // `path` follows the amm_router standard, e.g. `[quote, gov]` or a
    // multi-hop route; it must start at the FA paying with and end at the
    // governance token.
    public entry fun buy_and_lock_fa(
        user: &signer,
        gov_token: Object<Metadata>,
        amount: u64,
        amount_out_min: u64,
        path: vector<address>,
        deadline: u64,
        lock_epochs: u64,
    ) {
        assert!(amount > 0, error::invalid_argument(E_ZERO_AMOUNT));
        let gov_addr = object::object_address(&gov_token);
        assert_path_ends_at(&path, gov_addr);
        assert!(
            vector::length(&path) >= 2,
            error::invalid_argument(E_INVALID_PATH)
        );
        let (dao_address, target_token, needs_wrap) = resolve_dao_and_token(gov_token);

        let user_addr = signer::address_of(user);
        let before = read_balance(user_addr, gov_token);

        amm_router::swap_exact_tokens_for_tokens(
            user,
            amount,
            amount_out_min,
            path,
            user_addr,
            deadline
        );

        let delta = read_balance(user_addr, gov_token) - before;
        assert!(delta > 0, error::out_of_range(E_NOTHING_TO_LOCK));

        let lock_amount = if (needs_wrap) {
            let from_store = primary_fungible_store::ensure_primary_store_exists(user_addr, gov_token);
            let native_fa = dispatchable_fungible_asset::withdraw(user, from_store, delta);
            let wrapped_fa = dao_wrapper::wrap_fa(native_fa);
            let actual_minted = fungible_asset::amount(&wrapped_fa);
            let to_store = primary_fungible_store::ensure_primary_store_exists(user_addr, target_token);
            dispatchable_fungible_asset::deposit(to_store, wrapped_fa);
            actual_minted
        } else {
            delta
        };

        let _nft_object = legacy::create_lock(user, dao_address, lock_amount, lock_epochs);
    }
}
