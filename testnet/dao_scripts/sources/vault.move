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

    // ------------------------------------------------------------------
    // Tests - #[test_only] (stripped from the deploy bytecode).
    // ------------------------------------------------------------------

    #[test_only]
    use supra_framework::account;

    #[test_only]
    fun setup(deployer: &signer, user: &signer) {
        // Library must be bootstrapped (script_exists gates the vault writes).
        library::setup_for_test(deployer);
        if (!exists<VaultState>(@dao_scripts)) { init_module(deployer); };
        account::create_account_for_test(signer::address_of(user));
        library::submit_from_test(user, 3); // creates script_id 1
    }

    #[test(deployer = @dao_scripts, user = @0x1234)]
    fun test_vault_tristate(deployer: &signer, user: &signer) acquires VaultState {
        setup(deployer, user);
        let dao = signer::address_of(user);

        // unset + not audited -> not approved
        assert!(!is_approved(dao, 1), 1);

        // allow -> approved even though the library does not mark it audited
        add(user, 1);
        assert!(is_approved(dao, 1), 2);

        // block -> not approved
        remove(user, 1);
        assert!(!is_approved(dao, 1), 3);

        // another DAO's vault is independent (unset -> follows global audit = false)
        assert!(!is_approved(@0xBEEF, 1), 4);
    }

    #[test(deployer = @dao_scripts, user = @0x1234)]
    #[expected_failure(abort_code = 0x10001)] // invalid_argument(E_SCRIPT_NOT_FOUND=1)
    fun test_add_missing_script(deployer: &signer, user: &signer) acquires VaultState {
        setup(deployer, user);
        add(user, 999); // never registered in the library -> abort
    }
}
