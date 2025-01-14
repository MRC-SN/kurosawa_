
use kurosawa_akira::utils::account::{AccountABIDispatcherTrait, AccountABIDispatcher};
use starknet::ContractAddress;

fn check_sign(account: ContractAddress, hash: felt252, sign: Span<felt252>) -> bool {
    let mut calldata = ArrayTrait::new();
    calldata.append_span(sign);
    let res = AccountABIDispatcher{contract_address:account}.is_valid_signature(hash, calldata);
    return res == 'VALID';
}