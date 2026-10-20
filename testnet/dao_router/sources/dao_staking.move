// Staking router one door to turn a governance balance into a veNFT lock.
//
// Unifies the former `legacy_boost_router::create_lock_entry` and
// `coin_legacy_router::create_lock_from_coins`: the same intent (lock tokens)
// for the two ways the governance token can be held.
//
// Both entries take the GOVERNANCE TOKEN, never a DAO address: the owning
// registry (`petra::get_dao_for_token`) is the single source of truth for
// which DAO a token belongs to, so a caller can never lock against the wrong
// DAO. This mirrors `dao_setup` and `dao_zap`.
//
// Includes seamless auto-wrapping for tokens with transfer fees/hooks (third-party meme tokens)
// and 1-click withdraw-and-unwrap support.
module dao_router::dao_staking {
    use std::error;
    use std::option;
    use std::signer;
    use supra_framework::coin;
    use supra_framework::supra_coin::SupraCoin;
    use aptos_std::type_info;
    use supra_framework::fungible_asset::{Self, Metadata};
    use supra_framework::primary_fungible_store;
    use supra_framework::dispatchable_fungible_asset;
    use supra_framework::object::{Self, Object};
    use dao_factory::petra;
    use dao_factory::legacy;
    use dao_router::dao_wrapper;

    const E_DAO_NOT_FOUND: u64 = 1;

    // Resolves the DAO and tokens for staking:
    // Returns (dao_address, source_token_to_withdraw, target_token_for_legacy, needs_wrap)
    fun resolve_dao_and_tokens(
        user_addr: address,
        token_input: Object<Metadata>,
        amount: u64
    ): (address, Object<Metadata>, Object<Metadata>, bool) {
        if (dao_wrapper::is_wrapper_registered_for_native(token_input)) {
            // Case 1: Caller provided the native token of a wrapped DAO
            let wrapped_meta = dao_wrapper::get_wrapper_for_fa(token_input);
            let dao_opt = petra::get_dao_for_token(wrapped_meta);
            if (option::is_some(&dao_opt)) {
                (option::extract(&mut dao_opt), token_input, wrapped_meta, true)
            } else {
                abort error::not_found(E_DAO_NOT_FOUND)
            }
        } else if (dao_wrapper::is_wrapper_fa(token_input)) {
            // Case 2: Caller provided the wrapper token (gwTOKEN)
            let dao_opt = petra::get_dao_for_token(token_input);
            if (option::is_none(&dao_opt)) {
                abort error::not_found(E_DAO_NOT_FOUND)
            };
            let dao_addr = option::extract(&mut dao_opt);

            // Check if user already holds enough wrapped tokens in primary store
            let user_wrapped_bal = if (primary_fungible_store::primary_store_exists(user_addr, token_input)) {
                primary_fungible_store::balance(user_addr, token_input)
            } else {
                0
            };
            if (user_wrapped_bal >= amount) {
                // User already holds wrapped tokens, no auto-wrap needed
                (dao_addr, token_input, token_input, false)
            } else {
                // User holds native tokens, auto-wrap from native!
                let native_meta = dao_wrapper::get_original_fa(token_input);
                (dao_addr, native_meta, token_input, true)
            }
        } else {
            // Case 3: Standard clean FA or launcher token
            let dao_opt = petra::get_dao_for_token(token_input);
            if (option::is_some(&dao_opt)) {
                (option::extract(&mut dao_opt), token_input, token_input, false)
            } else {
                abort error::not_found(E_DAO_NOT_FOUND)
            }
        }
    }

    // Resolves the DAO that owns `gov_token`, aborting when the token has no
    // DAO yet (it must be activated before it can be locked).
    fun resolve_dao(gov_token: Object<Metadata>): address {
        if (dao_wrapper::is_wrapper_registered_for_native(gov_token)) {
            let wrapped_meta = dao_wrapper::get_wrapper_for_fa(gov_token);
            let dao_opt = petra::get_dao_for_token(wrapped_meta);
            if (option::is_some(&dao_opt)) {
                option::extract(&mut dao_opt)
            } else {
                abort error::not_found(E_DAO_NOT_FOUND)
            }
        } else {
            let dao_opt = petra::get_dao_for_token(gov_token);
            if (option::is_some(&dao_opt)) {
                option::extract(&mut dao_opt)
            } else {
                abort error::not_found(E_DAO_NOT_FOUND)
            }
        }
    }

    // Universal view function for frontend: resolves the DAO address from either the
    // native token address OR the wrapped governance token address seamlessly.
    #[view]
    public fun get_dao_for_token(gov_token: Object<Metadata>): option::Option<address> {
        let dao_opt = petra::get_dao_for_token(gov_token);
        if (option::is_some(&dao_opt)) {
            dao_opt
        } else if (dao_wrapper::is_wrapper_registered_for_native(gov_token)) {
            let wrapped_meta = dao_wrapper::get_wrapper_for_fa(gov_token);
            petra::get_dao_for_token(wrapped_meta)
        } else {
            option::none()
        }
    }

    // Creates a veNFT lock from the caller's FA (or already-wrapped) balance.
    // If `gov_token` is a native third-party token wrapped for governance,
    // auto-wraps into `gwTOKEN` by delta and locks into legacy.
    public entry fun create_lock(
        user: &signer,
        gov_token: Object<Metadata>,
        amount: u64,
        lock_epochs: u64,
    ) {
        let user_addr = signer::address_of(user);
        let (dao_address, source_token, target_token, needs_wrap) = resolve_dao_and_tokens(user_addr, gov_token, amount);

        let lock_amount = if (needs_wrap) {
            let from_store = primary_fungible_store::ensure_primary_store_exists(user_addr, source_token);
            let native_fa = dispatchable_fungible_asset::withdraw(user, from_store, amount);
            let wrapped_fa = dao_wrapper::wrap_fa(native_fa);
            let actual_minted = fungible_asset::amount(&wrapped_fa);
            let to_store = primary_fungible_store::ensure_primary_store_exists(user_addr, target_token);
            dispatchable_fungible_asset::deposit(to_store, wrapped_fa);
            actual_minted
        } else {
            amount
        };

        let _nft_object = legacy::create_lock(user, dao_address, lock_amount, lock_epochs);
    }

    // Unified increase lock amount: if the DAO uses wrapped FA, auto-wraps native tokens.
    // If it's a standard token, directly deposits into the lock. Works for all DAOs.
    public entry fun increase_lock_amount(
        user: &signer,
        legacy_addr: address,
        amount: u64,
    ) {
        let user_addr = signer::address_of(user);
        let dao_address = legacy::get_dao_address(object::address_to_object(legacy_addr));
        let token_metadata_addr = legacy::get_token_metadata_address(dao_address);
        let token_metadata = object::address_to_object<Metadata>(token_metadata_addr);

        if (dao_wrapper::is_wrapper_fa(token_metadata)) {
            let native_metadata = dao_wrapper::get_original_fa(token_metadata);
            let from_store = primary_fungible_store::ensure_primary_store_exists(user_addr, native_metadata);
            let native_fa = dispatchable_fungible_asset::withdraw(user, from_store, amount);
            let wrapped_fa = dao_wrapper::wrap_fa(native_fa);
            let actual_minted = fungible_asset::amount(&wrapped_fa);
            let to_store = primary_fungible_store::ensure_primary_store_exists(user_addr, token_metadata);
            dispatchable_fungible_asset::deposit(to_store, wrapped_fa);

            legacy::increase_amount(user, legacy_addr, actual_minted);
        } else {
            legacy::increase_amount(user, legacy_addr, amount);
        };
    }

    public entry fun increase_lock_amount_from_native(
        user: &signer,
        legacy_addr: address,
        native_amount: u64,
    ) {
        increase_lock_amount(user, legacy_addr, native_amount);
    }

    // Withdraws from expired veNFT and unwraps the tokens to native in 1 atomic transaction.
    // If the DAO token is wrapped, returns the underlying native token to the user.
    // Works for all DAOs (leaves standard tokens in user wallet).
    public entry fun withdraw_and_unwrap(
        user: &signer,
        legacy_addr: address,
    ) {
        let user_addr = signer::address_of(user);
        let dao_address = legacy::get_dao_address(object::address_to_object(legacy_addr));
        let token_metadata_addr = legacy::get_token_metadata_address(dao_address);
        let token_metadata = object::address_to_object<Metadata>(token_metadata_addr);

        let bal_before = if (primary_fungible_store::primary_store_exists(user_addr, token_metadata)) {
            primary_fungible_store::balance(user_addr, token_metadata)
        } else {
            0
        };
        legacy::withdraw(user, legacy_addr);
        let bal_after = primary_fungible_store::balance(user_addr, token_metadata);
        let withdrawn_amount = bal_after - bal_before;

        if (dao_wrapper::is_wrapper_fa(token_metadata) && withdrawn_amount > 0) {
            let user_wrapped_store = primary_fungible_store::ensure_primary_store_exists(user_addr, token_metadata);
            let wrapped_fa = dispatchable_fungible_asset::withdraw(user, user_wrapped_store, withdrawn_amount);
            let native_fa = dao_wrapper::unwrap_fa(wrapped_fa);
            let native_metadata = fungible_asset::asset_metadata(&native_fa);
            let native_store = primary_fungible_store::ensure_primary_store_exists(user_addr, native_metadata);
            dispatchable_fungible_asset::deposit(native_store, native_fa);
        };
    }

    // Coin-native counterpart of `create_lock`: holders of the legacy Coin
    // (not of the paired FA) can lock too.
    //
    // It withdraws the Coin, converts it to its paired FA, parks it in the
    // caller's primary store and locks through the same `legacy::create_lock`
    // (which withdraws from that primary store).
    //
    // `CoinType` must be the governance token's ORIGINAL coin type: for a DAO
    // created via `dao_setup::create_dao_static_coin<CoinType>`, the paired FA
    // IS the DAO's `token_metadata`, so `coin::coin_to_fungible_asset` yields
    // exactly the asset `legacy::create_lock` expects.
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
        let token_meta = fungible_asset::asset_metadata(&fa);
        let dest = primary_fungible_store::ensure_primary_store_exists(user_addr, token_meta);
        let bal_before = primary_fungible_store::balance(user_addr, token_meta);
        dispatchable_fungible_asset::deposit(dest, fa);
        let actual_amount = primary_fungible_store::balance(user_addr, token_meta) - bal_before;

        // 4. Lock.
        let _nft_object = legacy::create_lock(user, dao_address, actual_amount, lock_epochs);
    }

    // Resolves a CoinType to its paired FA Metadata object.
    // Falls back to @0xa (native SupraCoin FA metadata) when no paired metadata exists (FIX L-04).
    fun resolve_metadata<CoinType>(): Object<Metadata> {
        let metadata_opt = coin::paired_metadata<CoinType>();
        if (option::is_some(&metadata_opt)) {
            option::extract(&mut metadata_opt)
        } else {
            assert!(
                type_info::type_of<CoinType>() == type_info::type_of<SupraCoin>(),
                error::invalid_argument(1)
            );
            // SupraCoin native FA metadata object resides at @0xa (FIX L-04)
            object::address_to_object<Metadata>(@0xa)
        }
    }
}
