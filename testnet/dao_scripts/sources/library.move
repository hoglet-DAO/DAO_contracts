/// Global, immutable, content-addressed registry of Move scripts.
///
/// The chain stores ONLY hashes/CIDs (never the script code): `execution_hash`
/// (sha3-256 of the compiled bytecode) + `source_cid` (IPFS CID of the source
/// project). The code itself lives off-chain (IPFS + D1).
///
/// Entries are IMMUTABLE and versioned: a published `script_id` never changes.
/// A fix is a NEW entry. That is what makes referencing a script by id safe.
///
/// Curation: the admin (Hoglet DAO after the EOA handover) marks entries
/// `audited`. Anyone may submit a script by paying a flat anti-spam fee.
module dao_scripts::library {
    use std::string::{Self, String};
    use std::signer;
    use std::error;
    use std::vector;
    use supra_framework::timestamp;
    use supra_framework::event;
    use supra_framework::coin;
    use supra_framework::supra_coin::SupraCoin;
    use supra_framework::smart_table::{Self, SmartTable};

    // Errors
    const E_NOT_ADMIN: u64 = 1;
    const E_INVALID_HASH_LENGTH: u64 = 2;
    const E_INSUFFICIENT_FEE: u64 = 3;
    const E_NOT_FOUND: u64 = 4;
    const E_FEE_TOO_HIGH: u64 = 5;
    const E_INVALID_CID: u64 = 6;

    // 13_700 SUPRA (8 decimals) mirrors petra's MAX_CREATION_FEE ceiling.
    const MAX_FEE: u64 = 1_370_000_000_000;

    struct ScriptEntry has store, drop {
        execution_hash: vector<u8>, // sha3-256 of the compiled Move script bytecode
        source_cid: String,         // IPFS CID of the source project (Move.toml + sources)
        category: u8,               // free-form tag for discoverability
        has_args: bool,             // true: parameterized (seal::resolve with args), false: static (seal::resolve with b"")
        author: address,            // who submitted it
        audited: bool,              // set by the admin (Hoglet DAO)
        created_at: u64,
    }

    struct LibraryConfig has key {
        admin: address,
        pending_admin: address,
        fee: u64,
        fee_receiver: address,
        next_id: u64,
        entries: SmartTable<u64, ScriptEntry>,
    }

    #[event]
    struct ScriptSubmitted has drop, store {
        script_id: u64,
        author: address,
        execution_hash: vector<u8>,
        source_cid: String,
        category: u8,
        has_args: bool,
    }

    #[event]
    struct ScriptAuditChanged has drop, store {
        script_id: u64,
        audited: bool,
    }

    #[event]
    struct FeeChanged has drop, store {
        fee: u64,
        fee_receiver: address,
    }

    #[event]
    struct LibraryAdminTransferred has drop, store {
        old_admin: address,
        new_admin: address,
    }

    #[event]
    struct LibraryAdminRenounced has drop, store {
        old_admin: address,
    }

    // Runs once at publish; `deployer` is the dao_scripts package account.
    fun init_module(deployer: &signer) {
        move_to(deployer, LibraryConfig {
            admin: @HOG,
            pending_admin: @0x0,
            fee: 0,
            fee_receiver: @HOG,
            next_id: 1,
            entries: smart_table::new(),
        });
    }

    fun assert_admin(admin: &signer) acquires LibraryConfig {
        assert!(
            signer::address_of(admin) == borrow_global<LibraryConfig>(@dao_scripts).admin,
            error::permission_denied(E_NOT_ADMIN)
        );
    }

    /// Registers a new script. Permissionless: anyone may submit by paying the
    /// flat anti-spam fee (if configured). The entry starts un-audited.
    public entry fun submit_script(
        submitter: &signer,
        execution_hash: vector<u8>,
        source_cid: String,
        category: u8,
        has_args: bool,
    ) acquires LibraryConfig {
        assert!(vector::length(&execution_hash) == 32, error::invalid_argument(E_INVALID_HASH_LENGTH));

        // Bound the CID length (IPFS CIDv0 ~ 46, CIDv1 ~ 59): rejects storage spam.
        let cid_len = string::length(&source_cid);
        assert!(cid_len >= 32 && cid_len <= 128, error::invalid_argument(E_INVALID_CID));

        let config = borrow_global_mut<LibraryConfig>(@dao_scripts);

        // Anti-spam fee: paid to the admin's receiver wallet.
        if (config.fee > 0) {
            let balance = coin::balance<SupraCoin>(signer::address_of(submitter));
            assert!(balance >= config.fee, error::invalid_state(E_INSUFFICIENT_FEE));
            coin::transfer<SupraCoin>(submitter, config.fee_receiver, config.fee);
        };

        let id = config.next_id;
        config.next_id = id + 1;
        smart_table::add(&mut config.entries, id, ScriptEntry {
            execution_hash,
            source_cid,
            category,
            has_args,
            author: signer::address_of(submitter),
            audited: false,
            created_at: timestamp::now_seconds(),
        });

        event::emit(ScriptSubmitted {
            script_id: id,
            author: signer::address_of(submitter),
            execution_hash,
            source_cid,
            category,
            has_args,
        });
    }

    /// Marks a script as audited (or revokes it). Admin-only (Hoglet DAO).
    public entry fun mark_audited(admin: &signer, script_id: u64, audited: bool) acquires LibraryConfig {
        assert_admin(admin);
        let config = borrow_global_mut<LibraryConfig>(@dao_scripts);
        assert!(smart_table::contains(&config.entries, script_id), error::invalid_argument(E_NOT_FOUND));
        let entry = smart_table::borrow_mut(&mut config.entries, script_id);
        entry.audited = audited;
        event::emit(ScriptAuditChanged { script_id, audited });
    }

    public entry fun set_fee(admin: &signer, new_fee: u64) acquires LibraryConfig {
        assert_admin(admin);
        assert!(new_fee <= MAX_FEE, error::invalid_argument(E_FEE_TOO_HIGH));
        let config = borrow_global_mut<LibraryConfig>(@dao_scripts);
        config.fee = new_fee;
        event::emit(FeeChanged { fee: new_fee, fee_receiver: config.fee_receiver });
    }

    public entry fun set_fee_receiver(admin: &signer, new_receiver: address) acquires LibraryConfig {
        assert_admin(admin);
        assert!(new_receiver != @0x0, error::invalid_argument(E_NOT_FOUND));
        let config = borrow_global_mut<LibraryConfig>(@dao_scripts);
        config.fee_receiver = new_receiver;
        event::emit(FeeChanged { fee: config.fee, fee_receiver: new_receiver });
    }

    // --- Two-step admin transfer (mirrors petra: typo-safe) ---

    public entry fun transfer_admin(admin: &signer, new_admin: address) acquires LibraryConfig {
        assert_admin(admin);
        let config = borrow_global_mut<LibraryConfig>(@dao_scripts);
        config.pending_admin = new_admin;
    }

    public entry fun accept_admin(candidate: &signer) acquires LibraryConfig {
        do_accept_admin(signer::address_of(candidate));
    }

    fun do_accept_admin(candidate_addr: address) acquires LibraryConfig {
        let config = borrow_global_mut<LibraryConfig>(@dao_scripts);
        assert!(
            config.pending_admin != @0x0 && candidate_addr == config.pending_admin,
            error::permission_denied(E_NOT_ADMIN)
        );
        let old_admin = config.admin;
        config.admin = candidate_addr;
        config.pending_admin = @0x0;
        event::emit(LibraryAdminTransferred { old_admin, new_admin: candidate_addr });
    }

    /// Irreversible: burns the admin key. After this, no one can audit.
    public entry fun renounce_admin(admin: &signer) acquires LibraryConfig {
        assert_admin(admin);
        let config = borrow_global_mut<LibraryConfig>(@dao_scripts);
        let old_admin = config.admin;
        config.admin = @0x0;
        config.pending_admin = @0x0;
        event::emit(LibraryAdminRenounced { old_admin });
    }

    // --- Views ---

    #[view]
    public fun get_execution_hash(script_id: u64): vector<u8> acquires LibraryConfig {
        let config = borrow_global<LibraryConfig>(@dao_scripts);
        assert!(smart_table::contains(&config.entries, script_id), error::invalid_argument(E_NOT_FOUND));
        smart_table::borrow(&config.entries, script_id).execution_hash
    }

    #[view]
    public fun get_source_cid(script_id: u64): String acquires LibraryConfig {
        let config = borrow_global<LibraryConfig>(@dao_scripts);
        assert!(smart_table::contains(&config.entries, script_id), error::invalid_argument(E_NOT_FOUND));
        smart_table::borrow(&config.entries, script_id).source_cid
    }

    #[view]
    public fun is_audited(script_id: u64): bool acquires LibraryConfig {
        let config = borrow_global<LibraryConfig>(@dao_scripts);
        if (!smart_table::contains(&config.entries, script_id)) return false;
        smart_table::borrow(&config.entries, script_id).audited
    }

    #[view]
    public fun has_args(script_id: u64): bool acquires LibraryConfig {
        let config = borrow_global<LibraryConfig>(@dao_scripts);
        assert!(smart_table::contains(&config.entries, script_id), error::invalid_argument(E_NOT_FOUND));
        smart_table::borrow(&config.entries, script_id).has_args
    }

    public fun script_exists(script_id: u64): bool acquires LibraryConfig {
        smart_table::contains(&borrow_global<LibraryConfig>(@dao_scripts).entries, script_id)
    }

    #[view]
    public fun get_fee(): u64 acquires LibraryConfig {
        borrow_global<LibraryConfig>(@dao_scripts).fee
    }

    #[view]
    public fun get_fee_receiver(): address acquires LibraryConfig {
        borrow_global<LibraryConfig>(@dao_scripts).fee_receiver
    }

    #[view]
    public fun get_admin(): address acquires LibraryConfig {
        borrow_global<LibraryConfig>(@dao_scripts).admin
    }

    #[view]
    public fun get_count(): u64 acquires LibraryConfig {
        borrow_global<LibraryConfig>(@dao_scripts).next_id - 1
    }
}
