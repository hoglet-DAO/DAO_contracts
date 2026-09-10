module dao_factory::tax_router {
    use std::error;
    use std::signer;
    use std::vector;
    use dao_tokens::smart_token;
    use supra_framework::object;
    use supra_framework::fungible_asset::{Self, FungibleStore, FungibleAsset};

    const E_NOT_STORE_OWNER: u64 = 1;
    const E_NOT_WHITELISTED_ROUTER: u64 = 2;
    const E_ROUTER_ALREADY_REGISTERED: u64 = 3;
    const E_ROUTER_NOT_REGISTERED: u64 = 4;
    const E_ROUTER_MASTER_UNREMOVABLE: u64 = 5;

    /// FIX (audit13 R-1) Signer-proof router registry: the TaxFree bypass is
    /// only reachable by modules holding the signer of a whitelisted protocol
    /// object (the bonding-curve Pool of the launchpad, generated via its
    /// ExtendRef). No user pubcall can ever forge that proof.
    struct TaxFreeRouter has key {
        cap: smart_token::TaxFreeCap,
        /// Addresses allowed to produce the `router: &signer` proof.
        routers: vector<address>,
    }

    /// Stores the cap and the initial router whitelist. Called ONCE during
    /// the launcher's migration flow with the DAO resource signer.
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

    /// FIX (audit10 C3): true when the DAO has a TaxFreeRouter, i.e. its
    /// governance token is a launcher smart token whose TransferRef was
    /// exchanged for a cap during migration. Plain-FA DAOs (e.g. HOG, minted
    /// by hoglet_genesis without smart_token hooks) never have one and must
    /// use the normal dispatchable flow instead.
    public fun has_tax_free_router(dao_address: address): bool {
        exists<TaxFreeRouter>(dao_address)
    }

    public fun is_whitelisted_router(dao_address: address, router_address: address): bool acquires TaxFreeRouter {
        if (!exists<TaxFreeRouter>(dao_address)) {
            return false
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

    /// FIX (audit13 R-2) Post-deploy registration, LAUNCHER-GATED: a launch
    /// created AFTER this DAO's migration needs its bonding-curve Pool
    /// whitelisted here so it can custody/seed THIS DAO's token as a quote.
    /// Never callable directly: `dao_signer` is the DAO MASTER signer that
    /// only dao_factory's friend modules can produce (ledger). The launcher
    /// calls petra::add_tax_router, which asserts the launcher registry and
    /// generates the signer itself.
    public fun add_router(dao_signer: &signer, router_address: address) acquires TaxFreeRouter {
        let routers_addr = signer::address_of(dao_signer);
        let router = borrow_global_mut<TaxFreeRouter>(routers_addr);
        assert!(!contains_router(&router.routers, router_address), error::invalid_argument(E_ROUTER_ALREADY_REGISTERED));
        vector::push_back(&mut router.routers, router_address);
    }

    /// FIX (AUDIT13 #4) Revocation path: the DAO MASTER signer can remove any
    /// registered router (e.g. deprecating a launchpad integration, rotating
    /// upgrades). Re-adding after removal is allowed (add_router's
    /// duplicate-check only guards the CURRENT vector). Removal is always
    /// possible because add/remove are both anchored to the DAO master
    /// signer, which the DAO's own governance/infra retains for its
    /// lifetime no router can become permanently un-revocable.
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

    /// Withdraws `amount` from `store` using the DAO's cap (bypasses the
    /// token's dispatch hooks).
    ///
    /// FIX (audit13 R-1) hardening: the caller must (a) hold the signer of a
    /// WHITELISTED router (the object signer user pubcalls cannot produce
    /// it) and (b) OWN the target store, by audit9 H-2. Net effect: only the
    /// launchpad pool can extract from its own custodial reserve.
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
        // The DAO MASTER signer (the same authority that already holds the
        // DAO's mint/burn/TreasuryRef powers) is exempt from the owner check:
        // the DAO's own trusted infra withdraws from module-owned vault
        // stores. Every OTHER router keeps the strict audit9 H-2 owner rule.
        if (router_addr != dao_address) {
            assert!(
                object::owner(store) == router_addr,
                error::permission_denied(E_NOT_STORE_OWNER)
            );
        };
        let router_res = borrow_global<TaxFreeRouter>(dao_address);
        smart_token::withdraw_tax_free(&router_res.cap, store, amount)
    }

    /// FIX (audit10 C3): falls back to the normal dispatchable deposit when
    /// the DAO has no TaxFreeRouter (plain-FA tokens have no hooks, so the
    /// result is equivalent). Deposits do not require the receiver's signer,
    /// so the only gate is the whitelisted ROUTER proof: users can no longer
    /// self-deposit tax-free to dodge the token's incoming tax hooks.
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
            fungible_asset::deposit(store, fa);
        };
    }
}
