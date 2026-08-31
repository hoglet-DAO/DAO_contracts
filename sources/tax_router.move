module dao_factory::tax_router {
    friend dao_factory::legacy;
    friend dao_factory::harvest;
    friend dao_factory::restore;
    friend dao_factory::foundry;

    use dao_tokens::smart_token;

    struct TaxFreeRouter has key {
        cap: smart_token::TaxFreeCap,
    }

    public fun store_tax_free_cap(dao_signer: &signer, cap: smart_token::TaxFreeCap) {
        move_to(dao_signer, TaxFreeRouter { cap });
    }

    public(friend) fun withdraw_tax_free(
        dao_address: address,
        store: supra_framework::object::Object<supra_framework::fungible_asset::FungibleStore>,
        amount: u64
    ): supra_framework::fungible_asset::FungibleAsset acquires TaxFreeRouter {
        let router = borrow_global<TaxFreeRouter>(dao_address);
        smart_token::withdraw_tax_free(&router.cap, store, amount)
    }

    public(friend) fun deposit_tax_free(
        dao_address: address,
        store: supra_framework::object::Object<supra_framework::fungible_asset::FungibleStore>,
        fa: supra_framework::fungible_asset::FungibleAsset
    ) acquires TaxFreeRouter {
        let router = borrow_global<TaxFreeRouter>(dao_address);
        smart_token::deposit_tax_free(&router.cap, store, fa);
    }
}
