module dao_tax_router::tax_router {
    use std::error;
    use std::signer;
    use std::vector;
    use dao_tokens::smart_token;
    use supra_framework::object;
    use supra_framework::fungible_asset::{FungibleStore, FungibleAsset};
    use supra_framework::dispatchable_fungible_asset;

    const E_NOT_STORE_OWNER: u64 = 1;
    const E_NOT_WHITELISTED_ROUTER: u64 = 2;
    const E_ROUTER_ALREADY_REGISTERED: u64 = 3;
    const E_ROUTER_NOT_REGISTERED: u64 = 4;
    const E_ROUTER_MASTER_UNREMOVABLE: u64 = 5;
    const E_BLACKLISTED: u64 = 6;

    // FIX (audit13 R-1) Signer-proof router registry: the TaxFree bypass is
    // only reachable by modules holding the signer of a whitelisted protocol
    // object (the bonding-curve Pool of the launchpad, generated via its
    // ExtendRef). No user pubcall can ever forge that proof.
    struct TaxFreeRouter has key {
        cap: smart_token::TaxFreeCap,
        // Addresses allowed to produce the `router: &signer` proof.
        routers: vector<address>,
    }

    // Stores the cap and the initial router whitelist. Called ONCE during
    // the launcher's migration flow with the DAO resource signer.
    public fun store_tax_free_cap(
        dao_signer: &signer,
        cap: smart_token::TaxFreeCap,
        routers: vector<address>
    ) {
        // [FIX (audit13 R-1c)] Idempotent dedup of the INITIAL list: callers
        // compose it from protocol-derived addresses (curve pool, launcher
        // resource account, DAO master) and an overlap is a benign no-op, not
        // an error. The previous pairwise consult compared each element
        // against the WHOLE vector (including itself) and aborted every
        // non-empty registration E_ROUTER_ALREADY_REGISTERED on any
        // migration. Dedupe silently; ADD_router keeps the strict dup abort.
        // SECURITY: no semantic change the signer-proof gate, the
        // owner-check, the move_to-already-exists guard and add_router's
        // assert are untouched.
        let deduped = vector::empty<address>();
        let i = 0;
        let n = vector::length(&routers);
        while (i < n) {
            let elem = *vector::borrow(&routers, i);
            if (!contains_router(&deduped, elem)) {
                vector::push_back(&mut deduped, elem);
            };
            i = i + 1;
        };
        move_to(dao_signer, TaxFreeRouter { cap, routers: deduped });
    }

    fun contains_router(routers: &vector<address>, addr: address): bool {
        let i = 0;
        let n = vector::length(routers);
        while (i < n) {
            if (*vector::borrow(routers, i) == addr) {
                return true
            };
            i = i + 1;
        };
        false
    }

    // FIX (audit10 C3): true when the DAO has a TaxFreeRouter, i.e. its
    // governance token is a launcher smart token whose TransferRef was
    // exchanged for a cap during migration. Plain-FA DAOs (e.g. HOG, minted
    // by hoglet_genesis without smart_token hooks) never have one and must
    // use the normal dispatchable flow instead.
    public fun has_tax_free_router(dao_address: address): bool {
        exists<TaxFreeRouter>(dao_address)
    }

    public fun is_whitelisted_router(dao_address: address, router_address: address): bool acquires TaxFreeRouter {
        if (!exists<TaxFreeRouter>(dao_address)) {
            return false
        };
        if (router_address == dao_address) {
            return true
        };
        let router = borrow_global<TaxFreeRouter>(dao_address);
        contains_router(&router.routers, router_address)
    }

    public fun get_whitelisted_routers(dao_address: address): vector<address> acquires TaxFreeRouter {
        if (!exists<TaxFreeRouter>(dao_address)) {
            return vector::empty<address>()
        };
        let router = borrow_global<TaxFreeRouter>(dao_address);
        *&router.routers
    }

    // FIX (audit13 R-2) Post-deploy registration, LAUNCHER-GATED: a launch
    // created AFTER this DAO's migration needs its bonding-curve Pool
    // whitelisted here so it can custody/seed THIS DAO's token as a quote.
    // Never callable directly: `dao_signer` is the DAO MASTER signer that
    // only dao__tax_router's friend modules can produce (ledger). The launcher
    // calls petra::add_tax_router, which asserts the launcher registry and
    // generates the signer itself.
    public fun add_router(dao_signer: &signer, router_address: address) acquires TaxFreeRouter {
        let routers_addr = signer::address_of(dao_signer);
        let router = borrow_global_mut<TaxFreeRouter>(routers_addr);
        assert!(!contains_router(&router.routers, router_address), error::invalid_argument(E_ROUTER_ALREADY_REGISTERED));
        vector::push_back(&mut router.routers, router_address);
    }

    // FIX (AUDIT13 #4) Revocation path: the DAO MASTER signer can remove any
    // registered router (e.g. deprecating a launchpad integration, rotating
    // upgrades). Re-adding after removal is allowed (add_router's
    // duplicate-check only guards the CURRENT vector). Removal is always
    // possible because add/remove are both anchored to the DAO master
    // signer, which the DAO's own governance/infra retains for its
    // lifetime no router can become permanently un-revocable.
    public fun remove_router(dao_signer: &signer, router_address: address) acquires TaxFreeRouter {
        let routers_addr = signer::address_of(dao_signer);
        assert!(router_address != routers_addr, error::permission_denied(E_ROUTER_MASTER_UNREMOVABLE));
        let router = borrow_global_mut<TaxFreeRouter>(routers_addr);
        assert!(contains_router(&router.routers, router_address), error::not_found(E_ROUTER_NOT_REGISTERED));
        let i = 0;
        let n = vector::length(&router.routers);
        while (i < n) {
            if (*vector::borrow(&router.routers, i) == router_address) {
                vector::remove(&mut router.routers, i);
                return
            };
            i = i + 1;
        };
    }

    // Withdraws `amount` from `store` using the DAO's cap (bypasses the
    // token's dispatch hooks).
    // Returns true if `router_addr` owns `store` directly or transitively as a protocol object.
    public fun is_store_owned_by(store: object::Object<FungibleStore>, router_addr: address): bool {
        object::owner(store) == router_addr || object::owns(store, router_addr)
    }

    // Withdraws `amount` from `store` using the DAO's cap (bypasses the token's dispatch hooks).
    //
    // H-04 Remediation: strictly enforces store ownership.
    // Every router (including the DAO master signer) can only extract from stores that it
    // directly or transitively owns (treasury, escrow, rebase, vaults, gauges).
    // User wallets, veNFTs, and external stores can NEVER be drained.
    public fun withdraw_tax_free(
        dao_address: address,
        router: &signer,
        store: object::Object<FungibleStore>,
        amount: u64
    ): FungibleAsset acquires TaxFreeRouter {
        assert!(
            is_whitelisted_router(dao_address, signer::address_of(router)),
            error::permission_denied(E_NOT_WHITELISTED_ROUTER)
        );
        let router_addr = signer::address_of(router);
        assert!(
            is_store_owned_by(store, router_addr),
            error::permission_denied(E_NOT_STORE_OWNER)
        );
        let router_res = borrow_global<TaxFreeRouter>(dao_address);
        smart_token::withdraw_tax_free(&router_res.cap, store, amount)
    }

    // Transfers tax-free from a store signed and directly owned by `owner` into a protocol store
    // owned directly or transitively by `dao_address`.
    // Prevents arbitrary withdrawals (Point 1) by enforcing that destination must be protocol-owned.
    public fun transfer_tax_free_from_owner(
        dao_address: address,
        owner: &signer,
        from_store: object::Object<FungibleStore>,
        to_store: object::Object<FungibleStore>,
        amount: u64
    ) acquires TaxFreeRouter {
        assert!(exists<TaxFreeRouter>(dao_address), error::not_found(E_NOT_WHITELISTED_ROUTER));
        assert!(
            object::owner(from_store) == signer::address_of(owner),
            error::permission_denied(E_NOT_STORE_OWNER)
        );
        assert!(
            is_store_owned_by(to_store, dao_address),
            error::permission_denied(E_NOT_STORE_OWNER)
        );
        let router_res = borrow_global<TaxFreeRouter>(dao_address);
        let token_addr = smart_token::cap_token_address(&router_res.cap);
        assert!(
            !smart_token::is_blacklisted(token_addr, signer::address_of(owner)),
            error::permission_denied(E_BLACKLISTED)
        );
        let fa = smart_token::withdraw_tax_free(&router_res.cap, from_store, amount);
        smart_token::deposit_tax_free(&router_res.cap, to_store, fa);
    }

    // FIX (audit10 C3): falls back to the normal dispatchable deposit when
    // the DAO has no TaxFreeRouter (plain-FA tokens have no hooks, so the
    // result is equivalent). Deposits do not require the receiver's signer,
    // so the only gate is the whitelisted ROUTER proof: users can no longer
    // self-deposit tax-free to dodge the token's incoming tax hooks.
    public fun deposit_tax_free(
        dao_address: address,
        router: &signer,
        store: object::Object<FungibleStore>,
        fa: FungibleAsset
    ) acquires TaxFreeRouter {
        if (exists<TaxFreeRouter>(dao_address)) {
            assert!(
                is_whitelisted_router(dao_address, signer::address_of(router)),
                error::permission_denied(E_NOT_WHITELISTED_ROUTER)
            );
            let router_res = borrow_global<TaxFreeRouter>(dao_address);
            smart_token::deposit_tax_free(&router_res.cap, store, fa);
        } else {
            dispatchable_fungible_asset::deposit(store, fa);
        };
    }
}
