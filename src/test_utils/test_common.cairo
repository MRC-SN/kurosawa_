
    use core::{traits::Into,array::ArrayTrait,option::OptionTrait,traits::TryInto,result::ResultTrait};
    use starknet::{ContractAddress,info::get_block_number,get_caller_address};
    use debug::PrintTrait;
    use snforge_std::{start_cheat_caller_address, stop_cheat_caller_address,declare,ContractClassTrait};
    use core::dict::{Felt252Dict, Felt252DictTrait, SquashedFelt252Dict};
    use kurosawa_akira::utils::erc20::{IERC20DispatcherTrait,IERC20Dispatcher};
    use kurosawa_akira::LayerAkiraCore::{ILayerAkiraCoreDispatcher, ILayerAkiraCoreDispatcherTrait};
    use kurosawa_akira::Order::GasFee;
    use kurosawa_akira::utils::SlowModeLogic::SlowModeDelay;
    use serde::Serde;
    use kurosawa_akira::WithdrawComponent::{SignedWithdraw, Withdraw};
    use snforge_std::signature::KeyPairTrait;
    use snforge_std::signature::stark_curve::{ StarkCurveKeyPairImpl, StarkCurveSignerImpl, StarkCurveVerifierImpl};


    use kurosawa_akira::LayerAkiraExternalGrantor::{IExternalGrantorDispatcher, IExternalGrantorDispatcherTrait};
    use kurosawa_akira::LayerAkiraExecutor::{ILayerAkiraExecutorDispatcher, ILayerAkiraExecutorDispatcherTrait};



    fn get_eth_addr() -> ContractAddress {0x049D36570D4e46f48e99674bd3fcc84644DdD6b96F7C741B1562B82f9e004dC7.try_into().unwrap()}

    // strk
    fn get_usdc_addr() ->ContractAddress {0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d.try_into().unwrap()}
        
    fn tfer_eth_funds_to(receiver: ContractAddress, amount: u256) {
        let caller_who_have_funds: ContractAddress = 0x07BB3440166aa8867c092b7D8726d58F499e10E0112487814DF7a598C35D9301.try_into().unwrap();
        let ETH = IERC20Dispatcher { contract_address: get_eth_addr() };
        start_cheat_caller_address(ETH.contract_address, caller_who_have_funds);
        ETH.transfer(receiver, amount);
        stop_cheat_caller_address(ETH.contract_address);
    }
    fn tfer_usdc_funds_to(receiver: ContractAddress, amount: u256) {
        let caller_who_have_funds: ContractAddress = 0x07BB3440166aa8867c092b7D8726d58F499e10E0112487814DF7a598C35D9301.try_into().unwrap();
        let USDC = IERC20Dispatcher { contract_address: get_usdc_addr() };
        start_cheat_caller_address(USDC.contract_address, caller_who_have_funds);
        USDC.transfer(receiver, amount);
        stop_cheat_caller_address(USDC.contract_address);
    }


    fn get_fee_recipient_exchange()->ContractAddress {0x6fd7354452299b66076d0a7e88a1635cb08506f738434e95ef5cf4ee5af2e0c.try_into().unwrap()}

    fn get_slow_mode()->SlowModeDelay { SlowModeDelay {block:5, ts:5 * 60}}  //5 blocks and 300seconds

    fn get_withdraw_action_cost()->u32 { 100 } 

    fn spawn_exchange() -> ContractAddress {
        let cls = declare("LayerAkira").unwrap();
        let mut constructor: Array::<felt252> = ArrayTrait::new();
        constructor.append(get_eth_addr().into());
        constructor.append(get_fee_recipient_exchange().into());
        
        let mut serialized_slow_mode: Array<felt252> = ArrayTrait::new();
        Serde::serialize(@get_slow_mode(), ref serialized_slow_mode);
        loop {
            match serialized_slow_mode.pop_front() {
                Option::Some(felt) => { constructor.append(felt);},
                Option::None(_) => {break();}
            }
        };
        constructor.append(get_withdraw_action_cost().into());

        constructor.append(get_fee_recipient_exchange().into());

        let min_to_route = 200_000_000_000_000_000;
        constructor.append(min_to_route);
        constructor.append(0);

        constructor.append(get_fee_recipient_exchange().into());
        let (deployed, _) = cls.deploy(@constructor).unwrap();
        return deployed;
    }

    fn spawn_core() -> ContractAddress {
        let cls = declare("LayerAkiraCore").unwrap();
        let mut constructor: Array::<felt252> = ArrayTrait::new();
        constructor.append(get_eth_addr().into());
        constructor.append(get_fee_recipient_exchange().into());
        
        let mut serialized_slow_mode: Array<felt252> = ArrayTrait::new();
        Serde::serialize(@get_slow_mode(), ref serialized_slow_mode);
        loop {
            match serialized_slow_mode.pop_front() {
                Option::Some(felt) => { constructor.append(felt);},
                Option::None(_) => {break();}
            }
        };
        constructor.append(get_withdraw_action_cost().into());
        constructor.append(get_fee_recipient_exchange().into());
        let (deployed, _) = cls.deploy(@constructor).unwrap();
        return deployed;
    }

    fn spawn_external_grantor(core_address:ContractAddress) -> ContractAddress {
        let cls = declare("LayerAkiraExternalGrantor").unwrap();
        let mut constructor: Array::<felt252> = ArrayTrait::new();
        // constructor.append(get_eth_addr().into());
        
        let mut serialized_slow_mode: Array<felt252> = ArrayTrait::new();
        Serde::serialize(@get_slow_mode(), ref serialized_slow_mode);
        loop {
            match serialized_slow_mode.pop_front() {
                Option::Some(felt) => { constructor.append(felt);},
                Option::None(_) => {break();}
            }
        };
        let min_to_route = 200_000_000_000_000_000;
        constructor.append(min_to_route); // min to route
        constructor.append(0);

        constructor.append(get_fee_recipient_exchange().into()); // owner
        constructor.append(core_address.into()); // core address
        
        let (deployed, _) = cls.deploy(@constructor).unwrap();
        return deployed;
    }

    fn spawn_executor(core_address:ContractAddress, router_address:ContractAddress) -> ContractAddress {
        let cls = declare("LayerAkiraExecutor").unwrap();
        let mut constructor: Array::<felt252> = ArrayTrait::new();
        constructor.append(core_address.into());
        constructor.append(router_address.into());
        // constructor.append(get_fee_recipient_exchange().into());
        // constructor.append(get_eth_addr().into());
        // constructor.append(get_fee_recipient_exchange().into());
        let (deployed, _) = cls.deploy(@constructor).unwrap();
        return deployed;
    }
    
    fn spawn_contracts(mut executor:ContractAddress) -> (ContractAddress,ContractAddress,ContractAddress) {
        let core = spawn_core();
        let router = spawn_external_grantor(core);
        let core_contract = ILayerAkiraCoreDispatcher{contract_address:core};
        let executor_contract = spawn_executor(core, router);
        if (executor == 0x0.try_into().unwrap()) { executor = executor_contract}
        start_cheat_caller_address(core, get_fee_recipient_exchange());core_contract.set_executor(executor);stop_cheat_caller_address(core);
        start_cheat_caller_address(core, get_trader_address_1());core_contract.grant_access_to_executor();stop_cheat_caller_address(core);
        start_cheat_caller_address(core, get_trader_address_2());core_contract.grant_access_to_executor();stop_cheat_caller_address(core);

        start_cheat_caller_address(router, get_fee_recipient_exchange());IExternalGrantorDispatcher{contract_address:router}.set_executor(executor);stop_cheat_caller_address(router);
           
        (core, router, executor_contract)
    }

    fn get_trader_address_1()->ContractAddress {
        return 0x01a5f54cC7F0a1106648807f2aE972b05A6921Ba2e8b56bb2AF3b6e371184d68.try_into().unwrap();
    }
    fn get_trader_address_2() -> ContractAddress {
        return 0x07c14752dBC341cAE4c46D3437818dE0660E252a712cA24eE3110eD8D14205A2.try_into().unwrap();
    }

    fn get_trader_signer_and_pk_1()->(felt252,felt252){
        return (0x61c5ec8851e6e8fcdcc065b6724f75bdf4055857dacf3b6be1ac9f1b3dc6fb2,
                                0x0295697db67cfcd0e0a04a26ab2e1333ebc6266d9c5c91be8926922ae0f445c4);
    }

    fn get_trader_signer_and_pk_2()->(felt252, felt252) {
        return (0x40e455f20764012307ca1141ac086ac3b578a33450fd2764a689bf796e8dcf7,
                                0x0461913fd62002100bca4c02e862b2b5160db5c3451d8b9300ff668f91acd27f);
    }

    fn deposit(trader:ContractAddress, amount:u256, token:ContractAddress, akira:ILayerAkiraCoreDispatcher) {
        let erc = IERC20Dispatcher{contract_address: token};
        let (prev_total_supply,prev_user_balance) = (akira.total_supply(token), akira.balanceOf(trader, token));
        start_cheat_caller_address(token, trader);erc.approve(akira.contract_address, amount);stop_cheat_caller_address(token);
        start_cheat_caller_address(akira.contract_address, trader); akira.deposit(trader, token, amount); stop_cheat_caller_address(akira.contract_address);
        assert(akira.total_supply(token) == prev_total_supply + amount,'WRONG_MINT');
        assert(akira.balanceOf(trader, token) == prev_user_balance + amount,'WRONG_MINT'); 
    }

    fn prepare_double_gas_fee_native(akira:ILayerAkiraCoreDispatcher, gas_action:u32)-> GasFee {
        GasFee{ gas_per_action:gas_action, fee_token:get_eth_addr(), 
                max_gas_price: 2 * 1000, conversion_rate: (1,1),
        }
    }

    fn sign(message_hash:felt252,pub_key:felt252,priv:felt252)->(felt252, felt252) {
        let mut signer = KeyPairTrait::<felt252, felt252>::from_secret_key(priv);

        return signer.sign(message_hash).ok().unwrap();
    }


