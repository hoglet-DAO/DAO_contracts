// Convenience proposal router for DAO governance proposals.
// Provides type-safe entry points for standard proposal creation,
// delegating execution to dao_factory::herald::propose_standard.
module dao_router::dao_proposals {
    use std::string::String;
    use std::vector;
    use std::error;
    use supra_framework::object;
    use supra_framework::coin;
    use supra_framework::fungible_asset::Metadata;
    use aptos_token_objects::token;
    use dao_factory::herald;
    use dao_factory::charter;
    use dao_factory::legacy;
    use dao_factory::jubilee;
    use dao_boost::boost_registry;
    use dao_scripts::library;

    // Errors
    const E_INVALID_CONFIG_KEY: u64 = 5;
    const E_NOT_INFLATIONARY: u64 = 6;
    const E_INVALID_ACTION_TYPE: u64 = 8;
    const E_INVALID_BOOST: u64 = 10;
    const E_SCRIPT_NOT_FOUND: u64 = 14;
    const E_NOT_AN_NFT: u64 = 17;
    const E_INVALID_TARGET: u64 = 18;
    const E_NOT_BLESSED: u64 = 19;
    const E_INVALID_ASSET: u64 = 20;
    const E_NO_PAIRED_FA: u64 = 21;

    public entry fun propose_treasury_transfer(
        proposer: &signer,
        legacy_addr: address,
        dao_address: address,
        title: String,
        description_hash: vector<u8>,
        asset_address: address,
        recipient: address,
        amount: u64,
    ) {
        // Native SUPRA is the FA metadata object @0xa (canonical form). The
        // legacy @0x1 sentinel is normalized here so every NEW proposal stores
        // @0xa, and any non-native asset must be a real FA metadata object.
        let asset = if (asset_address == @0x1) { @0xa } else { asset_address };
        assert!(object::object_exists<Metadata>(asset), error::invalid_argument(E_INVALID_ASSET));

        herald::propose_standard(
            proposer, legacy_addr, dao_address, title, description_hash, 1,
            vector::empty(), recipient, amount, 0, 0, asset, @0x0, asset
        );
    }

    /// Type-safe treasury transfer for Coin-Legacy assets (including native
    /// SUPRA): derives the paired FA Metadata address on-chain, so callers
    /// cannot pass a coin type or an arbitrary wrapper FA.
    public entry fun propose_treasury_transfer_coin<CoinType>(
        proposer: &signer,
        legacy_addr: address,
        dao_address: address,
        title: String,
        description_hash: vector<u8>,
        recipient: address,
        amount: u64,
    ) {
        let meta_opt = coin::paired_metadata<CoinType>();
        assert!(std::option::is_some(&meta_opt), error::invalid_argument(E_NO_PAIRED_FA));
        let asset = object::object_address(&std::option::destroy_some(meta_opt));

        herald::propose_standard(
            proposer, legacy_addr, dao_address, title, description_hash, 1,
            vector::empty(), recipient, amount, 0, 0, asset, @0x0, asset
        );
    }

    public entry fun propose_nft_transfer(
        proposer: &signer,
        legacy_addr: address,
        dao_address: address,
        title: String,
        description_hash: vector<u8>,
        nft_address: address,
        recipient: address,
    ) {
        assert!(nft_address != dao_address, error::invalid_argument(E_INVALID_TARGET));
        assert!(object::object_exists<token::Token>(nft_address), error::invalid_argument(E_NOT_AN_NFT));

        herald::propose_standard(
            proposer, legacy_addr, dao_address, title, description_hash, 5,
            vector::empty(), recipient, 1, 0, 0, nft_address, nft_address, @0x0
        );
    }

    public entry fun propose_config_change(
        proposer: &signer,
        legacy_addr: address,
        dao_address: address,
        title: String,
        description_hash: vector<u8>,
        config_key: u8,
        config_value: u64,
    ) {
        assert!(config_key <= 11 || (config_key >= 20 && config_key <= 27), error::invalid_argument(E_INVALID_CONFIG_KEY));
        if (config_key <= 8) {
            charter::validate_config_value(dao_address, config_key, config_value);
            if (config_key == 6) {
                let total_locked = legacy::get_total_locked(dao_address);
                if (total_locked > 0) {
                    assert!(config_value <= total_locked, error::invalid_argument(E_INVALID_CONFIG_KEY));
                };
            };
        } else if (config_key >= 9 && config_key <= 11) {
            assert!(charter::is_inflationary(dao_address), error::invalid_state(E_NOT_INFLATIONARY));
            jubilee::assert_valid_emission_param(dao_address, (config_key as u64), config_value);
        };

        herald::propose_standard(
            proposer, legacy_addr, dao_address, title, description_hash, 2,
            vector::empty(), @0x0, 0, config_key, config_value, @0x0, @0x0, @0x0
        );
    }

    public entry fun propose_guardian_update(
        proposer: &signer,
        legacy_addr: address,
        dao_address: address,
        title: String,
        description_hash: vector<u8>,
        new_guardian: address,
    ) {
        herald::propose_standard(
            proposer, legacy_addr, dao_address, title, description_hash, 4,
            vector::empty(), @0x0, 0, 0, 0, new_guardian, new_guardian, @0x0
        );
    }

    public entry fun propose_gauge_action(
        proposer: &signer,
        legacy_addr: address,
        dao_address: address,
        title: String,
        description_hash: vector<u8>,
        action_type: u8,
        target_address: address,
        gauge_id: u64,
    ) {
        assert!(charter::is_inflationary(dao_address), error::invalid_state(E_NOT_INFLATIONARY));

        herald::propose_standard(
            proposer, legacy_addr, dao_address, title, description_hash, 3,
            vector::empty(), @0x0, 0, action_type, gauge_id, target_address, target_address, @0x0
        );
    }

    public entry fun propose_module_setting(
        proposer: &signer,
        legacy_addr: address,
        dao_address: address,
        title: String,
        description_hash: vector<u8>,
        setting_type: u8,
        target_address: address,
        string_value: String,
        bool_value: bool,
    ) {
        assert!(setting_type <= 4, error::invalid_argument(E_INVALID_ACTION_TYPE));
        if (setting_type == 1) {
            assert!(charter::is_inflationary(dao_address), error::invalid_state(E_NOT_INFLATIONARY));
        };

        herald::propose_standard(
            proposer, legacy_addr, dao_address, title, description_hash, 6,
            *std::string::bytes(&string_value), @0x0, 0, setting_type, if (bool_value) 1 else 0,
            target_address, target_address, @0x0
        );
    }

    public entry fun propose_boost_action(
        proposer: &signer,
        legacy_addr: address,
        dao_address: address,
        title: String,
        description_hash: vector<u8>,
        action_type: u8,
        collection_addr: address,
        boost_bps: u64,
    ) {
        assert!(action_type <= 1, error::invalid_argument(E_INVALID_ACTION_TYPE));
        assert!(charter::is_inflationary(dao_address), error::invalid_state(E_NOT_INFLATIONARY));

        if (action_type == 0) {
            assert!(
                boost_bps > 0 && boost_bps <= boost_registry::hard_cap_bps(),
                error::invalid_argument(E_INVALID_BOOST)
            );
        };

        herald::propose_standard(
            proposer, legacy_addr, dao_address, title, description_hash, 7,
            vector::empty(), @0x0, 0, action_type, boost_bps, collection_addr, collection_addr, @0x0
        );
    }

    public entry fun propose_script_allow(
        proposer: &signer,
        legacy_addr: address,
        dao_address: address,
        title: String,
        description_hash: vector<u8>,
        script_id: u64,
        add: bool,
    ) {
        assert!(charter::is_blessed(dao_address), error::invalid_state(E_NOT_BLESSED));
        assert!(library::script_exists(script_id), error::invalid_argument(E_SCRIPT_NOT_FOUND));

        herald::propose_standard(
            proposer, legacy_addr, dao_address, title, description_hash, 9,
            vector::empty(), @0x0, script_id, 0, if (add) 1 else 0, @0x0, @0x0, @0x0
        );
    }
}
