// Coin-Legacy Router Module
//
// Provides entry points for users holding legacy Coin tokens (not Fungible Assets)
// to interact with the DAO ecosystem. Each function resolves the CoinType to its
// paired FA Metadata address and delegates to the core factory functions.
//
// (Moved out of dao_factory to save core package size.)
module dao_factory::coin_legacy_router {
    use supra_framework::coin;
    use supra_framework::fungible_asset::Metadata;
    use supra_framework::object::{Self, Object};
    use dao_factory::petra;

    /// Helper: Resolve a CoinType to its paired FA Metadata Object address.
    /// Falls back to @0x1 (native SupraCoin) if no paired metadata exists.
    fun resolve_metadata<CoinType>(): Object<Metadata> {
        let metadata_opt = coin::paired_metadata<CoinType>();
        if (std::option::is_some(&metadata_opt)) {
            std::option::extract(&mut metadata_opt)
        } else {
            // SupraCoin has no paired metadata object; use @0x1 as fallback
            object::address_to_object<Metadata>(@0x1)
        }
    }

    /// Creates a static DAO for a Coin-Legacy token.
    /// The user only needs to specify the CoinType — the router resolves
    /// the FA Metadata address automatically.
    public entry fun create_dao_static_coin<CoinType>(creator: &signer) {
        let governance_token = resolve_metadata<CoinType>();
        petra::create_dao_static(creator, governance_token);
    }
}
