// Shared SmartTable read helpers.
//
// Lives in dao_libs (deployed under its own address) so the bytecode is
// NOT part of the dao_factory package size. Every "contains ? borrow : 0"
// block replaced by a call here removes ~50-60 bytes from dao_factory.
module dao_factory::table {
    use aptos_std::smart_table::{Self, SmartTable};

    /// Reads a u128 from a SmartTable, returning 0 when the key is absent.
    public fun u128_or_zero<K: copy + drop>(t: &SmartTable<K, u128>, k: K): u128 {
        if (smart_table::contains(t, copy k)) {
            *smart_table::borrow(t, k)
        } else {
            0
        }
    }

    /// Reads a u64 from a SmartTable, returning 0 when the key is absent.
    public fun u64_or_zero<K: copy + drop>(t: &SmartTable<K, u64>, k: K): u64 {
        if (smart_table::contains(t, copy k)) {
            *smart_table::borrow(t, k)
        } else {
            0
        }
    }
}
