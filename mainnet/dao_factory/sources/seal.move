/// Script argument commitment + allow-list gate for type-9 proposals.
///
/// The chain's `get_script_hash()` covers ONLY the bytecode, so a script that
/// takes arguments would let any executor run it with different inputs. This
/// module closes that gap: the DAO commits `args_commitment = keccak256(args)`
/// on-chain, and execution verifies the caller's args against it.
///
/// `seal` is the ONLY public entry point for type-9 scripts (`anchor::resolve`
/// is `public(friend)`), so the args + allow-list checks can never be bypassed.
///   - `resolve`: single entry point for all scripts (static scripts pass b"").
module dao_factory::seal {
    use std::error;
    use std::vector;
    use supra_framework::event;
    use aptos_std::aptos_hash;
    use dao_factory::anchor;
    use dao_factory::ledger;
    use dao_scripts::vault;

    const E_ARGS_MISMATCH: u64 = 1;
    const E_NOT_ALLOWED: u64 = 2;
    const E_NOT_COMMITTED: u64 = 3;

    #[event]
    struct ScriptExecuted has drop, store {
        dao_address: address,
        proposal_id: u64,
        script_id: u64,
    }

    /// Resolves a type-9 proposal for any script transaction. Must be
    /// called from within the script transaction (so `anchor::resolve` can
    /// compare `get_script_hash()` against the proposal's execution hash).
    ///
    /// For parameterized scripts: pass caller-supplied `args`.
    /// For static (parameterless) scripts: pass `b""` / `vector::empty<u8>()`.
    public fun resolve(dao_address: address, proposal_id: u64, args: vector<u8>): signer {
        let script_id = ledger::get_proposal_script_id(dao_address, proposal_id);

        // 1. Gate: the script id must be in this DAO's allow-list.
        assert!(vault::is_approved(dao_address, script_id), error::invalid_state(E_NOT_ALLOWED));

        // 2. Commit: the caller-supplied args must hash to the on-chain commitment.
        let commitment = ledger::get_proposal_args_commitment(dao_address, proposal_id);
        assert!(!vector::is_empty(&commitment), error::invalid_state(E_NOT_COMMITTED));
        assert!(aptos_hash::keccak256(args) == commitment, error::invalid_argument(E_ARGS_MISMATCH));

        // 3. All remaining checks live in anchor::resolve.
        let dao_signer = anchor::resolve(dao_address, proposal_id);
        event::emit(ScriptExecuted { dao_address, proposal_id, script_id });
        dao_signer
    }
}
