/// Boost router one door to apply or release Gauge boosts that involve
/// legacy V1 NFTs.
///
/// Formerly `legacy_boost_router`. Handles the wrap/unwrap lifecycle so a
/// holder of V1 tokens gets the same 1-click UX as a 0x4-native holder:
/// the DAO's `foundry::apply_boost` only accepts 0x4 Tokens, so V1 collections
/// must be wrapped on the way in and unwrapped on the way out.
module dao_router::dao_boost {
    use std::signer;
    use std::string::String;
    use std::vector;
    use aptos_token::token as tokenv1;
    use aptos_token_objects::token::Token as TokenV2;
    use supra_framework::object;
    use dao_factory::foundry;
    use hoglet_wrap_v1_to_da::nft_wrapper;

    const E_VECTOR_LENGTH_MISMATCH: u64 = 1;
    const E_EMPTY_INPUT: u64 = 2;

    /// Wraps V1 NFTs into 0x4 Objects and immediately applies them for a Gauge
    /// boost, in one transaction.
    ///
    /// The four vectors are parallel: index `i` describes one V1 token. All
    /// lengths must match or the call aborts (no partial state  Move reverts
    /// the whole transaction).
    public entry fun wrap_and_boost(
        user: &signer,
        gauge_addr: address,
        creator_addresses: vector<address>,
        collection_names: vector<String>,
        token_names: vector<String>,
        property_versions: vector<u64>,
    ) {
        let len = vector::length(&creator_addresses);
        assert!(
            len == vector::length(&collection_names)
                && len == vector::length(&token_names)
                && len == vector::length(&property_versions),
            E_VECTOR_LENGTH_MISMATCH
        );
        assert!(len > 0, E_EMPTY_INPUT);

        let v2_addrs = vector::empty<address>();

        let i = 0;
        while (i < len) {
            let creator = *vector::borrow(&creator_addresses, i);
            let collection = *vector::borrow(&collection_names, i);
            let name = *vector::borrow(&token_names, i);
            let property_version = *vector::borrow(&property_versions, i);

            let token_id = tokenv1::create_token_id_raw(creator, collection, name, property_version);

            // Withdraw the V1 token struct from the user's account.
            let v1_token = tokenv1::withdraw_token(user, token_id, 1);

            // Lock V1 and mint the 0x4 Token via the wrapper.
            let v2_token_obj = nft_wrapper::wrap_v1_to_da(user, v1_token);

            vector::push_back(&mut v2_addrs, object::object_address(&v2_token_obj));
            i = i + 1;
        };

        // Apply the boost using the brand-new 0x4 Objects.
        foundry::apply_boost(user, gauge_addr, v2_addrs);
    }

    /// Releases a boost and unwraps every returned 0x4 Object back into its
    /// original V1 NFT.
    ///
    /// The escrowed set is read from the gauge itself
    /// (`foundry::get_user_boost_nfts`) immediately before releasing, so the
    /// unwrap can never drift from what `unboost` actually returns  including
    /// NFTs re-priced or auto-returned by `foundry::sync_boost`. Callers never
    /// supply the list, so it cannot be wrong.
    public entry fun unboost_and_unwrap(
        user: &signer,
        gauge_addr: address,
    ) {
        let user_addr = signer::address_of(user);

        // 1. Snapshot the exact set the gauge is holding for this user.
        let v2_addrs = foundry::get_user_boost_nfts(gauge_addr, user_addr);

        // 2. Release the boost: the gauge escrow returns those 0x4 Objects.
        foundry::unboost(user, gauge_addr);

        // 3. Unwrap each returned 0x4 Object back into its V1 token.
        let i = 0;
        let len = vector::length(&v2_addrs);
        while (i < len) {
            let v2_addr = *vector::borrow(&v2_addrs, i);
            let v2_token = object::address_to_object<TokenV2>(v2_addr);

            // Burn 0x4, get V1 back.
            let v1_token = nft_wrapper::unwrap_da_to_v1(user, v2_token);

            // Deposit V1 into the user's account.
            tokenv1::deposit_token(user, v1_token);

            i = i + 1;
        };
    }
}
