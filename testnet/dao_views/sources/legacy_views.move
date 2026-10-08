// Batch views extracted from dao_factory::legacy (v2 refactor).
//
// Lives in its own package so the loops below do not count against the core
// package size limit. Semantics are identical to the original
// legacy::get_batch_nft_metadata: it only consumes public APIs of the core
// package (legacy::ve_info, legacy::max_lock_epochs), so no friend access
// and no access to private state is required here.
module dao_views::legacy_views {
    use std::vector;

    use dao_factory::legacy;
    use dao_libs::math;
    use dao_libs::pilgrim;

    /// Batch read of veToken metadata for a DAO.
    /// NFTs that do not host a VeToken of `target_dao` are skipped silently.
    ///
    /// NOTE: `valid_nfts` only means "hosts a VeToken of this DAO" it does
    /// NOT check who owns the token. veNFTs are transferable 0x4 objects, so
    /// callers that need the current holder must use
    /// `get_owned_nft_metadata` instead.
    #[view]
    public fun get_batch_nft_metadata(nfts: vector<address>, target_dao: address): (
        vector<address>, // valid_nfts
        vector<u64>,     // amounts
        vector<u64>,     // end_epochs
        vector<u64>,     // powers
        vector<bool>,    // is_delegated
        u64              // current_epoch
    ) {
        let (valid_nfts, amounts, end_epochs, powers, delegated_flags, _, current_epoch) =
            get_owned_nft_metadata(nfts, target_dao, vector::empty<address>());
        (valid_nfts, amounts, end_epochs, powers, delegated_flags, current_epoch)
    }

    /// Batch read of veToken metadata **owned by** `owner`.
    ///
    /// Same shape as `get_batch_nft_metadata`, plus an `owners` vector aligned
    /// with the other outputs. A token is included only when its current 0x4
    /// owner is in the `owners` allow-list, so a caller can never receive a
    /// veNFT that was transferred away. Pass an empty `owners` to disable the
    /// filter (equivalent to `get_batch_nft_metadata`, but with owners).
    ///
    /// `current_owner` is read live from the core (`legacy::get_owner_by_address`
    /// -> `object::owner`), the same source of truth the contract's own
    /// `verify_owner_and_get_legacy` guard uses when mutating a lock.
    #[view]
    public fun get_owned_nft_metadata(
        nfts: vector<address>,
        target_dao: address,
        owners: vector<address>,
    ): (
        vector<address>, // valid_nfts
        vector<u64>,     // amounts
        vector<u64>,     // end_epochs
        vector<u64>,     // powers
        vector<bool>,    // is_delegated
        vector<address>, // owners (aligned with valid_nfts)
        u64              // current_epoch
    ) {
        let valid_nfts = vector::empty<address>();
        let amounts = vector::empty<u64>();
        let end_epochs = vector::empty<u64>();
        let powers = vector::empty<u64>();
        let delegated_flags = vector::empty<bool>();
        let out_owners = vector::empty<address>();
        let current_epoch = pilgrim::now();
        let max_epochs = legacy::max_lock_epochs();
        let filter_by_owner = !vector::is_empty(&owners);

        let i = 0;
        let len = vector::length(&nfts);
        while (i < len) {
            let nft_addr = *vector::borrow(&nfts, i);
            let (valid, locked_amount, end_epoch, is_delegated) = legacy::ve_info(nft_addr, target_dao);
            if (valid) {
                // Authoritative current holder. Read through the core's
                // `get_owner_by_address` view: `VeToken` is a private type of
                // the core package, so this module cannot name it to call
                // `object::owner<VeToken>` directly.
                let current_owner = legacy::get_owner_by_address(nft_addr);
                if (!filter_by_owner || vector::contains(&owners, &current_owner)) {
                    let epochs_left = if (end_epoch > current_epoch) { end_epoch - current_epoch } else { 0 };
                    let power = math::mul_div_u64(locked_amount, epochs_left, max_epochs);

                    vector::push_back(&mut valid_nfts, nft_addr);
                    vector::push_back(&mut amounts, locked_amount);
                    vector::push_back(&mut end_epochs, end_epoch);
                    vector::push_back(&mut powers, power);
                    vector::push_back(&mut delegated_flags, is_delegated);
                    vector::push_back(&mut out_owners, current_owner);
                };
            };
            i = i + 1;
        };

        (valid_nfts, amounts, end_epochs, powers, delegated_flags, out_owners, current_epoch)
    }
}
