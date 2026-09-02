module dao_factory::tax_router {
    friend dao_factory::legacy;
    friend dao_factory::harvest;
    friend dao_factory::restore;
    friend dao_factory::foundry;

    use std::error;
    use std::signer;
    use dao_tokens::smart_token;

    const E_NOT_STORE_OWNER: u64 = 1;

    struct TaxFreeRouter has key {
        cap: smart_token::TaxFreeCap,
    }

    public fun store_tax_free_cap(dao_signer: &signer, cap: smart_token::TaxFreeCap) {
        move_to(dao_signer, TaxFreeRouter { cap });
    }

    /// FIX (audit10 C3): true when the DAO has a TaxFreeRouter, i.e. its
    /// governance token is a launcher smart token whose TransferRef was
    /// exchanged for a cap during migration. Plain-FA DAOs (e.g. HOG, minted
    /// by hoglet_genesis without smart_token hooks) never have one and must
    /// use the normal dispatchable flow instead.
    public fun has_tax_free_router(dao_address: address): bool {
        exists<TaxFreeRouter>(dao_address)
    }

    /// Withdraws `amount` from `store` using the DAO's cap (bypasses the
    /// token's dispatch hooks).
    ///
    /// FIX (audit9 H-2) hardening: `authority` must OWN `store`. The cap
    /// alone can withdraw from ANY store of the DAO token, so without this
    /// check a buggy or malicious future friend module could drain third
    /// parties. Invariant for new call sites: only pass the signer of the
    /// store's owner (the tx user, or a protocol object via its ExtendRef).
    public(friend) fun withdraw_tax_free(
        dao_address: address,
        authority: &signer,
        store: supra_framework::object::Object<supra_framework::fungible_asset::FungibleStore>,
        amount: u64
    ): supra_framework::fungible_asset::FungibleAsset acquires TaxFreeRouter {
        assert!(
            supra_framework::object::owner(store) == signer::address_of(authority),
            error::permission_denied(E_NOT_STORE_OWNER)
        );
        let router = borrow_global<TaxFreeRouter>(dao_address);
        smart_token::withdraw_tax_free(&router.cap, store, amount)
    }

    /// FIX (audit10 C3): falls back to the normal dispatchable deposit when
    /// the DAO has no TaxFreeRouter. Deposits do not require the receiver's
    /// signature, so no extra authority is needed for the fallback. Plain-FA
    /// tokens have no dispatch hooks, so the result is equivalent.
    public(friend) fun deposit_tax_free(
        dao_address: address,
        store: supra_framework::object::Object<supra_framework::fungible_asset::FungibleStore>,
        fa: supra_framework::fungible_asset::FungibleAsset
    ) acquires TaxFreeRouter {
        if (exists<TaxFreeRouter>(dao_address)) {
            let router = borrow_global<TaxFreeRouter>(dao_address);
            smart_token::deposit_tax_free(&router.cap, store, fa);
        } else {
            supra_framework::fungible_asset::deposit(store, fa);
        };
    }
}
