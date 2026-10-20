// Snapshot types + scan/upsert helpers extracted from dao_libs::legacy
// (v2 refactor).
//
// The struct definitions live HERE (not in a separate types module) because
// Move restricts field access and struct construction to the module that
// declares the struct. dao_libs::legacy constructs snapshots via
// scan::new_snapshot; everything else stays inside this module.
//
// SECURITY NOTE: every function below is byte-for-byte equivalent to the
// inline logic it replaces (including the VULN-04 fix: querying a power
// before the first snapshot returns 0). The logic moved here so the loops
// do not count against the core package size limit.
module dao_libs::scan {
    use aptos_std::smart_vector::{Self, SmartVector};
    use aptos_std::smart_table::{Self, SmartTable};
    use dao_libs::math;

    // Voting-power snapshot of a veToken at a given epoch.
    // Same fields and abilities (copy, drop, store) as the original private
    // struct in legacy.move, so storage semantics are unchanged.
    struct Snapshot has copy, drop, store {
        pilgrim: u64,
        locked_amount: u64,
        end_epoch: u64,
    }

    // Snapshot of a DAO registry's total locked amount and total voting power at a given epoch.
    struct RegistrySnapshot has copy, drop, store {
        pilgrim: u64,
        total_locked: u64,
        total_voting_power: u64,
    }

    // Public constructor for Snapshot (struct literals are restricted to
    // the defining module).
    public fun new_snapshot(pilgrim: u64, locked_amount: u64, end_epoch: u64): Snapshot {
        Snapshot {
            pilgrim: pilgrim,
            locked_amount: locked_amount,
            end_epoch: end_epoch,
        }
    }

    // Voting power of a lock at `query_epoch`.
    //
    // `locked_amount` / `end_epoch` are the veToken's CURRENT values and are
    // used as fallback when no snapshot qualifies (original semantics of
    // legacy::get_voting_power_at).
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

    // Total locked of a DAO at `query_epoch`.
    //
    // Returns 0 when there is no history or the query predates the first
    // snapshot (original semantics of legacy::get_total_locked_at).
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

    // Total voting power of a DAO at `query_epoch`.
    //
    // Returns 0 when there is no history or the query predates the first snapshot.
    public fun total_voting_power_at(snapshots: &SmartVector<RegistrySnapshot>, query_epoch: u64): u64 {
        let len = smart_vector::length(snapshots);
        if (len == 0) return 0;

        let first_snap = smart_vector::borrow(snapshots, 0);
        if (query_epoch < first_snap.pilgrim) return 0;

        let i = len;
        while (i > 0) {
            i = i - 1;
            let snap = smart_vector::borrow(snapshots, i);
            if (snap.pilgrim <= query_epoch) {
                return snap.total_voting_power
            };
        };
        0
    }

    // Upserts the voting-power snapshot for `epoch`: updates the last
    // snapshot if it belongs to this epoch, otherwise appends a new one.
    // (Extracted from legacy::upsert_snapshot.)
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

    // Same upsert for the registry's total-locked and total-voting-power history.
    // (Extracted from legacy::update_total_locked_history.)
    public fun upsert_registry_snapshot(
        snapshots: &mut SmartVector<RegistrySnapshot>,
        epoch: u64,
        total_locked: u64,
        total_voting_power: u64,
    ) {
        let len = smart_vector::length(snapshots);
        if (len > 0 && smart_vector::borrow(snapshots, len - 1).pilgrim == epoch) {
            let snap = smart_vector::borrow_mut(snapshots, len - 1);
            snap.total_locked = total_locked;
            snap.total_voting_power = total_voting_power;
        } else {
            smart_vector::push_back(snapshots, RegistrySnapshot {
                pilgrim: epoch,
                total_locked: total_locked,
                total_voting_power: total_voting_power,
            });
        };
    }

    // Drains and destroys a snapshots vector (extracted from
    // legacy::destroy_snapshots).
    public fun destroy_all<T: drop>(snapshots: SmartVector<T>) {
        let len = smart_vector::length(&snapshots);
        let i = 0;
        while (i < len) {
            smart_vector::pop_back(&mut snapshots);
            i = i + 1;
        };
        smart_vector::destroy_empty(snapshots);
    }

    // Calculates a lock's weekly decay slope: amount / max_lock_epochs (floored at 1 if amount > 0).
    public fun calculate_lock_slope(amount: u64, max_lock_epochs: u64): u64 {
        math::mul_div_u64(amount, 1, max_lock_epochs)
    }

    // Calculates a lock's voting power at a given remaining epochs duration.
    // Invariant: power == slope * epochs_left to prevent phantom voting power and quorum decay drift.
    public fun calculate_lock_power(amount: u64, epochs_left: u64, max_lock_epochs: u64): u64 {
        let slope = calculate_lock_slope(amount, max_lock_epochs);
        slope * epochs_left
    }

    // Advances bias and slope from `from_epoch` up to `target_epoch`, applying scheduled slope changes.
    // Returns (new_epoch, new_bias, new_slope).
    public fun advance_ve_decay(
        from_epoch: u64,
        bias: u64,
        slope: u64,
        slope_changes: &SmartTable<u64, u64>,
        target_epoch: u64,
    ): (u64, u64, u64) {
        let e = from_epoch;
        while (e < target_epoch) {
            e = e + 1;
            if (bias > slope) {
                bias = bias - slope;
            } else {
                bias = 0;
            };
            if (smart_table::contains(slope_changes, e)) {
                let d_slope = *smart_table::borrow(slope_changes, e);
                if (slope > d_slope) {
                    slope = slope - d_slope;
                } else {
                    slope = 0;
                };
            };
        };
        (e, bias, slope)
    }

    // Simulates decayed voting power at `query_epoch` given starting epoch, bias, slope,
    // and scheduled slope changes.
    public fun simulate_decay_power(
        from_epoch: u64,
        bias: u64,
        slope: u64,
        slope_changes: &SmartTable<u64, u64>,
        query_epoch: u64,
    ): u64 {
        if (query_epoch <= from_epoch) {
            return bias
        };
        let (_, final_bias, _) = advance_ve_decay(from_epoch, bias, slope, slope_changes, query_epoch);
        final_bias
    }

    // Adds a slope delta scheduled to expire at `epoch`.
    public fun add_slope_change(
        slope_changes: &mut SmartTable<u64, u64>,
        epoch: u64,
        slope: u64,
    ) {
        if (!smart_table::contains(slope_changes, epoch)) {
            smart_table::add(slope_changes, epoch, slope);
        } else {
            let cur = smart_table::borrow_mut(slope_changes, epoch);
            *cur = *cur + slope;
        };
    }

    // Removes or decrements a slope delta scheduled to expire at `epoch`.
    public fun sub_slope_change(
        slope_changes: &mut SmartTable<u64, u64>,
        epoch: u64,
        slope: u64,
    ) {
        if (smart_table::contains(slope_changes, epoch)) {
            let cur = smart_table::borrow_mut(slope_changes, epoch);
            if (*cur > slope) {
                *cur = *cur - slope;
            } else {
                smart_table::remove(slope_changes, epoch);
            };
        };
    }

    // Advances the global ve-supply decay to current_epoch
    public fun checkpoint_supply(
        last_epoch: &mut u64,
        last_bias: &mut u64,
        last_slope: &mut u64,
        slope_changes: &SmartTable<u64, u64>,
        current_epoch: u64,
    ) {
        if (*last_epoch == 0) {
            *last_epoch = current_epoch;
            return
        };
        if (current_epoch <= *last_epoch) {
            return
        };

        let (new_epoch, new_bias, new_slope) = advance_ve_decay(
            *last_epoch,
            *last_bias,
            *last_slope,
            slope_changes,
            current_epoch,
        );

        *last_epoch = new_epoch;
        *last_bias = new_bias;
        *last_slope = new_slope;
    }

    // Records a brand-new lock into global ve-supply
    public fun record_new_lock(
        last_epoch: &mut u64,
        last_bias: &mut u64,
        last_slope: &mut u64,
        slope_changes: &mut SmartTable<u64, u64>,
        amount: u64,
        end_epoch: u64,
        current_epoch: u64,
        max_lock_epochs: u64,
    ) {
        checkpoint_supply(last_epoch, last_bias, last_slope, slope_changes, current_epoch);
        if (amount == 0 || end_epoch <= current_epoch) return;

        let lock_epochs = end_epoch - current_epoch;
        let power = calculate_lock_power(amount, lock_epochs, max_lock_epochs);
        let slope = calculate_lock_slope(amount, max_lock_epochs);

        *last_bias = *last_bias + power;
        *last_slope = *last_slope + slope;

        add_slope_change(slope_changes, end_epoch, slope);
    }

    // Updates global ve-supply when a lock's amount and/or duration changes
    public fun record_lock_delta(
        last_epoch: &mut u64,
        last_bias: &mut u64,
        last_slope: &mut u64,
        slope_changes: &mut SmartTable<u64, u64>,
        old_amount: u64,
        old_end: u64,
        new_amount: u64,
        new_end: u64,
        current_epoch: u64,
        max_lock_epochs: u64,
    ) {
        checkpoint_supply(last_epoch, last_bias, last_slope, slope_changes, current_epoch);

        // Remove old contribution if was active
        if (old_amount > 0 && old_end > current_epoch) {
            let old_left = old_end - current_epoch;
            let old_power = calculate_lock_power(old_amount, old_left, max_lock_epochs);
            let old_slope = calculate_lock_slope(old_amount, max_lock_epochs);

            if (*last_bias > old_power) {
                *last_bias = *last_bias - old_power;
            } else {
                *last_bias = 0;
            };

            if (*last_slope > old_slope) {
                *last_slope = *last_slope - old_slope;
            } else {
                *last_slope = 0;
            };

            sub_slope_change(slope_changes, old_end, old_slope);
        };

        // Add new contribution if active
        if (new_amount > 0 && new_end > current_epoch) {
            let new_left = new_end - current_epoch;
            let new_power = calculate_lock_power(new_amount, new_left, max_lock_epochs);
            let new_slope = calculate_lock_slope(new_amount, max_lock_epochs);

            *last_bias = *last_bias + new_power;
            *last_slope = *last_slope + new_slope;

            add_slope_change(slope_changes, new_end, new_slope);
        };
    }

    // Called when a lock is destroyed before its end_epoch (e.g. merge)
    public fun record_remove_lock(
        last_epoch: &mut u64,
        last_bias: &mut u64,
        last_slope: &mut u64,
        slope_changes: &mut SmartTable<u64, u64>,
        amount: u64,
        end_epoch: u64,
        current_epoch: u64,
        max_lock_epochs: u64,
    ) {
        record_lock_delta(last_epoch, last_bias, last_slope, slope_changes, amount, end_epoch, 0, 0, current_epoch, max_lock_epochs);
    }
}
