use core::option::OptionTrait;
use core::traits::TryInto;
use starknet::{
    contract_address_const, get_tx_info, get_caller_address, testing::set_caller_address,ContractAddress, get_contract_address
};
use pedersen::PedersenTrait;
use hash::{HashStateTrait, HashStateExTrait};
use super::IOffchainMessage::{IOffchainMessageHash,IStructHash,SNIP12Metadata};
use super::V0OffchainMessage::{StructHashU256Impl, OffchainMessageHashImpl};
use kurosawa_akira::WithdrawComponent::{Withdraw};
use kurosawa_akira::Order::{Order,FixedFee,GasFee,TakerSelfTradePreventionMode, Quantity, Constraints, OrderFlags,OrderFee};
use kurosawa_akira::NonceComponent::{IncreaseNonce};    


impl SNIP12MetadataImpl of SNIP12Metadata {
    fn name() -> felt252 { 'LayerAkira Exchange'}
    fn version() -> felt252 { '0.0.1'}
}



// const GASFEE_TYPE_HASH: felt252 = selector!("GasFee(gas_per_action:felt,fee_token:felt,max_gas_price:u256,r0:u256,r1:u256)u256(low:felt,high:felt)");
const GASFEE_TYPE_HASH: felt252 = 0x1A39CA962D62DDE02988F6E3C3D248A70555CE48D84681FC67115E8C25F5927;
impl GasFeeHashImpl of IStructHash<GasFee> {
    
    fn hash_struct(self: @GasFee) -> felt252 {
        let mut state = PedersenTrait::new(0);
        state = state.update_with(GASFEE_TYPE_HASH);
        state = state.update_with(*self.gas_per_action);
        state = state.update_with(*self.fee_token);
        state = state.update_with(self.max_gas_price.hash_struct());
        let (r0,r1) = self.conversion_rate;
        state = state.update_with(r0.hash_struct());
        state = state.update_with(r1.hash_struct());
        state = state.update_with(6);
        state.finalize()
    }
}

//  ORDER


// const FIXEDFEE_TYPE_HASH: felt252 = selector!("FixedFee(recipient:felt,maker_pbips:felt,taker_pbips:felt,apply_to_receipt_amount:bool)");
const FIXEDFEE_TYPE_HASH: felt252 = 0x224AC2D1E75629D974CA4E9C46175C31807D2794D41AD53DF8E07707EF194E6;
impl FixedFeeHashImpl of IStructHash<FixedFee> {
    fn hash_struct(self: @FixedFee) -> felt252 {
        let mut state = PedersenTrait::new(0);
        state = state.update_with(FIXEDFEE_TYPE_HASH);
        state = state.update_with(*self);
        state = state.update_with(5);
        state.finalize()
    }
}


// const ORDERFEE_TYPE_HASH: felt252 = selector!("OrderFee(trade_fee:FixedFee,router_fee:FixedFee,gas_fee:GasFee)FixedFee(recipient:felt,maker_pbips:felt,taker_pbips:felt,apply_to_receipt_amount:bool)GasFee(gas_per_action:felt,fee_token:felt,max_gas_price:u256,r0:u256,r1:u256)u256(low:felt,high:felt)");
const ORDERFEE_TYPE_HASH: felt252 = 0x1F94C7EFA9BAE1115ADFC49506561EEA74C584CC6ECA6B0D2E210E87615A89E;
impl OrderFeeHashImpl of IStructHash<OrderFee> {
    fn hash_struct(self: @OrderFee) -> felt252 {
        let mut state = PedersenTrait::new(0);
        state = state.update_with(ORDERFEE_TYPE_HASH);
        state = state.update_with(self.trade_fee.hash_struct());
        state = state.update_with(self.router_fee.hash_struct());
        state = state.update_with(self.gas_fee.hash_struct());
        state = state.update_with(4);
        state.finalize()
    }
}

// const ORDERFLAGS_TYPE_HASH: felt252 = selector!("OrderFlags(full_fill_only:bool,best_level_only:bool,post_only:bool,is_sell_side:bool,is_market_order:bool,to_ecosystem_book:bool,external_funds:bool)");
const ORDERFLAGS_TYPE_HASH: felt252 =  0xf4acda9e8bbf75928080965997bf8f485abcc2113a9d8b08fc2a30249988e3;
impl OrderFlagsHashImpl of IStructHash<OrderFlags> {
    fn hash_struct(self: @OrderFlags) -> felt252 {
        let mut state = PedersenTrait::new(0);
        state = state.update_with(ORDERFLAGS_TYPE_HASH);
        state = state.update_with(*self);
        state = state.update_with(8);
        state.finalize()
    }
}


// const QUANTITY_TYPE_HASH: felt252 = selector!("Quantity(base_qty:u256,quote_qty:u256,base_asset:u256)u256(low:felt,high:felt)");
const QUANTITY_TYPE_HASH: felt252 =  0x86a677a4608ab4c497f6157ac95210589a82883be0665f34e7cbf80c65bd5d;
impl QuantityHashImpl of IStructHash<Quantity> {
    fn hash_struct(self: @Quantity) -> felt252 {
        let mut state = PedersenTrait::new(0);
        state = state.update_with(QUANTITY_TYPE_HASH);
        state = state.update_with(self.base_qty.hash_struct());
        state = state.update_with(self.quote_qty.hash_struct());
        state = state.update_with(self.base_asset.hash_struct());
        state = state.update_with(4);
        state.finalize()
    }
}

// const CONSTRAINTS_TYPE_HASH: felt252 = selector!("Constraints(number_of_swaps_allowed:felt,duration_valid:felt,created_at:felt,stp:felt,nonce:felt,min_receive_amount:u256,router_signer:felt)u256(low:felt,high:felt)");
const CONSTRAINTS_TYPE_HASH: felt252 = 0x15AD6B6E2857A7B2A494F79AD1051D9BE921C5B5A8AF916675B7A4B5FECE5E8;
impl ConstraintsHashImpl of IStructHash<Constraints> {
    fn hash_struct(self: @Constraints) -> felt252 {
        let mut state = PedersenTrait::new(0);
        state = state.update_with(CONSTRAINTS_TYPE_HASH);
        state = state.update_with(*self.number_of_swaps_allowed);
        state = state.update_with(*self.duration_valid);
        state = state.update_with(*self.created_at);
        state = match self.stp {
            TakerSelfTradePreventionMode::NONE => { state.update_with(0x0)},
            TakerSelfTradePreventionMode::EXPIRE_TAKER => {state.update_with(0x1)},
            TakerSelfTradePreventionMode::EXPIRE_MAKER => {state.update_with(0x2)},
            TakerSelfTradePreventionMode::EXPIRE_BOTH => { state.update_with(0x3)}
        };
        state = state.update_with(*self.nonce);
        state = state.update_with(self.min_receive_amount.hash_struct());
        state = state.update_with(*self.router_signer);
        state = state.update_with(8);
        state.finalize()
    }
}

// const ORDER_TYPE_HASH: felt252 = selector!("Order(maker:felt,price:u256,qty:Quantity,base:felt,quote:felt,fee:OrderFee,constraints:Constraints,salt:felt,flags:OrderFlags,exchange:felt,source:felt,sign_scheme:felt)Constraints(number_of_swaps_allowed:felt,duration_valid:felt,created_at:felt,stp:felt,nonce:felt,min_receive_amount:u256,router_signer:felt)FixedFee(recipient:felt,maker_pbips:felt,taker_pbips:felt,apply_to_receipt_amount:bool)GasFee(gas_per_action:felt,fee_token:felt,max_gas_price:u256,r0:u256,r1:u256)OrderFee(trade_fee:FixedFee,router_fee:FixedFee,gas_fee:GasFee)OrderFlags(full_fill_only:bool,best_level_only:bool,post_only:bool,is_sell_side:bool,is_market_order:bool,to_ecosystem_book:bool,external_funds:bool)Quantity(base_qty:u256,quote_qty:u256,base_asset:u256)u256(low:felt,high:felt)");
const ORDER_TYPE_HASH: felt252 =  0x2D20F9714788913E1DE79742F8518B427FE1E7398AB0FBDD61C840EE79C1AD3;
impl OrderHashImpl of IStructHash<Order> {
    fn hash_struct(self: @Order) -> felt252 {
        let mut state = PedersenTrait::new(0);
        state = state.update_with(ORDER_TYPE_HASH);
        state = state.update_with(*self.maker);
        state = state.update_with(self.price.hash_struct());
        state = state.update_with(self.qty.hash_struct());
        let (b,q) = *self.ticker;
        state = state.update_with(b);
        state = state.update_with(q);
        state = state.update_with(self.fee.hash_struct());
        state = state.update_with(self.constraints.hash_struct());
        state = state.update_with(*self.salt);
        state = state.update_with(self.flags.hash_struct());
        state = state.update_with(get_contract_address());
        state = state.update_with(*self.source);
        state = state.update_with(*self.sign_scheme);
        state = state.update_with(13);
        state.finalize()
    }
}

// const WITHDRAW_TYPE_HASH: felt252 = 
    // selector!("Withdraw(maker:felt,token:felt,amount:u256,salt:felt,gas_fee:GasFee,receiver:felt,exchange:felt,sign_scheme:felt)GasFee(gas_per_action:felt,fee_token:felt,max_gas_price:u256,r0:u256,r1:u256)u256(low:felt,high:felt)");
const WITHDRAW_TYPE_HASH: felt252 = 0x2BEA416E56C3B164D794221F7BE94992DBA648F7DF4B3CDC2C9E9EE9131DC68;
impl WithdrawHashImpl of IStructHash<Withdraw> {
    fn hash_struct(self: @Withdraw) -> felt252 {
        let mut state = PedersenTrait::new(0);
        state = state.update_with(WITHDRAW_TYPE_HASH);
        state = state.update_with(*self.maker);
        state = state.update_with(*self.token);
        state = state.update_with(self.amount.hash_struct());
        state = state.update_with(*self.salt);
        state = state.update_with(self.gas_fee.hash_struct());
        state = state.update_with(*self.receiver);
        state = state.update_with(get_contract_address());
        state = state.update_with(*self.sign_scheme);
        state = state.update_with(9);
        state.finalize()
    }
}


// const NONCE_TYPE_HASH: felt252 = 
//     selector!("OnchainCancelAll(maker:felt,new_nonce:felt,gas_fee:GasFee,sign_scheme:felt)GasFee(gas_per_action:felt,fee_token:felt,max_gas_price:u256,r0:u256,r1:u256)u256(low:felt,high:felt)");
const NONCE_TYPE_HASH: felt252 = 0x1419e39e06e7e76ddc32635d95dee09599a35d2c8687fc87e22c6e6a803f578;
impl IncreaseNonceHashImpl of IStructHash<IncreaseNonce> {
    fn hash_struct(self: @IncreaseNonce) -> felt252 {
        let mut state = PedersenTrait::new(0);
        state = state.update_with(NONCE_TYPE_HASH);
        state = state.update_with(*self.maker);
        state = state.update_with(*self.new_nonce);
        state = state.update_with(self.gas_fee.hash_struct());
        state = state.update_with(*self.sign_scheme);
        state = state.update_with(5);
        state.finalize()
    }
}
