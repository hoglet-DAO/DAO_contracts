/// Setup router  one door to bring a token's governance alive.
///
/// Unifies the former `fa_router` and the DAO-creation half of
/// `coin_legacy_router`: both answer the same question ("give this token a
/// DAO") for the two ways a token can be held (FA metadata vs legacy Coin).
module dao_router::dao_setup {
    // ==================================================================
    // [UX] The caller passes ONLY the governance token. The router asks the
    // LAUNCHER where the token was born and routes:
    //
    //   * launcher-born -> launcher meme path:
    //       `hoglet_core::activate_delayed_dao` enforces `pool::is_meme`
    //       + `hodl_fa::is_hodl_period_finished`, launcher-signs the
    //       creation, derives the frozen governance thresholds from the
    //       curve economics and charges the DAO creation fee. This is the
    //       ONLY route for those tokens (petra's direct static path
    //       rejects them via E_TOKEN_CLAIMED_BY_LAUNCHER).
    //
    //   * heritage / community FA -> `petra::create_dao_static`
    //       fee-gated, one-DAO-per-token, born ACTIVE, no MintRef needed.
    //
    //   Both wrong-route attempts abort cleanly with NO state change:
    //       (a) a heritage token forced into the launcher path aborts on the
    //       meme gate; (b) a launcher-born token forced into the heritage
    //       path aborts on petra's claimed_tokens guard.
    //
    //   A token that already owns a DAO aborts early (one-DAO-per-token,
    //   checked via the existing petra view get_dao_for_token).
    //
    // [COIN VARIANT] `create_dao_static_coin` resolves the legacy CoinType to
    //   its paired FA metadata and delegates to the same `petra` door, so
    //   Coin and FA holders share one single implementation.
    //
    // [SCOPE] Static DAOs only. The inflationary track (DAO/zeal) is born
    //   with its DAO at launch and never passes here (its tokens abort on
    //   the early already-exists check or on the meme gate).
    //
    // [DEPENDENCY DAG] dao_router_v3 -> hoglet_core -> dao_factory; spike
    //   never depends on this router (acyclic). dao_factory core stays
    //   byte-neutral: zero additions to saturated petra.
    // ==================================================================
    use std::error;
    use std::option;
    use dao_factory::petra;
    use hoglet_core::hoglet_core;
    use supra_framework::coin;
    use supra_framework::object::{Self, Object};
    use supra_framework::fungible_asset::Metadata;

    const E_DAO_ALREADY_EXISTS: u64 = 1;

    /// Activates (or creates) the STATIC DAO of `governance_token`.
    ///
    /// Both branches charge the DAO creation fee in SUPRA to `user`, who
    /// is recorded as the DAO creator.
    public entry fun activate_dao(
        user: &signer,
        governance_token: Object<Metadata>,
    ) {
        // Early clear-path: any token that already owns a DAO (launcher DAO
        // track, or a previously activated meme/heritage DAO) must not pass.
        if (option::is_some(&petra::get_dao_for_token(governance_token))) {
            abort error::already_exists(E_DAO_ALREADY_EXISTS)
        };

        if (hoglet_core::is_launcher_project(object::object_address(&governance_token))) {
            // Launcher-born: only its own gate (meme + HODL finished)
            // authorizes the hand-over.
            let token_address = object::object_address(&governance_token);
            hoglet_core::activate_delayed_dao(user, token_address);
        } else {
            // Heritage FA: petra's static door (its own guards apply:
            // creation fee, one-per-token, claimed-tokens rejection).
            petra::create_dao_static(user, governance_token);
        };
    }

    /// Coin-native counterpart of `activate_dao`: the caller passes only the
    /// legacy `CoinType` and the router resolves its paired FA metadata.
    ///
    /// For a token created through this entry, the paired FA IS the DAO's
    /// `token_metadata`, which is what the rest of the stack locks against.
    public entry fun create_dao_static_coin<CoinType>(creator: &signer) {
        let governance_token = resolve_metadata<CoinType>();
        petra::create_dao_static(creator, governance_token);
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
