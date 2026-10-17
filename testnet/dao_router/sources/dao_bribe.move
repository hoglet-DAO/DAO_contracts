// Bribe router - convenience entry point to deposit legacy Coins as bribes.
// Withdraws the Coin, converts to paired FungibleAsset, and deposits via restore::deposit_bribe.
module dao_router::dao_bribe {
    use std::signer;
    use supra_framework::coin;
    use supra_framework::fungible_asset;
    use supra_framework::object;
    use supra_framework::primary_fungible_store;
    use supra_framework::dispatchable_fungible_asset;
    use dao_factory::restore;

    public entry fun deposit_bribe_coin<CoinType>(
        depositor: &signer,
        dao_address: address,
        pilgrim: u64,
        gauge_id: u64,
        amount: u64,
    ) {
        let depositor_addr = signer::address_of(depositor);
        let coin = coin::withdraw<CoinType>(depositor, amount);
        let fa = coin::coin_to_fungible_asset(coin);
        let token_metadata = fungible_asset::asset_metadata(&fa);
        let token_addr = object::object_address(&token_metadata);
        let dest = primary_fungible_store::ensure_primary_store_exists(depositor_addr, token_metadata);
        let bal_before = primary_fungible_store::balance(depositor_addr, token_metadata);
        dispatchable_fungible_asset::deposit(dest, fa);
        let actual_amount = primary_fungible_store::balance(depositor_addr, token_metadata) - bal_before;
        restore::deposit_bribe(depositor, dao_address, pilgrim, gauge_id, token_addr, actual_amount);
    }
}
