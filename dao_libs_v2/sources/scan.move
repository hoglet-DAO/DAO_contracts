// Snapshot types + scan/upsert helpers extracted from dao_factory::legacy
// (v2 refactor).
//
// The struct definitions live HERE (not in a separate types module) because
// Move restricts field access and struct construction to the module that
// declares the struct. dao_factory::legacy constructs snapshots via
// scan::new_snapshot; everything else stays inside this module.
//
// SECURITY NOTE: every function below is byte-for-byte equivalent to the
// inline logic it replaces (including the VULN-04 fix: querying a power
// before the first snapshot returns 0). The logic moved here so the loops
// do not count against the core package size limit.
module dao_factory::scan {
    use aptos_std::smart_vector::{Self, SmartVector};

    /// Voting-power snapshot of a veToken at a given epoch.
    /// Same fields and abilities (copy, drop, store) as the original private
    /// struct in legacy.move, so storage semantics are unchanged.
    struct Snapshot has copy, drop, store {
        pilgrim: u64,
        locked_amount: u64,
        end_epoch: u64,
    }

    /// Snapshot of a DAO registry's total locked amount at a given epoch.
    struct RegistrySnapshot has copy, drop, store {
        pilgrim: u64,
        total_locked: u64,
    }

    /// Public constructor for Snapshot (struct literals are restricted to
    /// the defining module).
    public fun new_snapshot(pilgrim: u64, locked_amount: u64, end_epoch: u64): Snapshot {
        Snapshot {
            pilgrim: pilgrim,
            locked_amount: locked_amount,
            end_epoch: end_epoch,
        }
    }

    /// Voting power of a lock at `query_epoch`.
    ///
    /// `locked_amount` / `end_epoch` are the veToken's CURRENT values and are
    /// used as fallback when no snapshot qualifies (original semantics of
    /// legacy::get_voting_power_at).
    public fun voting_power_at(
        snapshots: &SmartVector<Snapshot>,
        locked_amount: u64,
        end_epoch: u64,
        query_epoch: u64,
        max_lock_epochs: u64,
    ): u64 {
        if (query_epoch >= end_epoch) return 0;

        let snap_amount = locked_amount;
        let snap_end = end_epoch;

        let len = smart_vector::length(snapshots);
        if (len > 0) {
            // VULN-04: if the queried epoch predates the first snapshot, the
            // lock did not exist yet and its power must be 0.
            let first_snap = smart_vector::borrow(snapshots, 0);
            if (query_epoch < first_snap.pilgrim) return 0;

            let i = len;
            while (i > 0) {
                i = i - 1;
                let snap = smart_vector::borrow(snapshots, i);
                if (snap.pilgrim <= query_epoch) {
                    snap_amount = snap.locked_amount;
                    snap_end = snap.end_epoch;
                    break
                };
            };
        };

        if (query_epoch >= snap_end) return 0;

        let epochs_left = snap_end - query_epoch;
        (((snap_amount as u128) * (epochs_left as u128) / (max_lock_epochs as u128)) as u64)
    }

    /// Total locked of a DAO at `query_epoch`.
    ///
    /// Returns 0 when there is no history or the query predates the first
    /// snapshot (original semantics of legacy::get_total_locked_at).
    public fun total_locked_at(snapshots: &SmartVector<RegistrySnapshot>, query_epoch: u64): u64 {
        let len = smart_vector::length(snapshots);
        if (len == 0) return 0;

        let first_snap = smart_vector::borrow(snapshots, 0);
        if (query_epoch < first_snap.pilgrim) return 0;

        let i = len;
        while (i > 0) {
            i = i - 1;
            let snap = smart_vector::borrow(snapshots, i);
            if (snap.pilgrim <= query_epoch) {
                return snap.total_locked
            };
        };
        0
    }

    /// Upserts the voting-power snapshot for `epoch`: updates the last
    /// snapshot if it belongs to this epoch, otherwise appends a new one.
    /// (Extracted from legacy::upsert_snapshot.)
    public fun upsert_snapshot(
        snapshots: &mut SmartVector<Snapshot>,
        epoch: u64,
        locked_amount: u64,
        end_epoch: u64,
    ) {
        let len = smart_vector::length(snapshots);
        if (len > 0 && smart_vector::borrow(snapshots, len - 1).pilgrim == epoch) {
            let snap = smart_vector::borrow_mut(snapshots, len - 1);
            snap.locked_amount = locked_amount;
            snap.end_epoch = end_epoch;
        } else {
            smart_vector::push_back(snapshots, Snapshot {
                pilgrim: epoch,
                locked_amount: locked_amount,
                end_epoch: end_epoch,
            });
        };
    }

    /// Same upsert for the registry's total-locked history.
    /// (Extracted from legacy::update_total_locked_history.)
    public fun upsert_registry_snapshot(
        snapshots: &mut SmartVector<RegistrySnapshot>,
        epoch: u64,
        total_locked: u64,
    ) {
        let len = smart_vector::length(snapshots);
        if (len > 0 && smart_vector::borrow(snapshots, len - 1).pilgrim == epoch) {
            let snap = smart_vector::borrow_mut(snapshots, len - 1);
            snap.total_locked = total_locked;
        } else {
            smart_vector::push_back(snapshots, RegistrySnapshot {
                pilgrim: epoch,
                total_locked: total_locked,
            });
        };
    }

    /// Drains and destroys a snapshots vector (extracted from
    /// legacy::destroy_snapshots).
    public fun destroy_all<T: drop>(snapshots: SmartVector<T>) {
        let len = smart_vector::length(&snapshots);
        let i = 0;
        while (i < len) {
            smart_vector::pop_back(&mut snapshots);
            i = i + 1;
        };
        smart_vector::destroy_empty(snapshots);
    }
}
