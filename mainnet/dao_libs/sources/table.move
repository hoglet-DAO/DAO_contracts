// Shared SmartTable read helpers.
//
// Lives in dao_libs (deployed under its own address) so the bytecode is
// NOT part of the dao_libs package size. Every "contains ? borrow : 0"
// block replaced by a call here removes ~50-60 bytes from dao_libs.
module dao_libs::table {
    use aptos_std::smart_table::{Self, SmartTable};
    use std::vector;

    // Reads a u128 from a SmartTable, returning 0 when the key is absent.
    public fun u128_or_zero<K: copy + drop>(t: &SmartTable<K, u128>, k: K): u128 {
        if (smart_table::contains(t, copy k)) {
            *smart_table::borrow(t, k)
        } else {
            0
        }
    }

    // Reads a u64 from a SmartTable, returning 0 when the key is absent.
    public fun u64_or_zero<K: copy + drop>(t: &SmartTable<K, u64>, k: K): u64 {
        if (smart_table::contains(t, copy k)) {
            *smart_table::borrow(t, k)
        } else {
            0
        }
    }

    // Appends `addr` to the vector only when absent. Returns true when inserted.
    // Pure vector logic: no storage, no authority, safe as a public helper.
    public fun push_unique(v: &mut vector<address>, addr: address): bool {
        if (vector::contains(v, &addr)) {
            false
        } else {
            vector::push_back(v, addr);
            true
        }
    }

    // Removes `addr` from the vector when present. Returns true when removed.
    public fun remove_if_present(v: &mut vector<address>, addr: address): bool {
        let (found, index) = vector::index_of(v, &addr);
        if (found) {
            vector::remove(v, index);
            true
        } else {
            false
        }
    }
}
