module dao_factory::hoglet_genesis {
    use std::signer;
    use std::string;
    use std::option;
    use supra_framework::object::{Self};
    use supra_framework::fungible_asset::{Self, Metadata};
    use supra_framework::primary_fungible_store;
    use dao_factory::petra;

    // Constants for Hoglet Token
    const TOKEN_NAME: vector<u8> = b"Hoglet DAOs"; 
    const TOKEN_SYMBOL: vector<u8> = b"HOG";
    const TOKEN_DECIMALS: u8 = 3;
    const INITIAL_SUPPLY: u64 = 13_700_000_000_000_000; 
    const TOKEN_URI: vector<u8> = b"ipfs://bafkreig3pnks7kgrk4b4p5kmifajh74hd6ne7wopsd65hk4osxgz2ovj2i";
    const PROJECT_URI: vector<u8> = b"https://www.hoglet.xyz";

    // This runs automatically when the dao_factory package is deployed.
    // It creates the Hoglet token, creates the DAO, and transfers admin rights.
    fun init_module(admin: &signer) {
        // 1. Create Hoglet Token (Fungible Asset)
        let constructor_ref = object::create_named_object(admin, b"HOGLET_TOKEN_SEED");
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor_ref,
            option::none(),
            string::utf8(TOKEN_NAME),
            string::utf8(TOKEN_SYMBOL),
            TOKEN_DECIMALS,
            string::utf8(TOKEN_URI),
            string::utf8(PROJECT_URI)
        );
        let mint_ref = fungible_asset::generate_mint_ref(&constructor_ref);
        let metadata_object = object::object_from_constructor_ref<Metadata>(&constructor_ref);

        // 2. Mint initial supply directly to the deployer's wallet
        let coins = fungible_asset::mint(&mint_ref, INITIAL_SUPPLY);
        primary_fungible_store::deposit(signer::address_of(admin), coins);

        // 3. Temporarily inject Formula 137 into the Factory config
        petra::set_default_initial_emission_ppm(admin, 2734); // 2734 PPM = 0.2734% = 37.45 Trillions
        petra::set_default_decay_bps(admin, 100); // 1% weekly decay
        petra::set_default_tail_emission_ppm(admin, 10); // 10 PPM = 0.001% = 137 Billions perpetual

        // 4. Create the Inflationary DAO via Factory
        let dao_address = petra::create_dao_inflationary(admin, metadata_object, mint_ref);

        // 5. Revert the Factory to the 137-themed defaults for everyone else
        petra::set_default_initial_emission_ppm(admin, 13700); // 1.37%
        petra::set_default_decay_bps(admin, 137); // 1.37% decay
        petra::set_default_tail_emission_ppm(admin, 137); // 0.0137%

        // 6. Complete Ouroboros: Transfer Factory admin rights to the Hoglet DAO
        //petra::transfer_admin(admin, dao_address);
    }
}
