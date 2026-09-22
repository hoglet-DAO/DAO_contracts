module dao_factory::fa_router {
    // ==================================================================
    // SETUP ROUTER one door to bring a token's STATIC governance alive.
    //
    // [UX] The caller passes ONLY the governance token address. The router
    // asks the LAUNCHER where the token was born (hoglet_core::
    // is_launcher_project zero bytes added to the saturated dao_factory
    // core) and routes:
    //
    //   * launcher-born (true) -> launcher meme path:
    //       hoglet_core::activate_delayed_dao enforces `pool::is_meme`
    //       + `hodl_fa::is_hodl_period_finished`, launcher-signs the
    //       creation, derives the frozen governance thresholds from the
    //       curve economics and charges the DAO creation fee. This is the
    //       ONLY route for those tokens (petra's direct static path
    //       rejects them via E_TOKEN_CLAIMED_BY_LAUNCHER).
    //
    //   * heritage / community FA (false) -> petra::create_dao_static
    //       fee-gated, one-DAO-per-token, born ACTIVE, no MintRef needed.
    //
    //   Both wrong-route attempts abort cleanly with NO state change:
    //       (a heritage token forced into the launcher path aborts on the
    //        meme gate), (a launcher-born token forced into the heritage
    //        path aborts on petra's claimed_tokens guard).
    //
    //   A token that already owns a DAO aborts early (one-DAO-per-token,
    //   checked via the existing petra view get_dao_for_token).
    //
    // [DESIGN] The launchpad-ownership question is answered by the module
    // that OWNS that knowledge (hoglet). Every rule still lives inside the
    // owning module (single source of truth, no duplicated guards). Future
    // setup-style functions can be added here as additional entries.
    //
    // [SCOPE] Static DAOs only. The inflationary track (DAO/zeal) is born
    // with its DAO at launch and never passes here (its tokens abort on
    // the early already-exists check or on the meme gate).
    //
    // [DEPENDENCY DAG] dao_router_v3 -> hoglet_core -> dao_factory; spike
    // never depends on this router (acyclic). dao_factory core stays
    // byte-neutral: zero additions to saturated petra.
    // ==================================================================
    use std::error;
    use std::option;
    use dao_factory::petra;
    use hoglet_core::hoglet_core;
    use supra_framework::object::{Self, Object};
    use supra_framework::fungible_asset::{Metadata};

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
}

