/// Per-DAO allow-list ("vault") of script ids the DAO has approved.
///
/// Type 10 proposals add/remove ids here. Type 9 execution is gated on
/// membership (checked both at proposal creation and at execution), so a DAO
/// can only run scripts it has explicitly allow-listed and can REVOKE one
/// (remove it) to make pending executions fail.
///
/// Keyed by (dao, script_id) in a single global table: no per-DAO resource and
/// no initialization needed. Writes take the DAO's `&signer`, which only the
/// dao_factory governance can produce (via `ledger::generate_signer`), so a
/// caller can only ever edit its OWN vault.
module dao_scripts::vault {
    use std::signer;
    use std::error;
    use supra_framework::event;
    use supra_framework::smart_table::{Self, SmartTable};
    use dao_scripts::library;

    const E_SCRIPT_NOT_FOUND: u64 = 1;

    struct VaultKey has copy, drop, store {
        dao: address,
        script_id: u64,
    }

    struct VaultState has key {
        approved: SmartTable<VaultKey, bool>,
    }

    #[event]
    struct ScriptAllowed has drop, store {
        dao_address: address,
        script_id: u64,
    }

    #[event]
    struct ScriptRevoked has drop, store {
        dao_address: address,
        script_id: u64,
    }

    fun init_module(deployer: &signer) {
        move_to(deployer, VaultState { approved: smart_table::new() });
    }

    /// Allow-lists a script id for the caller's DAO. The id must exist in the
    /// global library, so a vault can never reference a phantom script.
    public fun add(dao_signer: &signer, script_id: u64) acquires VaultState {
        assert!(library::script_exists(script_id), error::invalid_argument(E_SCRIPT_NOT_FOUND));
        let dao = signer::address_of(dao_signer);
        let state = borrow_global_mut<VaultState>(@dao_scripts);
        smart_table::upsert(&mut state.approved, VaultKey { dao, script_id }, true);
        event::emit(ScriptAllowed { dao_address: dao, script_id });
    }

    /// Removes a script id from the caller's DAO allow-list (revoke).
    public fun remove(dao_signer: &signer, script_id: u64) acquires VaultState {
        let dao = signer::address_of(dao_signer);
        let state = borrow_global_mut<VaultState>(@dao_scripts);
        let key = VaultKey { dao, script_id };
        if (smart_table::contains(&state.approved, key)) {
            smart_table::remove(&mut state.approved, key);
            event::emit(ScriptRevoked { dao_address: dao, script_id });
        };
    }

    #[view]
    public fun is_approved(dao: address, script_id: u64): bool acquires VaultState {
        let state = borrow_global<VaultState>(@dao_scripts);
        smart_table::contains(&state.approved, VaultKey { dao, script_id })
    }
}
