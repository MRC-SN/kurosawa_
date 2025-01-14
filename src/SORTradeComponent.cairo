



use kurosawa_akira::Order::{SignedOrder,Order,get_gas_fee_and_coin, OrderTradeInfo, OrderFee, FixedFee,GasFee,
            get_feeable_qty,get_limit_px, do_taker_price_checks, do_maker_checks, get_available_base_qty, generic_taker_check,generic_common_check,TakerSelfTradePreventionMode};


#[starknet::interface]
trait ISORTradeLogic<TContractState> {
    
}

#[starknet::component]
mod sor_trade_component {
    use starknet::{get_contract_address, ContractAddress, get_caller_address, get_tx_info};
    use super::{SignedOrder, Order};
    use kurosawa_akira::BaseTradeComponent::base_trade_component as  base_trade_component;
    use base_trade_component::InternalBaseOrderTradable;

    
    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {}


    #[storage]
    struct Storage {
        atomic_taker_info:(felt252, (felt252, felt252)), // hash lock, router sign
        scheduled_taker_order: Order
    }




    #[embeddable_as(SORTradable)]
    impl SOROrderTradableImpl<TContractState, 
    +HasComponent<TContractState>,
    impl BaseTrade:base_trade_component::HasComponent<TContractState>,
    +Drop<TContractState>> of super::ISORTradeLogic<ComponentState<TContractState>> {}

     #[generate_trait]
    impl InternalSORTradableImpl<TContractState, +HasComponent<TContractState>, +Drop<TContractState> ,
        impl BaseTrade:base_trade_component::HasComponent<TContractState> > of InternalSORTradable<TContractState> {

        fn placeTakerOrder(ref self: ComponentState<TContractState>, order: Order, router_sign: (felt252,felt252)) {
            let (hash_lock, _) = self.atomic_taker_info.read();
            assert(hash_lock == 0, 'Lock already acquired');
            assert(order.maker == get_caller_address(), 'Maker must be caller');
            
            let tx_info = get_tx_info().unbox();
            self.atomic_taker_info.write((tx_info.transaction_hash, router_sign));
            self.scheduled_taker_order.write(order);
        }


        fn fullfillTakerOrder(ref self: ComponentState<TContractState>, mut maker_orders:Array<(SignedOrder,u256)>,
                        total_amount_matched:u256, gas_steps:u32, gas_price:u256) {
            let (hash_lock, router_signature) = self.atomic_taker_info.read();            
            let tx_info = get_tx_info().unbox();
            
            assert(hash_lock == tx_info.transaction_hash, 'Lock not acquired');

            let mut base_trade = get_dep_component_mut!(ref self, BaseTrade);
            base_trade.apply_single_taker(
                SignedOrder{order:self.scheduled_taker_order.read(), sign: array![].span(), router_sign:router_signature},
                maker_orders, total_amount_matched, gas_price, gas_steps, true, true);
            // release lock
            self.atomic_taker_info.write((0, (0,0)));
        }


        
    }

}