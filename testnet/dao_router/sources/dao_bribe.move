/// Bribe router - convenience entry point to deposit legacy Coins as bribes.
/// Withdraws the Coin, converts to paired FungibleAsset, and deposits via restore::deposit_bribe.
module dao_router::dao_bribe {
    use std::signer;
    use supra_framework::coin;
    use supra_framework::fungible_asset;
    use supra_framework::object;
    use supra_framework::primary_fungible_store;
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
        primary_fungible_store::deposit(depositor_addr, fa);
        restore::deposit_bribe(depositor, dao_address, pilgrim, gauge_id, token_addr, amount);
    }
}
