module dao_factory::legacy_boost_router {
    use std::string::String;
    use aptos_token::token as tokenv1;
    use aptos_token_objects::token::Token as TokenV2;
    use supra_framework::object;
    use dao_factory::foundry;
    use dao_factory::legacy;
    use hoglet_wrap_v1_to_da::nft_wrapper;

    /// Entry point for Frontend/Wallets to create a lock.
    /// Discards the returned Object<VeToken> since entry functions cannot return values.
    /// (Moved out of dao_factory::legacy to save core package size.)
    public entry fun create_lock_entry(
        user: &signer,
        dao_address: address,
        amount: u64,
        lock_epochs: u64,
    ) {
        let _nft_object = legacy::create_lock(user, dao_address, amount, lock_epochs);
    }

    /// Wraps V1 NFTs into V2 Objects and immediately applies them for a Gauge Boost.
    /// This provides a seamless 1-click UX for users with legacy NFTs.
    public entry fun wrap_and_boost(
        user: &signer,
        gauge_addr: address,
        creator_addresses: vector<address>,
        collection_names: vector<String>,
        token_names: vector<String>,
        property_versions: vector<u64>,
    ) {
        let len = std::vector::length(&creator_addresses);
        assert!(len == std::vector::length(&collection_names), 1);
        assert!(len == std::vector::length(&token_names), 1);
        assert!(len == std::vector::length(&property_versions), 1);

        let i = 0;
        let v2_addrs = std::vector::empty<address>();

        // Wrap all V1 tokens one by one
        while (i < len) {
            let creator = *std::vector::borrow(&creator_addresses, i);
            let collection = *std::vector::borrow(&collection_names, i);
            let name = *std::vector::borrow(&token_names, i);
            let property_version = *std::vector::borrow(&property_versions, i);

            let token_id = tokenv1::create_token_id_raw(creator, collection, name, property_version);
            
            // Withdraw V1 token struct from user's account
            let v1_token = tokenv1::withdraw_token(user, token_id, 1);
            
            // Lock V1 and Mint V2 via wrapper
            let v2_token_obj = nft_wrapper::wrap_v1_to_da(user, v1_token);
            
            std::vector::push_back(&mut v2_addrs, object::object_address(&v2_token_obj));
            i = i + 1;
        };

        // Apply boost inside the gauge using the brand new V2 Objects
        foundry::apply_boost(user, gauge_addr, v2_addrs);
    }

    /// Unboosts from the Gauge (which returns the V2 Objects to the user)
    /// and immediately unwraps them back into the original V1 NFTs.
    public entry fun unboost_and_unwrap(
        user: &signer,
        gauge_addr: address,
        v2_addrs: vector<address>
    ) {
        // 1. Withdraw the V2 Objects from the Gauge Escrow
        foundry::unboost(user, gauge_addr);

        let i = 0;
        let len = std::vector::length(&v2_addrs);

        // 2. Unwrap all V2 Objects and return V1 tokens to user's TokenStore
        while (i < len) {
            let v2_addr = *std::vector::borrow(&v2_addrs, i);
            let v2_token = object::address_to_object<TokenV2>(v2_addr);
            
            // Burn V2, get V1
            let v1_token = nft_wrapper::unwrap_da_to_v1(user, v2_token);
            
            // Deposit V1 back into user's account
            tokenv1::deposit_token(user, v1_token);
            
            i = i + 1;
        };
    }
}
