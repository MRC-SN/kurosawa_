use starknet::ContractAddress;
use serde::Serde;
use kurosawa_akira::utils::SlowModeLogic::SlowModeDelay;

#[starknet::interface]
trait IRouter<TContractState> {
    fn get_base_token(self:@TContractState)-> ContractAddress;
        

    // same semantic as in deposit component
    fn router_deposit(ref self:TContractState, router:ContractAddress, coin:ContractAddress, amount:u256);
    
    //  native token can be withdrawn up to amount specified to be eligible of being router
    //  other tokens can be withdrawn immediately because not influence on trading flow
    fn router_withdraw(ref self: TContractState, coin: ContractAddress, amount: u256, receiver:ContractAddress);
    
    // register router so router can router orders offchain
    // caller can be registered only if he have sufficient amount to route 
    fn register_router(ref self: TContractState);

    // if router wish to bind new signers
    // reverse semantic compared to SignerComponent
    // here router can have multiple signers associated to avoid risks  of exposing his router' private key
    // so when it comes to signing router taker orders router will sign order  by one of his associated signers keys
    fn add_router_binding(ref self: TContractState, signer: ContractAddress);

    // if some signer' key gets compromised router can ASAP remove it
    // TODO would be a minor feature in next release
    // fn remove_router_binding(ref self: TContractState, signer: ContractAddress);
    
    // to not break logic it is applied in 2 txs with delay
    fn request_onchain_deregister(ref self: TContractState);
    
    fn apply_onchain_deregister(ref self: TContractState);

    // validates that message was signed by signer that mapped to router
    fn validate_router(self: @TContractState, message: felt252, signature: (felt252, felt252), signer: ContractAddress, router:ContractAddress) -> bool;

    // in case of failed action due to wrong taker details we punish router and distribute this fine to exchange,
    // because we wasted gas for nothing and to maker because he have lost opportunity
    fn get_punishment_factor_bips(self: @TContractState) -> u16;

    // is router registered as router so he can route router orders to our exchange
    // and we can match them offchain and then apply in router rollup ASAP
    fn is_registered(self: @TContractState, router: ContractAddress) -> bool;

    // does router have sufficient amount of base token to route
    //  route must have some amount so in case of non legit taker we have balance to deduct from for punishment
    fn have_sufficient_amount_to_route(self: @TContractState, router:ContractAddress) -> bool;

    fn balance_of_router(self:@TContractState, router:ContractAddress, coin:ContractAddress)->u256;

    // get router address associated with given signer
    fn get_router(self:@TContractState, signer:ContractAddress) -> ContractAddress;

    // how much one must hold have in balance to be registered as router
    fn get_route_amount(self:@TContractState) -> u256;
}


#[starknet::component]
mod router_component {
    use ecdsa::check_ecdsa_signature;    
    use super::{IRouter, ContractAddress, SlowModeDelay};
    use starknet::{get_caller_address, get_contract_address, get_block_timestamp};
    use starknet::info::get_block_number;
    use kurosawa_akira::utils::erc20::{IERC20DispatcherTrait, IERC20Dispatcher};
    use kurosawa_akira::utils::common::DisplayContractAddress;
    use kurosawa_akira::LayerAkiraCore::{ILayerAkiraCoreDispatcherTrait, ILayerAkiraCoreDispatcher};



    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Deposit:  Deposit,
        Withdraw: Withdraw,
        RouterRegistration: RouterRegistration,
        Binding: Binding,
        RouterMint: RouterMint,
        RouterBurn: RouterBurn
    }

    #[derive(Drop, starknet::Event)]
    struct Deposit {
        #[key]
        router: ContractAddress,
        #[key]
        token: ContractAddress,
        funder: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct Withdraw {
        #[key]
        router:ContractAddress,
        #[key]
        token:ContractAddress,
        amount:u256,
        receiver:ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct RouterRegistration {
        #[key]
        router:ContractAddress,
        status: u8, //0registered, 1scheduled unregister, 2unregsiter
    }
    #[derive(Drop, starknet::Event)]
    struct Binding {
        #[key]
        router:ContractAddress,
        #[key]
        signer:ContractAddress,
        is_added:bool
    }

    #[derive(Drop, starknet::Event)]
    struct RouterMint {
        token:ContractAddress,
        router:ContractAddress,
        amount:u256
    }
    #[derive(Drop, starknet::Event)]
    struct RouterBurn {
        router:ContractAddress,
        token:ContractAddress,
        amount:u256
    }

    #[storage]
    struct Storage {
        pending_unregister:starknet::storage::Map::<felt252, SlowModeDelay>,
        r_delay: SlowModeDelay, // set by exchange, can be updated but no more then original
        min_to_route:u256,
        token_to_user:starknet::storage::Map::<(ContractAddress,ContractAddress),u256>,
        registered:starknet::storage::Map::<ContractAddress,bool>,
        signer_to_router:starknet::storage::Map<ContractAddress,ContractAddress>,
        punishment_bips:u16,
        core_address:ContractAddress
    }

    #[embeddable_as(Routable)]
    impl RoutableImpl<TContractState, +HasComponent<TContractState>> of super::IRouter<ComponentState<TContractState>> {
        fn get_base_token(self:@ComponentState<TContractState>)-> ContractAddress {
            ILayerAkiraCoreDispatcher {contract_address:self.core_address.read() }.get_wrapped_native_token()
        }
        fn get_router(self:@ComponentState<TContractState>, signer:ContractAddress) -> ContractAddress { self.signer_to_router.read(signer)}

        fn get_route_amount(self:@ComponentState<TContractState>) -> u256 { 2 * self.min_to_route.read() }
        
        fn router_deposit(ref self:ComponentState<TContractState>, router:ContractAddress, coin:ContractAddress, amount:u256) {
            let (erc20, contract_addr, caller) = (IERC20Dispatcher{contract_address: coin}, get_contract_address(), get_caller_address());
            
            let pre = erc20.balanceOf(contract_addr);
            erc20.transferFrom(caller, contract_addr, amount);
            let cur = erc20.balanceOf(contract_addr);
            assert!(cur - pre == amount, "WRONG_TFER: failed erc20_balance - prev_balance ({}) == amount({})", cur - pre, amount);
            self.mint(router, coin, amount);
            self.emit(Deposit{router:router, token:coin, funder:caller, amount:amount});
        }

        fn router_withdraw(ref self: ComponentState<TContractState>, coin: ContractAddress, amount: u256, receiver:ContractAddress) {
            let router = get_caller_address();
            let balance:u256 = self.token_to_user.read((coin,router)); 
            assert!(balance >= amount, "FEW_COINS: failed balance ({}) >= amount ({})", balance, amount);
            if self.get_base_token() ==  coin {
                assert!(!self.registered.read(router) || balance - amount >= 2 * self.min_to_route.read(), "FEW_FOR_ROUTE: need to keep at least {} router balance", 2 * self.min_to_route.read());
            }
            self.burn(router, coin, amount);
            
            let erc20 = IERC20Dispatcher{contract_address: coin};
            let balance_before = erc20.balanceOf(get_contract_address());

            erc20.transfer(receiver, amount);

            let transferred = balance_before - erc20.balanceOf(get_contract_address());
            assert!(transferred <= amount, "WRONG_TRANSFER_AMOUNT expected {} actual {}",  amount, transferred);
            self.emit(Withdraw{router:router, token:coin, amount:amount, receiver:receiver});
        }

        fn register_router(ref self: ComponentState<TContractState>) {
            let caller = get_caller_address();
            assert!(!self.registered.read(caller) ,"ALREADY_REGISTERED, router {} already registered", caller);
            let native_balance = self.token_to_user.read( (self.get_base_token(), caller));
            assert!(native_balance >= self.get_route_amount(), "FEW_DEPOSITED: need at least {} base token to register new router", self.get_route_amount());
            self.registered.write(caller, true);
            self.emit(RouterRegistration{router:caller, status:0});
        }

        fn add_router_binding(ref self: ComponentState<TContractState>, signer: ContractAddress){
            let router = get_caller_address();
            assert!(self.registered.read(router) ,"NOT_REGISTERED: router {} not registered", router);
            let cur_router = self.signer_to_router.read(signer);
            assert!(!self.registered.read(cur_router), "ALREADY_USED: given signer {} already used", signer);
            self.signer_to_router.write(signer,router);
            self.emit(Binding{router,signer,is_added:true});
        }

        // TODO: LATER MAKE IT WITH DELAY TO AVOID ON_PURPOSE_REMOVAL aka MALICOUS ACTIVITIES BY ROUTERS
        // fn remove_router_binding(ref self: ComponentState<TContractState>, signer: ContractAddress){
        //     let router = get_caller_address();
        //     assert(self.registered.read(router) ,'NOT_REGISTERED');
        //     let cur_router = self.signer_to_router.read(signer);
        //     assert(cur_router == router, 'WRONG_BINDING');
        //     self.signer_to_router.write(signer, 0.try_into().unwrap());
        //     self.emit(Binding{router,signer,is_added:false});
        // }

        fn request_onchain_deregister(ref self: ComponentState<TContractState>) {
            let router = get_caller_address();
            assert!(self.registered.read(router), "NOT_REGISTERED: not registered router {}", router);
            let ongoing:SlowModeDelay = self.pending_unregister.read(router.into());
            assert!(ongoing.block == 0, "DEREGISTER_ALREADY_REQUESTED: router {} already requested deregistration", router);
            self.pending_unregister.write(router.into(), SlowModeDelay{block:get_block_number(), ts:get_block_timestamp()});
            self.emit(RouterRegistration{router:router,status:1});
        }
         
        fn apply_onchain_deregister(ref self: ComponentState<TContractState>) {
            let router = get_caller_address();
            assert!(self.registered.read(router), "NOT_REGISTERED: not registered router {}", router);
            let ongoing:SlowModeDelay = self.pending_unregister.read(router.into());
            assert!(ongoing.block != 0, "NOT_REQUESTED: router {} has not requested deregistration", router);
            let delay:SlowModeDelay = self.r_delay.read();
            let (block_delta, ts_delta) = (get_block_number() - ongoing.block, get_block_timestamp() - ongoing.ts);
            assert!(block_delta >= delay.block && ts_delta >= delay.ts, "FEW_TIME_PASSED: wait at least {} block and {} ts (for now its {} and {})", delay.block, delay.ts, block_delta, ts_delta);
            
            self.registered.write(router, false);
            self.pending_unregister.write(router.into(), SlowModeDelay{block:0,ts:0});
            self.emit(RouterRegistration{router:router,status:2});
        }

        fn validate_router(self: @ComponentState<TContractState>, message: felt252, signature: (felt252, felt252), signer: ContractAddress, router:ContractAddress) -> bool {
            // message should be correctly signed by signer and 
            // signer should be associated with expected router
            // and this router should actually be registered as router  
            let actual_router = self.signer_to_router.read(signer);
            if actual_router != router {return false;}
            assert!(self.registered.read(router), "NOT_REGISTERED: not registered router {}", router); // this one should be controlled by exchange, if fails, exchage screwed
            let (sig_r, sig_s) = signature;
            return check_ecdsa_signature(message, signer.into(), sig_r, sig_s);
        }

        fn get_punishment_factor_bips(self: @ComponentState<TContractState>) -> u16 { return self.punishment_bips.read();}
        
        fn is_registered(self: @ComponentState<TContractState>, router: ContractAddress) -> bool { return self.registered.read(router);}

        fn have_sufficient_amount_to_route(self: @ComponentState<TContractState>, router:ContractAddress) -> bool {
            return self.token_to_user.read((self.get_base_token(), router)) >= self.min_to_route.read();
        }

        fn balance_of_router(self:@ComponentState<TContractState>, router:ContractAddress, coin:ContractAddress)-> u256 {
            return self.token_to_user.read((coin, router));
        }
    }

    #[generate_trait]
    impl InternalRoutableImpl<TContractState, +HasComponent<TContractState>> of InternalRoutable<TContractState> {
        fn initializer(ref self: ComponentState<TContractState>, delay:SlowModeDelay, core_address:ContractAddress, min_to_route:u256, punishment_bips:u16 ) {
            self.min_to_route.write(min_to_route); 
            self.punishment_bips.write(punishment_bips);
            self.r_delay.write(delay);            
            self.core_address.write(core_address);
        }
        // burn mint only by executor, alsways stake a tad amount
        fn mint(ref self: ComponentState<TContractState>,router:ContractAddress,token:ContractAddress, amount:u256) {
            // mint on router deposit and when we give reward to router after trade
            let new_balance = self.token_to_user.read((token, router)) + amount;
            self.token_to_user.write((token, router), new_balance);
            self.emit(RouterMint{router, token, amount});
        }

        fn burn(ref self: ComponentState<TContractState>,router:ContractAddress,token:ContractAddress, amount:u256) {
            // burn on router withdrawal and when we punish router on trade failed because of bad taker
            let balance:u256 = self.token_to_user.read((token, router)); 
            assert!(balance >= amount, "FEW_TO_BURN_ROUTER: failed balance ({}) >= amount ({})", balance, amount);
            self.token_to_user.write((token, router), balance - amount);
            self.emit(RouterBurn{router, token, amount});
        }
        fn burn_and_send(ref self: ComponentState<TContractState>,router:ContractAddress,token:ContractAddress, amount:u256,  
                            to:ContractAddress) -> u256 {
            self.burn(router, token, amount);
            let erc20 = IERC20Dispatcher{contract_address: token};
            let balance_before = erc20.balanceOf(get_contract_address());
            erc20.transfer(to, amount);
            let transferred = balance_before - erc20.balanceOf(get_contract_address());
            assert!(transferred <= amount, "WRONG_TRANSFER_AMOUNT expected {} actual {}",  amount, transferred);
            return transferred;
        }
    }

}
