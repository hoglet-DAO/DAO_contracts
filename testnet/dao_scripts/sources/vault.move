// Per-DAO script policy ("vault") - a TRI-STATE, plus the global audit fallback.
//
// Each (dao, script_id) is one of:
//   unset (default) -> the DAO has not spoken: usable IFF the library marks it
//                      audited. This is the "dynamic" fast-path: a Hoglet-audited
//                      script can be proposed/executed by ANY DAO without an
//                      allow-list proposal.
//   allow           -> the DAO explicitly allow-listed it (usable even if NOT audited).
//   block           -> the DAO explicitly BLOCKED it (NOT usable even if audited) -
//                      the sovereign opt-out (e.g. the script's target protocol
//                      got hacked and the DAO wants it dead immediately).
//
// Type 9 proposals drive this (add=true -> allow, add=false -> block). The gate
// `is_approved` is checked at BOTH proposal creation and execution, so blocking a
// script (or Hoglet un-auditing it) makes pending executions fail.
//
// Keyed by (dao, script_id) in a single global table: no per-DAO resource and no
// initialization needed. Writes take the DAO's `&signer`, which only the
// dao_factory governance can produce (via `ledger::generate_signer`), so a caller
// can only ever edit its OWN vault.
module dao_scripts::vault {
    use std::signer;
    use std::error;
    use supra_framework::event;
    use supra_framework::smart_table::{Self, SmartTable};
    use dao_scripts::library;

    const E_SCRIPT_NOT_FOUND: u64 = 1;

    const STATE_ALLOW: u8 = 1;
    const STATE_BLOCK: u8 = 2;

    struct VaultKey has copy, drop, store {
        dao: address,
        script_id: u64,
    }

    struct VaultState has key {
        state: SmartTable<VaultKey, u8>,
    }
    #[event]
    struct ScriptStatusChanged has drop, store {
        dao_address: address,
        script_id: u64,
        is_allowed: bool,
    }

    fun init_module(deployer: &signer) {
        move_to(deployer, VaultState { state: smart_table::new() });
    }

    // Explicitly allow-lists a script id for the caller's DAO (usable even if the
    // script is NOT audited). The id must exist in the global library, so a vault
    // can never reference a phantom script.
    public fun add(dao_signer: &signer, script_id: u64) acquires VaultState {
        assert!(library::script_exists(script_id), error::invalid_argument(E_SCRIPT_NOT_FOUND));
        let dao = signer::address_of(dao_signer);
        let state = borrow_global_mut<VaultState>(@dao_scripts);
        smart_table::upsert(&mut state.state, VaultKey { dao, script_id }, STATE_ALLOW);
        event::emit(ScriptStatusChanged { dao_address: dao, script_id, is_allowed: true });
    }

    // Explicitly BLOCKS a script id for the caller's DAO: it can no longer be
    // proposed nor executed, even if the library still marks it as audited.
    public fun remove(dao_signer: &signer, script_id: u64) acquires VaultState {
        assert!(library::script_exists(script_id), error::invalid_argument(E_SCRIPT_NOT_FOUND));
        let dao = signer::address_of(dao_signer);
        let state = borrow_global_mut<VaultState>(@dao_scripts);
        smart_table::upsert(&mut state.state, VaultKey { dao, script_id }, STATE_BLOCK);
        event::emit(ScriptStatusChanged { dao_address: dao, script_id, is_allowed: false });
    }

    // Gate used at BOTH proposal creation and execution:
    //   allow           -> true
    //   block           -> false  (even if audited)
    //   unset (default) -> true iff the library marks the script audited
    #[view]
    public fun is_approved(dao: address, script_id: u64): bool acquires VaultState {
        let state = borrow_global<VaultState>(@dao_scripts);
        let key = VaultKey { dao, script_id };
        if (smart_table::contains(&state.state, key)) {
            return *smart_table::borrow(&state.state, key) == STATE_ALLOW
        };
        // Unset: fall back to the global audit signal (dynamic fast-path).
        library::is_audited(script_id)
    }
}
