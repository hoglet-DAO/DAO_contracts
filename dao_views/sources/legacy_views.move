// Batch views extracted from dao_factory::legacy (v2 refactor).
//
// Lives in its own package so the loops below do not count against the core
// package size limit. Semantics are identical to the original
// legacy::get_batch_nft_metadata: it only consumes public APIs of the core
// package (legacy::ve_info, legacy::max_lock_epochs), so no friend access
// and no access to private state is required here.
module dao_factory::legacy_views {
    use std::vector;

    use dao_factory::legacy;
    use dao_factory::math;
    use dao_factory::pilgrim;

    /// Batch read of veToken metadata for a DAO.
    /// NFTs that do not host a VeToken of `target_dao` are skipped silently.
    #[view]
    public fun get_batch_nft_metadata(nfts: vector<address>, target_dao: address): (
        vector<address>, // valid_nfts
        vector<u64>,     // amounts
        vector<u64>,     // end_epochs
        vector<u64>,     // powers
        vector<bool>,    // is_delegated
        u64              // current_epoch
    ) {
        let valid_nfts = vector::empty<address>();
        let amounts = vector::empty<u64>();
        let end_epochs = vector::empty<u64>();
        let powers = vector::empty<u64>();
        let delegated_flags = vector::empty<bool>();
        let current_epoch = pilgrim::now();
        let max_epochs = legacy::max_lock_epochs();

        let i = 0;
        let len = vector::length(&nfts);
        while (i < len) {
            let nft_addr = *vector::borrow(&nfts, i);
            let (valid, locked_amount, end_epoch, is_delegated) = legacy::ve_info(nft_addr, target_dao);
            if (valid) {
                let epochs_left = if (end_epoch > current_epoch) { end_epoch - current_epoch } else { 0 };
                let power = math::mul_div_u64(locked_amount, epochs_left, max_epochs);

                vector::push_back(&mut valid_nfts, nft_addr);
                vector::push_back(&mut amounts, locked_amount);
                vector::push_back(&mut end_epochs, end_epoch);
                vector::push_back(&mut powers, power);
                vector::push_back(&mut delegated_flags, is_delegated);
            };
            i = i + 1;
        };

        (valid_nfts, amounts, end_epochs, powers, delegated_flags, current_epoch)
    }
}
