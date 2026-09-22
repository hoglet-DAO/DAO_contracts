// ==================================================================
// ZAP BUY & LOCK ROUTER one door to buy governance tokens with any
// quote (native Coin or FA) and lock them into a veNFT, atomically.
//
// [UX] Standard ve-tokenomics one-click flow (Aerodrome/Velodrome
// "buy & lock", Convex-style zap). The caller passes the governance
// token + payment amount; the router:
//
//   1. resolves the token's OWNED DAO via petra::get_dao_for_token
//      (the module that owns that knowledge, same pattern as
//      fa_router::activate_dao);
//   2. snapshots the user's primary-store balance;
//   3. routes the payment through the PUBLISHED spike_amm router
//      (its own guards, fees and slippage rules apply — single
//      source of truth, no duplicated swap logic);
//   4. measures the balance DELTA — the honest amount bought,
//     immune to fee splits, excess-fill trims and dispatch tax
//     hooks, and never needs duplicated curve math;
//   5. locks that delta with legacy::create_lock (its own guards
//     apply: sentinel pause, blacklist, MIN/MAX epochs). Every
//     failure aborts the whole transaction: atomic.
//
// [SCOPE] Post-migration / heritage tokens only (DAO exists, token
// trades on the AMM). There is no pre-activation variant: before
// activate_delayed_dao no VeTokenRegistry exists, so create_lock
// would abort — buying during the curve stays in the frontend
// (GetTokenModal). Locking a token the user ALREADY holds is
// legacy_boost_router::create_lock_entry.
//
// [DEPENDENCY DAG] dao_router_v3 -> spike_amm (interface stub
// vendored at contracts/amm_interfaces, bound to the published AMM
// address) and -> dao_factory. spike_amm never depends on
// dao_factory (acyclic). dao_factory core stays byte-neutral.
//
// [BALANCE-DELTA SAFETY] read_balance returns 0 for owners without
// a primary store (first-time buyers). The delta guard rejects a
// non-positive net amount; create_lock's own zero-amount guard is
// the belt to this suspenders.
// ==================================================================
module dao_factory::zap_buy_lock_router {
    use std::error;
    use std::option;
    use std::vector;
    use dao_factory::petra;
    use dao_factory::legacy;
    use supra_framework::object::{Self, Object};
    use supra_framework::fungible_asset::Metadata;
    use supra_framework::primary_fungible_store;
    use spike_amm::amm_router;

    const E_DAO_NOT_FOUND: u64 = 1;
    const E_INVALID_PATH: u64 = 2;
    const E_ZERO_AMOUNT: u64 = 3;
    const E_NOTHING_TO_LOCK: u64 = 4;

    /// Owner's primary-store balance; 0 when no store exists yet
    /// (first-time buyers), so the delta captures the full deposit.
    inline fun read_balance(owner: address, token: Object<Metadata>): u64 {
        if (primary_fungible_store::primary_store_exists(owner, token)) {
            primary_fungible_store::balance(owner, token)
        } else {
            0u64
        }
    }

    /// The DAO that owns `gov_token` (the owning module's registry is
    /// the single source of truth; one-DAO-per-token).
    fun resolve_dao(gov_token: Object<Metadata>): address {
        let dao_opt = petra::get_dao_for_token(gov_token);
        if (option::is_some(&dao_opt)) {
            option::extract(&mut dao_opt)
        } else {
            abort error::not_found(E_DAO_NOT_FOUND)
        }
    }

    /// The route must END at the governance token: the last hop is
    /// always the buy leg. The frontend may add intermediate hops
    /// (e.g. via the wrapped SUPRA) to find the best route.
    inline fun assert_path_ends_at(path: &vector<address>, gov_addr: address) {
        assert!(
            !std::vector::is_empty(path)
                && *std::vector::borrow(path, std::vector::length(path) - 1) == gov_addr,
            error::invalid_argument(E_INVALID_PATH)
        );
    }

    /// Claims `amount` (or a later-funded portion) of `gov_token`
    /// with the Native Coin `CoinType` and locks the net result into
    /// a fresh veNFT for `lock_epochs`, atomically.
    ///
    /// `path` follows the amm_router convention; the wrapped-coin
    /// start is injected by the AMM router itself. Typically [gov].
    public entry fun zap_buy_and_lock_coin<CoinType>(
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
        let dao_address = resolve_dao(gov_token);

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
        let _nft_object = legacy::create_lock(user, dao_address, delta, lock_epochs);
    }

    /// Claims `amount` of `gov_token` paying with any FA in `path`
    /// and locks the net result into a fresh veNFT, atomically.
    ///
    /// `path` follows the amm_router standard, e.g. [quote, gov] or
    /// a multi-hop rabbit route; it must start at the FA paying with
    /// and end at the governance token.
    public entry fun zap_buy_and_lock_fa(
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
            std::vector::length(&path) >= 2,
            error::invalid_argument(E_INVALID_PATH)
        );
        let dao_address = resolve_dao(gov_token);

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
        let _nft_object = legacy::create_lock(user, dao_address, delta, lock_epochs);
    }
}
