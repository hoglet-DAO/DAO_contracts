module dao_libs::format {
    use std::string::{Self, String};
    use aptos_std::string_utils;

    public fun format_ve_nft_name(symbol: String, mint_count: u64): String {
        let token_name = string::utf8(b"ve");
        string::append(&mut token_name, symbol);
        string::append(&mut token_name, string::utf8(b" #"));
        string::append(&mut token_name, string_utils::to_string(&mint_count));
        token_name
    }

    public fun format_ve_nft_uri(base_uri: String, obj_addr: address): String {
        let uri = if (string::is_empty(&base_uri)) {
            string::utf8(b"https://daos.hoglet.xyz/api/nft/")
        } else {
            base_uri
        };
        let addr_str = string_utils::to_string(&obj_addr);
        let addr_bytes = string::bytes(&addr_str);
        let len = std::vector::length(addr_bytes);
        if (len > 0 && *std::vector::borrow(addr_bytes, 0) == 64u8) {
            let stripped = string::sub_string(&addr_str, 1, len);
            string::append(&mut uri, stripped);
        } else {
            string::append(&mut uri, addr_str);
        };
        uri
    }
}
