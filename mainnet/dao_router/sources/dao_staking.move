/// Staking router one door to turn a governance balance into a veNFT lock.
///
/// Unifies the former `legacy_boost_router::create_lock_entry` and
/// `coin_legacy_router::create_lock_from_coins`: the same intent (lock tokens)
/// for the two ways the governance token can be held.
///
/// Both entries take the GOVERNANCE TOKEN, never a DAO address: the owning
/// registry (`petra::get_dao_for_token`) is the single source of truth for
/// which DAO a token belongs to, so a caller can never lock against the wrong
/// DAO. This mirrors `dao_setup` and `dao_zap`.
module dao_router::dao_staking {
    use std::error;
    use std::option;
    use std::signer;
    use supra_framework::coin;
    use supra_framework::fungible_asset::Metadata;
    use supra_framework::primary_fungible_store;
    use supra_framework::object::{Self, Object};
    use dao_factory::petra;
    use dao_factory::legacy;

    const E_DAO_NOT_FOUND: u64 = 1;

    /// Resolves the DAO that owns `gov_token`, aborting when the token has no
    /// DAO yet (it must be activated before it can be locked).
    fun resolve_dao(gov_token: Object<Metadata>): address {
        let dao_opt = petra::get_dao_for_token(gov_token);
        if (option::is_some(&dao_opt)) {
            option::extract(&mut dao_opt)
        } else {
            abort error::not_found(E_DAO_NOT_FOUND)
        }
    }

    /// Creates a veNFT lock from the caller's FA (or already-wrapped) balance.
    ///
    /// Entry point for frontends/wallets. The returned `Object<VeToken>` is
    /// discarded because entry functions cannot return values.
    /// (Lives here rather than in `legacy` to keep the core package lean.)
    ///
    /// Every `legacy::create_lock` guard still applies: zero amount, MIN/MAX
    /// epochs, sentinel pause and blacklist.
    public entry fun create_lock(
        user: &signer,
        gov_token: Object<Metadata>,
        amount: u64,
        lock_epochs: u64,
    ) {
        let dao_address = resolve_dao(gov_token);
        let _nft_object = legacy::create_lock(user, dao_address, amount, lock_epochs);
    }

    /// Coin-native counterpart of `create_lock`: holders of the legacy Coin
    /// (not of the paired FA) can lock too.
    ///
    /// It withdraws the Coin, converts it to its paired FA, parks it in the
    /// caller's primary store and locks through the same `legacy::create_lock`
    /// (which withdraws from that primary store).
    ///
    /// `CoinType` must be the governance token's ORIGINAL coin type: for a DAO
    /// created via `dao_setup::create_dao_static_coin<CoinType>`, the paired FA
    /// IS the DAO's `token_metadata`, so `coin::coin_to_fungible_asset` yields
    /// exactly the asset `legacy::create_lock` expects.
    public entry fun create_lock_from_coins<CoinType>(
        user: &signer,
        amount: u64,
        lock_epochs: u64,
    ) {
        let user_addr = signer::address_of(user);

        // 1. Resolve the paired FA of this Coin it IS the governance token,
        //    so it also answers which DAO the lock belongs to.
        let gov_token = resolve_metadata<CoinType>();
        let dao_address = resolve_dao(gov_token);

        // 2. Pull the legacy Coin and convert it to its paired FA.
        let coin_in = coin::withdraw<CoinType>(user, amount);
        let fa = coin::coin_to_fungible_asset(coin_in);

        // 3. Park it in the caller's primary FA store: `create_lock` withdraws
        //    from `primary_fungible_store::primary_store(user, token_metadata)`.
        primary_fungible_store::deposit(user_addr, fa);

        // 4. Lock.
        let _nft_object = legacy::create_lock(user, dao_address, amount, lock_epochs);
    }

    /// Resolves a CoinType to its paired FA Metadata object.
    /// Falls back to @0x1 (native SupraCoin) when no paired metadata exists.
    fun resolve_metadata<CoinType>(): Object<Metadata> {
        let metadata_opt = coin::paired_metadata<CoinType>();
        if (option::is_some(&metadata_opt)) {
            option::extract(&mut metadata_opt)
        } else {
            // SupraCoin has no paired metadata object; use @0x1 as fallback.
            object::address_to_object<Metadata>(@0x1)
        }
    }
}
