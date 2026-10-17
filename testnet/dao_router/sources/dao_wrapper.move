// Sovereign Governance Wrapper Module for Hoglet DAO
//
// Provides safe, delta-based wrapping of third-party dispatchable fungible assets
// (tokens with transfer fees, hooks, or external programmability).
// Produces 1:1 clean, standard Fungible Assets (gwTOKEN) for permissionless,
// un-exploitable governance in DAO Factory.
//
// Clones the icon, decimals and project URI of the native token, with AMM-style
// "gw" symbol prefix and "Wrapped " name prefix with strict character-overflow
// truncation to prevent any framework aborts.
//
// Governed under the Friend pattern:
// - Creation of wrappers is restricted to `dao_setup` (only created when activating a DAO).
// - Wrapping is restricted to `dao_staking` and `dao_zap` (only wrapped when locking into veNFT).
// - Unwrapping is open to anyone holding wrapped tokens to guarantee redemption rights.
// - Flash Loans are open to external routers via the Hot Potato standard (`FlashLoanReceiptFA`).
module dao_router::dao_wrapper {
    friend dao_router::dao_setup;
    friend dao_router::dao_staking;
    friend dao_router::dao_zap;

    use supra_framework::account::{Self, SignerCapability};
    use supra_framework::fungible_asset::{Self, BurnRef, FungibleAsset, Metadata, MintRef};
    use supra_framework::object::{Self, Object};
    use supra_framework::primary_fungible_store;
    use supra_framework::dispatchable_fungible_asset;
    use supra_framework::event;

    use aptos_std::smart_table::{Self, SmartTable};
    use std::string;
    use std::option;
    use std::signer;
    use std::error;
    use std::bcs;

    const WRAPPER_SEED: vector<u8> = b"HOGLET_DAO_GOV_WRAPPER";

    // Errors
    const ERROR_INSUFFICIENT_AMOUNT: u64 = 101;
    const ERROR_INVALID_REPAYMENT: u64 = 102;
    const ERROR_NOT_ADMIN: u64 = 103;
    const ERROR_ALREADY_WRAPPED: u64 = 104;
    const ERROR_ZERO_DEPOSIT: u64 = 105;

    // Default 5 bps flash loan fee (0.05%)
    const DEFAULT_FLASH_LOAN_FEE_BPS: u64 = 5;

    struct WrappedAssetData has store {
        metadata: Object<Metadata>,
        mint_ref: MintRef,
        burn_ref: BurnRef,
    }

    struct WrapperRegistry has key {
        wrapper_address: address,
        signer_cap: SignerCapability,
        admin: address,
        fee_bps: u64,
        fee_receiver: address,
        native_to_wrapper: SmartTable<Object<Metadata>, WrappedAssetData>,
        wrapper_to_native: SmartTable<Object<Metadata>, Object<Metadata>>,
    }

    /// Hot Potato receipt for Flash Loans (no abilities: no drop, no store, no copy, no key)
    struct FlashLoanReceiptFA {
        amount: u64,
        fee: u64,
        metadata: Object<Metadata>,
    }

    #[event]
    struct FlashLoanFAEvent has drop, store {
        amount: u64,
        fee_amount: u64,
        metadata: Object<Metadata>,
    }

    #[event]
    struct WrapperCreated has drop, store {
        native_metadata: address,
        wrapper_metadata: address,
    }

    #[event]
    struct AssetWrapped has drop, store {
        native_metadata: address,
        wrapper_metadata: address,
        amount_native_deposited: u64,
        amount_wrapped_minted: u64,
        recipient: address,
    }

    #[event]
    struct AssetUnwrapped has drop, store {
        wrapper_metadata: address,
        native_metadata: address,
        amount_wrapped_burned: u64,
        amount_native_withdrawn: u64,
        recipient: address,
    }

    // Initialization
    fun init_module(router_signer: &signer) {
        if (exists<WrapperRegistry>(@dao_router)) {
            return
        };

        let (wrapper_signer, signer_cap) = account::create_resource_account(router_signer, WRAPPER_SEED);
        let wrapper_address = signer::address_of(&wrapper_signer);

        move_to(router_signer, WrapperRegistry {
            wrapper_address,
            signer_cap,
            admin: @HOGL,
            fee_bps: DEFAULT_FLASH_LOAN_FEE_BPS,
            fee_receiver: @HOGL,
            native_to_wrapper: smart_table::new(),
            wrapper_to_native: smart_table::new(),
        });
    }

    public entry fun initialize(admin: &signer) {
        let admin_addr = signer::address_of(admin);
        assert!(admin_addr == @HOGL, error::permission_denied(ERROR_NOT_ADMIN));
        if (!exists<WrapperRegistry>(@dao_router)) {
            let (wrapper_signer, signer_cap) = account::create_resource_account(admin, WRAPPER_SEED);
            let wrapper_address = signer::address_of(&wrapper_signer);

            move_to(admin, WrapperRegistry {
                wrapper_address,
                signer_cap,
                admin: @HOGL,
                fee_bps: DEFAULT_FLASH_LOAN_FEE_BPS,
                fee_receiver: @HOGL,
                native_to_wrapper: smart_table::new(),
                wrapper_to_native: smart_table::new(),
            });
        };
    }

    // Wrapper creation restricted to friends (dao_setup)
    // Produces a clean 1:1 governance wrapper with AMM-style short prefix (gw + Wrapped )
    // Clones decimals, icon, and project URI, with strict framework character-overflow truncation.
    public(friend) fun create_fungible_asset_for_fa(native_metadata: Object<Metadata>): Object<Metadata> acquires WrapperRegistry {
        assert!(!is_wrapper_fa(native_metadata), error::invalid_argument(ERROR_ALREADY_WRAPPED));
        let registry = borrow_global_mut<WrapperRegistry>(@dao_router);
        
        if (!smart_table::contains(&registry.native_to_wrapper, native_metadata)) {
            let symbol = fungible_asset::symbol(native_metadata);
            let name = fungible_asset::name(native_metadata);
            let decimals = fungible_asset::decimals(native_metadata);
            let icon_uri = fungible_asset::icon_uri(native_metadata);
            let project_uri = fungible_asset::project_uri(native_metadata);

            // Safe AMM-style naming with strict overflow protection:
            // "Wrapped " is 8 chars, max native name allowed = 32 - 8 = 24 chars
            let mut_name = string::utf8(b"Wrapped ");
            if (string::length(&name) > 24) {
                name = string::sub_string(&name, 0, 24);
            };
            string::append(&mut mut_name, name);

            // "gw" is 2 chars, max native symbol allowed = 10 - 2 = 8 chars
            let mut_symbol = string::utf8(b"gw");
            if (string::length(&symbol) > 8) {
                symbol = string::sub_string(&symbol, 0, 8);
            };
            string::append(&mut mut_symbol, symbol);

            let wrapper_signer = account::create_signer_with_capability(&registry.signer_cap);
            let seed = object::object_address(&native_metadata);
            let constructor_ref = object::create_named_object(&wrapper_signer, bcs::to_bytes(&seed));

            primary_fungible_store::create_primary_store_enabled_fungible_asset(
                &constructor_ref,
                option::none(),
                mut_name,
                mut_symbol,
                decimals,
                icon_uri,
                project_uri,
            );

            let mint_ref = fungible_asset::generate_mint_ref(&constructor_ref);
            let burn_ref = fungible_asset::generate_burn_ref(&constructor_ref);
            let wrapper_metadata = object::object_from_constructor_ref<Metadata>(&constructor_ref);

            smart_table::add(&mut registry.native_to_wrapper, native_metadata, WrappedAssetData {
                metadata: wrapper_metadata,
                mint_ref,
                burn_ref,
            });
            smart_table::add(&mut registry.wrapper_to_native, wrapper_metadata, native_metadata);

            event::emit(WrapperCreated {
                native_metadata: object::object_address(&native_metadata),
                wrapper_metadata: object::object_address(&wrapper_metadata),
            });
        };

        smart_table::borrow(&registry.native_to_wrapper, native_metadata).metadata
    }

    // Wrap function restricted to friends (dao_staking, dao_zap)
    // Deposits native FA (by delta) and mints wrapped FA
    public(friend) fun wrap_fa(native_fa: FungibleAsset): FungibleAsset acquires WrapperRegistry {
        let native_metadata = fungible_asset::asset_metadata(&native_fa);
        if (!is_wrapper_registered_for_native(native_metadata)) {
            create_fungible_asset_for_fa(native_metadata);
        };

        let registry = borrow_global<WrapperRegistry>(@dao_router);
        let wrapper_address = registry.wrapper_address;

        let balance_before = primary_fungible_store::balance(wrapper_address, native_metadata);
        let store = primary_fungible_store::ensure_primary_store_exists(wrapper_address, native_metadata);
        dispatchable_fungible_asset::deposit(store, native_fa);
        let balance_after = primary_fungible_store::balance(wrapper_address, native_metadata);
        let actual_deposited = balance_after - balance_before;
        assert!(actual_deposited > 0, error::invalid_argument(ERROR_ZERO_DEPOSIT));

        let data = smart_table::borrow(&registry.native_to_wrapper, native_metadata);

        event::emit(AssetWrapped {
            native_metadata: object::object_address(&native_metadata),
            wrapper_metadata: object::object_address(&data.metadata),
            amount_native_deposited: actual_deposited,
            amount_wrapped_minted: actual_deposited,
            recipient: wrapper_address,
        });

        fungible_asset::mint(&data.mint_ref, actual_deposited)
    }

    // Unwrap function: burns wrapped FA and returns native FA (public so redemption is always guaranteed)
    public fun unwrap_fa(wrapper_fa: FungibleAsset): FungibleAsset acquires WrapperRegistry {
        let wrapper_metadata = fungible_asset::asset_metadata(&wrapper_fa);
        let amount = fungible_asset::amount(&wrapper_fa);

        let registry = borrow_global<WrapperRegistry>(@dao_router);
        let native_metadata = *smart_table::borrow(&registry.wrapper_to_native, wrapper_metadata);
        let data = smart_table::borrow(&registry.native_to_wrapper, native_metadata);

        fungible_asset::burn(&data.burn_ref, wrapper_fa);

        let wrapper_signer = account::create_signer_with_capability(&registry.signer_cap);
        let from_store = primary_fungible_store::ensure_primary_store_exists(registry.wrapper_address, native_metadata);

        event::emit(AssetUnwrapped {
            wrapper_metadata: object::object_address(&wrapper_metadata),
            native_metadata: object::object_address(&native_metadata),
            amount_wrapped_burned: amount,
            amount_native_withdrawn: amount,
            recipient: signer::address_of(&wrapper_signer),
        });

        dispatchable_fungible_asset::withdraw(&wrapper_signer, from_store, amount)
    }

    // Direct entry unwrap for frontend users to redeem underlying collateral anytime
    public entry fun unwrap_entry(user: &signer, wrapped_metadata: Object<Metadata>, amount: u64) acquires WrapperRegistry {
        let user_addr = signer::address_of(user);
        let from_store = primary_fungible_store::ensure_primary_store_exists(user_addr, wrapped_metadata);
        let wrapped_fa = dispatchable_fungible_asset::withdraw(user, from_store, amount);
        let native_fa = unwrap_fa(wrapped_fa);
        let native_metadata = fungible_asset::asset_metadata(&native_fa);
        let dest = primary_fungible_store::ensure_primary_store_exists(user_addr, native_metadata);
        dispatchable_fungible_asset::deposit(dest, native_fa);
    }

    // Hot Potato Flash Loan (no abilities on receipt)
    public fun flash_loan_fa(
        metadata: Object<Metadata>,
        amount: u64
    ): (FungibleAsset, FlashLoanReceiptFA) acquires WrapperRegistry {
        let registry = borrow_global<WrapperRegistry>(@dao_router);
        let wrapper_signer = account::create_signer_with_capability(&registry.signer_cap);
        let wrapper_address = registry.wrapper_address;

        let bal = primary_fungible_store::balance(wrapper_address, metadata);
        assert!(bal >= amount, error::invalid_argument(ERROR_INSUFFICIENT_AMOUNT));

        let from_store = primary_fungible_store::ensure_primary_store_exists(wrapper_address, metadata);
        let loan_fa = dispatchable_fungible_asset::withdraw(&wrapper_signer, from_store, amount);
        let bps = registry.fee_bps;
        let fee = ((((amount as u128) * (bps as u128) + 9999) / 10000) as u64);

        let receipt = FlashLoanReceiptFA { amount, fee, metadata };

        event::emit(FlashLoanFAEvent {
            amount,
            fee_amount: fee,
            metadata
        });

        (loan_fa, receipt)
    }

    public fun repay_flash_loan_fa(
        payment: FungibleAsset,
        receipt: FlashLoanReceiptFA
    ) acquires WrapperRegistry {
        let FlashLoanReceiptFA { amount, fee, metadata } = receipt;

        assert!(fungible_asset::asset_metadata(&payment) == metadata, error::invalid_argument(ERROR_INVALID_REPAYMENT));

        let registry = borrow_global<WrapperRegistry>(@dao_router);
        let balance_before = primary_fungible_store::balance(registry.wrapper_address, metadata);
        let to_store = primary_fungible_store::ensure_primary_store_exists(registry.wrapper_address, metadata);
        dispatchable_fungible_asset::deposit(to_store, payment);
        let balance_after = primary_fungible_store::balance(registry.wrapper_address, metadata);
        let actual_repaid = balance_after - balance_before;
        assert!(actual_repaid >= amount + fee, error::invalid_argument(ERROR_INVALID_REPAYMENT));
    }

    // Hot Potato receipt getters (allows external routers to inspect details)
    public fun flash_loan_receipt_amount(receipt: &FlashLoanReceiptFA): u64 {
        receipt.amount
    }

    public fun flash_loan_receipt_fee(receipt: &FlashLoanReceiptFA): u64 {
        receipt.fee
    }

    public fun flash_loan_receipt_metadata(receipt: &FlashLoanReceiptFA): Object<Metadata> {
        receipt.metadata
    }

    // Admin & Fees (Admin is @HOGL)
    public entry fun collect_accumulated_fees_fa(
        admin: &signer,
        native_metadata: Object<Metadata>,
        amount: u64,
        to: address
    ) acquires WrapperRegistry {
        let registry = borrow_global<WrapperRegistry>(@dao_router);
        assert!(signer::address_of(admin) == registry.admin, error::permission_denied(ERROR_NOT_ADMIN));

        let wrapper_signer = account::create_signer_with_capability(&registry.signer_cap);
        let total_real_balance = primary_fungible_store::balance(registry.wrapper_address, native_metadata);
        
        let data = smart_table::borrow(&registry.native_to_wrapper, native_metadata);
        let total_supply_fa = option::destroy_some(fungible_asset::supply(data.metadata));

        let user_collateral = (total_supply_fa as u64);
        let available_fees = if (total_real_balance > user_collateral) {
            total_real_balance - user_collateral
        } else {
            0
        };

        assert!(amount <= available_fees, error::invalid_argument(ERROR_INSUFFICIENT_AMOUNT));

        let from_store = primary_fungible_store::ensure_primary_store_exists(registry.wrapper_address, native_metadata);
        let fee_fa = dispatchable_fungible_asset::withdraw(&wrapper_signer, from_store, amount);
        let to_store = primary_fungible_store::ensure_primary_store_exists(to, native_metadata);
        dispatchable_fungible_asset::deposit(to_store, fee_fa);
    }

    public entry fun set_fee_bps(admin: &signer, new_fee_bps: u64) acquires WrapperRegistry {
        let registry = borrow_global_mut<WrapperRegistry>(@dao_router);
        assert!(signer::address_of(admin) == registry.admin, error::permission_denied(ERROR_NOT_ADMIN));
        assert!(new_fee_bps <= 100, error::invalid_argument(ERROR_INVALID_REPAYMENT)); // Max 1%
        registry.fee_bps = new_fee_bps;
    }

    public entry fun set_admin(admin: &signer, new_admin: address) acquires WrapperRegistry {
        let registry = borrow_global_mut<WrapperRegistry>(@dao_router);
        assert!(signer::address_of(admin) == registry.admin, error::permission_denied(ERROR_NOT_ADMIN));
        registry.admin = new_admin;
    }

    public entry fun set_fee_receiver(admin: &signer, new_fee_receiver: address) acquires WrapperRegistry {
        let registry = borrow_global_mut<WrapperRegistry>(@dao_router);
        assert!(signer::address_of(admin) == registry.admin, error::permission_denied(ERROR_NOT_ADMIN));
        registry.fee_receiver = new_fee_receiver;
    }

    // Views
    #[view]
    public fun is_wrapper_fa(metadata: Object<Metadata>): bool acquires WrapperRegistry {
        if (!exists<WrapperRegistry>(@dao_router)) return false;
        smart_table::contains(&borrow_global<WrapperRegistry>(@dao_router).wrapper_to_native, metadata)
    }

    #[view]
    public fun is_wrapper_registered_for_native(native_metadata: Object<Metadata>): bool acquires WrapperRegistry {
        if (!exists<WrapperRegistry>(@dao_router)) return false;
        smart_table::contains(&borrow_global<WrapperRegistry>(@dao_router).native_to_wrapper, native_metadata)
    }

    #[view]
    public fun get_original_fa(wrapper_metadata: Object<Metadata>): Object<Metadata> acquires WrapperRegistry {
        *smart_table::borrow(&borrow_global<WrapperRegistry>(@dao_router).wrapper_to_native, wrapper_metadata)
    }

    #[view]
    public fun get_wrapper_for_fa(native_metadata: Object<Metadata>): Object<Metadata> acquires WrapperRegistry {
        smart_table::borrow(&borrow_global<WrapperRegistry>(@dao_router).native_to_wrapper, native_metadata).metadata
    }

    #[view]
    public fun wrapper_address(): address acquires WrapperRegistry {
        borrow_global<WrapperRegistry>(@dao_router).wrapper_address
    }

    #[view]
    public fun get_balance_fa(native_metadata: Object<Metadata>): u64 acquires WrapperRegistry {
        primary_fungible_store::balance(wrapper_address(), native_metadata)
    }

    #[view]
    public fun expected_fee(amount: u64): u64 acquires WrapperRegistry {
        let bps = if (exists<WrapperRegistry>(@dao_router)) {
            borrow_global<WrapperRegistry>(@dao_router).fee_bps
        } else {
            DEFAULT_FLASH_LOAN_FEE_BPS
        };
        ((((amount as u128) * (bps as u128) + 9999) / 10000) as u64)
    }

    #[view]
    public fun get_flash_loan_fee_bps(): u64 acquires WrapperRegistry {
        if (exists<WrapperRegistry>(@dao_router)) {
            borrow_global<WrapperRegistry>(@dao_router).fee_bps
        } else {
            DEFAULT_FLASH_LOAN_FEE_BPS
        }
    }

    #[view]
    public fun get_admin(): address acquires WrapperRegistry {
        borrow_global<WrapperRegistry>(@dao_router).admin
    }

    // ------------------------------------------------------------------
    // Tests - #[test_only] (stripped at deploy).
    // ------------------------------------------------------------------

    #[test_only]
    fun setup(router: &signer) {
        if (!exists<WrapperRegistry>(@dao_router)) { init_module(router); };
    }

    #[test(router = @dao_router, admin = @HOGL)]
    fun test_wrapper_fees(router: &signer, admin: &signer) acquires WrapperRegistry {
        setup(router);
        account::create_account_for_test(signer::address_of(admin));

        assert!(get_flash_loan_fee_bps() == DEFAULT_FLASH_LOAN_FEE_BPS, 1);
        // expected_fee rounds UP to the next unit.
        assert!(expected_fee(1_000_000) == ((1_000_000 * DEFAULT_FLASH_LOAN_FEE_BPS + 9999) / 10000), 2);
        assert!(get_admin() == @HOGL, 3);

        // admin lowers the fee to 0.5%
        set_fee_bps(admin, 50);
        assert!(get_flash_loan_fee_bps() == 50, 4);
        assert!(expected_fee(1_000_000) == 5000, 5);
    }

    #[test(router = @dao_router, admin = @HOGL)]
    #[expected_failure(abort_code = 0x10066)] // invalid_argument(ERROR_INVALID_REPAYMENT=102)
    fun test_wrapper_fee_cap(router: &signer, admin: &signer) acquires WrapperRegistry {
        setup(router);
        account::create_account_for_test(signer::address_of(admin));
        set_fee_bps(admin, 101); // > 100 bps -> abort
    }

    #[test(router = @dao_router, not_admin = @0xBAD)]
    #[expected_failure(abort_code = 0x50067)] // permission_denied(ERROR_NOT_ADMIN=103)
    fun test_wrapper_fee_not_admin(router: &signer, not_admin: &signer) acquires WrapperRegistry {
        setup(router);
        set_fee_bps(not_admin, 10); // not the registry admin -> abort
    }
}
