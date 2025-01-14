
use starknet::ContractAddress;
use kurosawa_akira::Order::GasFee;
use kurosawa_akira::ExchangeBalanceComponent::{get_gas_fee_and_coin};
use serde::Serde;
use kurosawa_akira::utils::SlowModeLogic::SlowModeDelay;

#[starknet::interface]
trait IExternalGrantor<TContractState> {
    
    fn balance_of_router(self:@TContractState, router:ContractAddress, coin:ContractAddress)->u256;

    
    // validates that message was signed by signer that mapped to router
    fn validate_router(self: @TContractState, message: felt252, signature: (felt252, felt252), signer: ContractAddress, router:ContractAddress) -> bool;

    fn get_punishment_factor_bips(self: @TContractState) -> u16;

    fn is_registered(self: @TContractState, router: ContractAddress) -> bool;

    fn have_sufficient_amount_to_route(self: @TContractState, router:ContractAddress) -> bool;

    // get router address associated with given signer
    fn get_router(self:@TContractState, signer:ContractAddress) -> ContractAddress;

    // how much one must hold have in balance to be registered as router
    fn get_route_amount(self:@TContractState) -> u256;


    fn router_deposit(ref self:TContractState, router:ContractAddress, coin:ContractAddress, amount:u256);
    
    //  native  token can be withdrawn up to amount specified to be eligible of being router
    fn router_withdraw(ref self: TContractState, coin: ContractAddress, amount: u256, receiver:ContractAddress);
    
    // register router so the required amount is held while he is router
    fn register_router(ref self: TContractState);

    // if router wish to bind new signers
    fn transfer_to_core(ref self: TContractState, router:ContractAddress,token:ContractAddress, amount:u256) -> u256;

    fn add_router_binding(ref self: TContractState, signer: ContractAddress);
    fn get_base_token(self:@TContractState)-> ContractAddress;

    fn grant_access_to_executor(ref self: TContractState);
    fn set_executor(ref self: TContractState, new_executor:ContractAddress);



}


#[starknet::contract]
mod LayerAkiraExternalGrantor{
    use starknet::{ContractAddress, get_caller_address, get_tx_info};
    use kurosawa_akira::utils::SlowModeLogic::SlowModeDelay;
    use starknet::{get_contract_address};
    
    use kurosawa_akira::RouterComponent::router_component as router_component;
    use kurosawa_akira::AccessorComponent::accessor_logic_component as  accessor_logic_component;
    use kurosawa_akira::LayerAkiraCore::{ILayerAkiraCoreDispatcherTrait, ILayerAkiraCoreDispatcher};

    use router_component::InternalRoutable;
    use accessor_logic_component::InternalAccesorable;
    
    
    component!(path: router_component, storage: router_s, event:RouterEvent);
    component!(path: accessor_logic_component, storage: accessor_s, event:AccessorEvent);
    
    
    #[abi(embed_v0)]
    impl RoutableImpl = router_component::Routable<ContractState>;
    #[abi(embed_v0)]
    impl AccsesorableImpl = accessor_logic_component::Accesorable<ContractState>;
    
    #[storage]
    struct Storage {
        #[substorage(v0)]
        router_s: router_component::Storage,

        #[substorage(v0)]
        accessor_s: accessor_logic_component::Storage,
        max_slow_mode_delay:SlowModeDelay, // upper bound for all delayed actions
    }



    #[constructor]
    fn constructor(ref self: ContractState,
                max_slow_mode_delay:SlowModeDelay, 
                min_to_route:u256, // minimum amount neccesary to start to provide 
                owner:ContractAddress,
                core_address:ContractAddress
        ) {
        self.max_slow_mode_delay.write(max_slow_mode_delay);
        self.router_s.initializer(max_slow_mode_delay, core_address, min_to_route, 10_000);
        self.accessor_s.owner.write(owner);
        self.accessor_s.executor.write(0.try_into().unwrap());
        self.accessor_s.executor_epoch.write(0);
    }


    #[external(v0)]
    fn update_router_component_params(ref self: ContractState, new_delay:SlowModeDelay, min_amount_to_route:u256, new_punishment_bips:u16) {
        self.accessor_s.only_owner();
        let max = self.max_slow_mode_delay.read();
        assert!(new_delay.block <= max.block && new_delay.ts <= max.ts, "Failed router params update: new_delay <= max_slow_mode_delay");
        self.router_s.r_delay.write(new_delay);
        self.router_s.min_to_route.write(min_amount_to_route);
        self.router_s.punishment_bips.write(new_punishment_bips);
        self.emit(RouterComponentUpdate{new_delay,min_amount_to_route,new_punishment_bips});
    }

    #[external(v0)]
    fn transfer_to_core(ref self: ContractState, router:ContractAddress, token:ContractAddress, amount:u256) -> u256 {
        self.accessor_s.only_executor(); self.accessor_s.only_authorized_by_user(router);
        return self.router_s.burn_and_send(router,token,amount,self.router_s.core_address.read());
    }
    
    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        RouterEvent: router_component::Event,
        RouterComponentUpdate: RouterComponentUpdate,
        AccessorEvent: accessor_logic_component::Event,   
    }

    #[derive(Drop, starknet::Event)]
    struct RouterComponentUpdate {new_delay:SlowModeDelay, min_amount_to_route:u256, new_punishment_bips:u16}
}