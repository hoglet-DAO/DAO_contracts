// Setup router - one door to bring a token's governance alive.
//
// Unifies the former `fa_router` and the DAO-creation half of
// `coin_legacy_router`: both answer the same question ("give this token a
// DAO") for the two ways a token can be held (FA metadata vs legacy Coin).
module dao_router::dao_setup {
    use std::error;
    use std::option;
    use std::signer;
    use dao_factory::petra;
    use hoglet_core::hoglet_core;
    use supra_framework::coin;
    use supra_framework::object::{Self, Object};
    use supra_framework::fungible_asset::{Self, Metadata};
    use supra_framework::event;
    use dao_router::dao_wrapper;

    const E_DAO_ALREADY_EXISTS: u64 = 1;

    #[event]
    struct StaticDaoActivated has drop, store {
        dao_address: address,
        native_token: address,
        governance_token: address,
        is_internal_wrapper: bool,
        creator: address,
    }

    // Activates (or creates) the STATIC DAO of `governance_token`.
    public entry fun activate_dao(
        user: &signer,
        governance_token: Object<Metadata>,
    ) {
        // Early clear-path: any token that already owns a DAO must not pass.
        if (option::is_some(&petra::get_dao_for_token(governance_token))) {
            abort error::already_exists(E_DAO_ALREADY_EXISTS)
        };
        if (dao_wrapper::is_wrapper_registered_for_native(governance_token)) {
            let wrapped = dao_wrapper::get_wrapper_for_fa(governance_token);
            if (option::is_some(&petra::get_dao_for_token(wrapped))) {
                abort error::already_exists(E_DAO_ALREADY_EXISTS)
            };
        };

        if (hoglet_core::is_launcher_project(object::object_address(&governance_token))) {
            // Launcher-born: only its own gate (meme + HODL finished) authorizes the hand-over.
            let token_address = object::object_address(&governance_token);
            hoglet_core::activate_delayed_dao(user, token_address);
        } else {
            // Check if governance_token has custom dispatch hooks (third-party / competitor tokens)
            let probe_constr = object::create_object_from_account(user);
            let probe_store = fungible_asset::create_store(&probe_constr, governance_token);
            let is_dispatchable = fungible_asset::is_store_dispatchable(probe_store);

            let (gov_token_used, is_internal_wrapper) = if (is_dispatchable) {
                // Auto-wrap into clean governance FA:
                let wrapped_token = dao_wrapper::create_fungible_asset_for_fa(governance_token);
                if (option::is_some(&petra::get_dao_for_token(wrapped_token))) {
                    abort error::already_exists(E_DAO_ALREADY_EXISTS)
                };
                petra::create_dao_static_for_wrapper(user, wrapped_token, governance_token);
                (wrapped_token, true)
            } else {
                // Heritage / Clean FA: direct petra static door
                petra::create_dao_static(user, governance_token);
                (governance_token, false)
            };

            let dao_opt = petra::get_dao_for_token(gov_token_used);
            let dao_address = if (option::is_some(&dao_opt)) {
                option::extract(&mut dao_opt)
            } else {
                @0x0
            };

            event::emit(StaticDaoActivated {
                dao_address,
                native_token: object::object_address(&governance_token),
                governance_token: object::object_address(&gov_token_used),
                is_internal_wrapper,
                creator: signer::address_of(user),
            });
        };
    }

    // Coin-native counterpart of `activate_dao`: the caller passes only the
    // legacy `CoinType` and the router resolves its paired FA metadata.
    public entry fun create_dao_static_coin<CoinType>(creator: &signer) {
        let governance_token = resolve_metadata<CoinType>();
        petra::create_dao_static(creator, governance_token);

        let dao_opt = petra::get_dao_for_token(governance_token);
        let dao_address = if (option::is_some(&dao_opt)) {
            option::extract(&mut dao_opt)
        } else {
            @0x0
        };

        event::emit(StaticDaoActivated {
            dao_address,
            native_token: object::object_address(&governance_token),
            governance_token: object::object_address(&governance_token),
            is_internal_wrapper: false,
            creator: signer::address_of(creator),
        });
    }

    // Resolves a CoinType to its paired FA Metadata object.
    // Falls back to @0xa (native SupraCoin FA metadata) when no paired metadata exists (FIX L-04).
    public fun resolve_metadata<CoinType>(): Object<Metadata> {
        let metadata_opt = coin::paired_metadata<CoinType>();
        if (option::is_some(&metadata_opt)) {
            option::extract(&mut metadata_opt)
        } else {
            // SupraCoin native FA metadata object resides at @0xa (FIX L-04)
            object::address_to_object<Metadata>(@0xa)
        }
    }
}
