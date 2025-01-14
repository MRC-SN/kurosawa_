
#[cfg(test)]
mod tests_deposit_and_withdrawal_and_nonce {
    use kurosawa_akira::test_utils::test_common::{deposit,get_eth_addr,tfer_eth_funds_to,get_fee_recipient_exchange,get_slow_mode,get_trader_address_1,
    get_withdraw_action_cost,spawn_exchange,prepare_double_gas_fee_native,get_trader_signer_and_pk_1,sign, spawn_contracts};
    use core::{traits::Into,array::ArrayTrait,option::OptionTrait,traits::TryInto,result::ResultTrait};
    use starknet::{ContractAddress,info::get_block_number,get_caller_address};
    use snforge_std::{start_cheat_caller_address,stop_cheat_caller_address, start_cheat_block_timestamp,stop_cheat_block_timestamp, declare,ContractClassTrait, start_cheat_block_number, stop_cheat_block_number};
    use kurosawa_akira::utils::erc20::{IERC20DispatcherTrait,IERC20Dispatcher};
    use kurosawa_akira::Order::GasFee;
    use kurosawa_akira::utils::SlowModeLogic::SlowModeDelay;
    use serde::Serde;
    use kurosawa_akira::WithdrawComponent::{SignedWithdraw, Withdraw};
    use kurosawa_akira::FundsTraits::check_sign;
    use kurosawa_akira::NonceComponent::{IncreaseNonce,SignedIncreaseNonce};
    use core::string::StringLiteral;
    use kurosawa_akira::signature::V0OffchainMessage::{OffchainMessageHashImpl};
    use kurosawa_akira::signature::AkiraV0OffchainMessage::{OrderHashImpl,SNIP12MetadataImpl,IncreaseNonceHashImpl,WithdrawHashImpl};


    use kurosawa_akira::LayerAkiraCore::{ILayerAkiraCoreDispatcher, ILayerAkiraCoreDispatcherTrait};
    
    
    #[test]
    #[fork("block_based")]
    fn test_eth_deposit() {
        let(core, _, __) = spawn_contracts(get_fee_recipient_exchange());
        let core_contract = ILayerAkiraCoreDispatcher{contract_address:core};
        let (trader,eth_addr,amount_deposit) = (get_trader_address_1(), get_eth_addr(),1_000_000);
        tfer_eth_funds_to(trader, 2 * amount_deposit);
        deposit(trader, amount_deposit, eth_addr, core_contract); 
        deposit(trader, amount_deposit, eth_addr, core_contract); 
    }

    fn get_withdraw(trader:ContractAddress, amount:u256, token:ContractAddress, akira:ILayerAkiraCoreDispatcher, 
                salt:felt252, sign_scheme:felt252)-> Withdraw {
        let gas_fee = prepare_double_gas_fee_native(akira, 100);
        let amount = if token == akira.get_wrapped_native_token() {amount} else {amount};
        return Withdraw {maker:trader, token, amount, salt, gas_fee, receiver:trader, sign_scheme};
        
    }

    fn request_onchain_withdraw(trader:ContractAddress, amount:u256, token:ContractAddress, akira:ILayerAkiraCoreDispatcher, salt:felt252)-> (Withdraw,SlowModeDelay) {
        let withdraw = get_withdraw(trader, amount, token, akira, salt, '');
        start_cheat_caller_address(akira.contract_address, trader); akira.request_onchain_withdraw(withdraw); stop_cheat_caller_address(akira.contract_address);
        let (request_time, w) = akira.get_pending_withdraw(trader, token);
        assert(withdraw == w, 'WRONG_WTIHDRAW_RETURNED');
        return (withdraw, request_time);
    }

    fn withdraw_direct(trader:ContractAddress,token:ContractAddress, akira:ILayerAkiraCoreDispatcher, use_delay:bool) {
        let delay = get_slow_mode();
        let(req_time, w) = akira.get_pending_withdraw(trader,token);
        let erc = IERC20Dispatcher{contract_address:token};
        let balance_trader = erc.balanceOf(trader);
        let (akira_total, akira_user) = (akira.total_supply(token), akira.balanceOf(trader,token));

        if use_delay{
            start_cheat_block_number(akira.contract_address, delay.block + req_time.block); 
            start_cheat_block_timestamp(akira.contract_address, req_time.ts + delay.ts);
        }
        start_cheat_caller_address(akira.contract_address, trader); akira.apply_onchain_withdraw(token, akira.get_withdraw_hash(w)); stop_cheat_caller_address(akira.contract_address);
        if use_delay {
             stop_cheat_block_number(akira.contract_address);
             stop_cheat_block_timestamp(akira.contract_address);
        }

        assert(erc.balanceOf(trader) - balance_trader == w.amount, 'WRONG_AMOUNT_RECEIVED');
        assert(akira_total - akira.total_supply(token) == w.amount, 'WRONG_BURN_TOTAL');
        assert(akira_user - akira.balanceOf(trader, token) == w.amount, 'WRONG_BURN_TOKEN');
    }

    #[test]
    #[fork("block_based")]
    #[should_panic(expected: ("FEW_TIME_PASSED: wait at least 67186 block and 1716027804 ts (for now its 0 and 0)",))]
    fn test_withdraw_eth_direct_immediate() {
        let(core, _, __) = spawn_contracts(get_fee_recipient_exchange());
        let akira = ILayerAkiraCoreDispatcher{contract_address:core};
        
        let (trader,eth_addr,amount_deposit) = (get_trader_address_1(), get_eth_addr(),1_000_000);
        tfer_eth_funds_to(trader, amount_deposit);
        deposit(trader, amount_deposit, eth_addr, akira); 
        request_onchain_withdraw(trader, amount_deposit, eth_addr, akira, 0);
        withdraw_direct(trader,eth_addr,akira,false);
    }

    // Failure data:
    // Incorrect panic data
    // Actual:     (, , FEW_TIME_PASSED: wait at least , 67186 block and 1716027804 ts (, for now its 0 and 0), )
    // Expected:  [1997209042069643135709344952807065910992472029923670688473712229447419591075, 2, 124157870587116589809572849905489050861556589536883664145575828278905893920, 77963588382890035563278993479845890735047611822669186366049693698084598899, 788485465482797490682227907733662976304670684936652468265, 24] (, , FEW_TIME_PASSED: wait at least , , 67186 block and 1716027804 ts,  (, for now its 0 and 0), )

    #[test]
    #[fork("block_based")]
    fn test_withdraw_eth_direct_delayed() {
        let(core, _, __) = spawn_contracts(get_fee_recipient_exchange());
        let akira = ILayerAkiraCoreDispatcher{contract_address:core};
        
        let (trader,eth_addr,amount_deposit) = (get_trader_address_1(), get_eth_addr(),1_000_000);
        tfer_eth_funds_to(trader, amount_deposit);
        deposit(trader, amount_deposit, eth_addr, akira); 
        request_onchain_withdraw(trader, amount_deposit, eth_addr, akira, 0);
        withdraw_direct(trader, eth_addr, akira, true);     
    }

    #[test]
    #[fork("block_based")]
    #[should_panic(expected: ("ALREADY_COMPLETED: withdraw has been completed already",))]
    fn test_withdraw_eth_direct_delayed_cant_apply_twice() {
        let(core, _, __) = spawn_contracts(get_fee_recipient_exchange());
        let akira = ILayerAkiraCoreDispatcher{contract_address:core};
        
        let (trader,eth_addr,amount_deposit) = (get_trader_address_1(), get_eth_addr(),1_000_000);
        tfer_eth_funds_to(trader, amount_deposit);
        deposit(trader, amount_deposit, eth_addr, akira); 
        request_onchain_withdraw(trader, amount_deposit, eth_addr, akira, 0);
        withdraw_direct(trader, eth_addr, akira, true);     
        withdraw_direct(trader, eth_addr, akira, true);     
    }

    #[test]
    #[fork("block_based")]
    fn test_withdraw_eth_direct_no_delayed_by_exchange() {
        let(core, _, __) = spawn_contracts(get_fee_recipient_exchange());
        let akira = ILayerAkiraCoreDispatcher{contract_address:core};
        
        let (trader, eth_addr, amount_deposit) = (get_trader_address_1(), get_eth_addr(),1_000_000);
        tfer_eth_funds_to(trader, amount_deposit); deposit(trader, amount_deposit, eth_addr, akira); 
        let(withdraw, _) = request_onchain_withdraw(trader, amount_deposit, eth_addr, akira, 0);

        let erc = IERC20Dispatcher{contract_address: eth_addr};
        let b = erc.balanceOf(trader);

        start_cheat_caller_address(akira.contract_address, get_fee_recipient_exchange());
        akira.apply_withdraw(SignedWithdraw{withdraw, sign:array![0, 0].span()}, 100, withdraw.gas_fee.gas_per_action);
        stop_cheat_caller_address(akira.contract_address);
        assert(amount_deposit - withdraw.gas_fee.gas_per_action.into() * 100 == erc.balanceOf(trader) - b ,'WRONG_SEND');
        assert(akira.balanceOf(trader, eth_addr) == 0,'WRONG_BURN');
    }

    #[test]
    #[fork("block_based")]
    fn test_withdraw_eth_indirect() {
        let(core, _, __) = spawn_contracts(get_fee_recipient_exchange());
        let akira = ILayerAkiraCoreDispatcher{contract_address:core};
        
        let (trader, eth_addr, amount_deposit) = (get_trader_address_1(), get_eth_addr(),1_000_000);
        let (pub_addr,priv) = get_trader_signer_and_pk_1();
        
        tfer_eth_funds_to(trader, amount_deposit); deposit(trader, amount_deposit, eth_addr, akira); 
        
        let w = get_withdraw(trader, amount_deposit, eth_addr, akira, 0, 'ecdsa curve');

        start_cheat_caller_address(akira.contract_address, trader); akira.bind_to_signer(pub_addr.try_into().unwrap()); stop_cheat_caller_address(akira.contract_address);
       
        start_cheat_caller_address(akira.contract_address, get_fee_recipient_exchange());
        let (r,s) = sign(akira.get_withdraw_hash(w), pub_addr, priv);
        akira.apply_withdraw(SignedWithdraw{withdraw:w, sign: array![r,s].span()}, 100,w.gas_fee.gas_per_action);
        stop_cheat_caller_address(akira.contract_address);
    }    

    #[test]
    #[fork("block_based")]
    #[should_panic(expected: ("ALREADY_COMPLETED: withdraw (hash = 957201278841670640498632393349450727444268037161897304282096904719289985567)",))]
    fn test_withdraw_eth_indirect_twice() {
        let(core, _, __) = spawn_contracts(get_fee_recipient_exchange());
        let akira = ILayerAkiraCoreDispatcher{contract_address:core};
        
        let (trader, eth_addr, amount_deposit) = (get_trader_address_1(), get_eth_addr(),1_000_000);
        let (pub_addr,priv) = get_trader_signer_and_pk_1();
        
        tfer_eth_funds_to(trader, amount_deposit); deposit(trader, amount_deposit, eth_addr, akira); 
        
        let w = get_withdraw(trader, amount_deposit, eth_addr, akira, 0,'ecdsa curve');
        
        start_cheat_caller_address(akira.contract_address, trader); akira.bind_to_signer(pub_addr.try_into().unwrap()); stop_cheat_caller_address(akira.contract_address);
        start_cheat_caller_address(akira.contract_address, get_fee_recipient_exchange());
        
        let (r,s) = sign(akira.get_withdraw_hash(w), pub_addr, priv);
        akira.apply_withdraw(SignedWithdraw{withdraw:w, sign:array![r,s].span()}, 100, w.gas_fee.gas_per_action);
        akira.apply_withdraw(SignedWithdraw{withdraw:w, sign:array![r,s].span()}, 100, w.gas_fee.gas_per_action);
        
        stop_cheat_caller_address(akira.contract_address);
    } 
    #[test]
    #[fork("block_based")]
    fn test_increase_nonce() {
        let(core, _, __) = spawn_contracts(get_fee_recipient_exchange());
        let akira = ILayerAkiraCoreDispatcher{contract_address:core};
        
        let (trader, eth_addr, amount_deposit) = (get_trader_address_1(), get_eth_addr(),1_000_000);
        let (pub_addr, priv) = get_trader_signer_and_pk_1();
        tfer_eth_funds_to(trader, amount_deposit); deposit(trader, amount_deposit, eth_addr, akira); 
        let nonce = IncreaseNonce{maker:trader ,new_nonce:1, gas_fee:prepare_double_gas_fee_native(akira,100), salt:0,
                    sign_scheme: 'ecdsa curve'};

        start_cheat_caller_address(akira.contract_address, trader); akira.bind_to_signer(pub_addr.try_into().unwrap()); stop_cheat_caller_address(akira.contract_address);

        start_cheat_caller_address(akira.contract_address, get_fee_recipient_exchange());
        let (r,s) = sign(akira.get_increase_nonce_hash(nonce), pub_addr, priv);
        akira.apply_increase_nonce(SignedIncreaseNonce{increase_nonce:nonce, sign:array![r,s].span()}, 100, nonce.gas_fee.gas_per_action);        
        stop_cheat_caller_address(akira.contract_address);
    } 

}

mod test_common_trade {

    use core::clone::Clone;
    use kurosawa_akira::test_utils::test_common::{deposit,spawn_contracts,get_eth_addr,tfer_eth_funds_to,get_fee_recipient_exchange,get_slow_mode, 
    get_trader_address_1,get_trader_address_2,get_trader_signer_and_pk_1,get_usdc_addr,tfer_usdc_funds_to,
    get_withdraw_action_cost,spawn_exchange,prepare_double_gas_fee_native,sign,get_trader_signer_and_pk_2};
    use core::{traits::Into,array::ArrayTrait,option::OptionTrait,traits::TryInto,result::ResultTrait};
    use starknet::{ContractAddress,info::get_block_number,get_caller_address};
    use debug::PrintTrait;
    use snforge_std::{start_cheat_caller_address,start_cheat_block_timestamp,stop_cheat_block_timestamp,stop_cheat_caller_address,declare,ContractClassTrait, start_cheat_block_number, stop_cheat_block_number};
    use core::dict::{Felt252Dict, Felt252DictTrait, SquashedFelt252Dict};
    use kurosawa_akira::utils::erc20::{IERC20DispatcherTrait,IERC20Dispatcher};
    use kurosawa_akira::Order::GasFee;
    use kurosawa_akira::utils::SlowModeLogic::SlowModeDelay;
    use serde::Serde;
    use kurosawa_akira::WithdrawComponent::{SignedWithdraw, Withdraw};
    use kurosawa_akira::FundsTraits::check_sign;
    use kurosawa_akira::Order::{SignedOrder, Order,Constraints,Quantity,TakerSelfTradePreventionMode, FixedFee,OrderFee,OrderFlags, get_feeable_qty};
    use kurosawa_akira::signature::V0OffchainMessage::{OffchainMessageHashImpl};
    use kurosawa_akira::signature::AkiraV0OffchainMessage::{OrderHashImpl,SNIP12MetadataImpl,IncreaseNonceHashImpl,WithdrawHashImpl};
    
    use kurosawa_akira::LayerAkiraCore::{ILayerAkiraCoreDispatcher, ILayerAkiraCoreDispatcherTrait};
    use kurosawa_akira::LayerAkiraExternalGrantor::{IExternalGrantorDispatcher, IExternalGrantorDispatcherTrait};
    use kurosawa_akira::LayerAkiraExecutor::{ILayerAkiraExecutorDispatcher, ILayerAkiraExecutorDispatcherTrait};


    fn prepare() ->((ILayerAkiraCoreDispatcher,IExternalGrantorDispatcher,ILayerAkiraExecutorDispatcher), ContractAddress, ContractAddress, ContractAddress, ContractAddress, u256, u256) {
        let(core, router, executor) = spawn_contracts(0x0.try_into().unwrap());
        let core_contract = ILayerAkiraCoreDispatcher{contract_address:core};
        let (tr1,tr2, (pub_addr1, _), (pub_addr2, _)) = (get_trader_address_1(), get_trader_address_2(), get_trader_signer_and_pk_1(), get_trader_signer_and_pk_2());
        let (eth, usdc) = (get_eth_addr(), get_usdc_addr());
        let (eth_amount, usdc_amount) = (1_000_000_000_000_000_000, 2000_000_000); //1eth and 2k usdc 
        tfer_eth_funds_to(tr1, 2 * eth_amount); tfer_eth_funds_to(tr2, 2 * eth_amount);
        tfer_usdc_funds_to(tr1, 2 *  usdc_amount); tfer_usdc_funds_to(tr2, 2 * usdc_amount);

        start_cheat_caller_address(core_contract.contract_address, tr1); core_contract.bind_to_signer(pub_addr1.try_into().unwrap()); stop_cheat_caller_address(core_contract.contract_address);
        start_cheat_caller_address(core_contract.contract_address, tr2); core_contract.bind_to_signer(pub_addr2.try_into().unwrap()); stop_cheat_caller_address(core_contract.contract_address);
        
        return ((core_contract,IExternalGrantorDispatcher{contract_address:router},ILayerAkiraExecutorDispatcher{contract_address:executor}), tr1, tr2, eth, usdc, eth_amount, usdc_amount);
    }

    fn get_maker_taker_fees()->(u32, u32)  {  (100, 200)} //1 and 2 bips

    fn get_swap_gas_cost()->u32 {100}

    fn get_zero_router_fee() -> FixedFee {
        FixedFee{recipient:0.try_into().unwrap(), maker_pbips:0, taker_pbips: 0,apply_to_receipt_amount:true}
    }

    fn zero_router() -> ContractAddress { 0.try_into().unwrap()}


    fn spawn_order(contracts:(ILayerAkiraCoreDispatcher,IExternalGrantorDispatcher,ILayerAkiraExecutorDispatcher), maker:ContractAddress, price:u256, base_qty:u256,
            flags:OrderFlags,
            num_swaps_allowed:u16, router_signer:ContractAddress) ->SignedOrder {
        spawn_double_qty_order(contracts, maker, price, base_qty, 0, flags, num_swaps_allowed, router_signer, true)
    }

    fn spawn_double_qty_order(contracts:(ILayerAkiraCoreDispatcher,IExternalGrantorDispatcher,ILayerAkiraExecutorDispatcher),
            maker:ContractAddress, price:u256, base_qty:u256, quote_qty:u256,
            flags:OrderFlags,
            num_swaps_allowed:u16, router_signer:ContractAddress, apply_to_receipt_amount:bool,
            
            ) ->SignedOrder {
        let (core,router,executor) = contracts;
        let zero_addr:ContractAddress = 0.try_into().unwrap();
        let ticker =(get_eth_addr(), get_usdc_addr()); 
        let salt = num_swaps_allowed.into();
        let (maker_pbips,taker_pbips) = get_maker_taker_fees();
        let fee_recipient = core.get_fee_recipient();
        let router_fee =  if router_signer != zero_addr { 
            FixedFee{recipient:router.get_router(router_signer), maker_pbips, taker_pbips,apply_to_receipt_amount}
        } else { FixedFee{recipient: zero_addr, maker_pbips:0, taker_pbips:0,apply_to_receipt_amount}
        };
        let mut order = Order {
            qty:Quantity{base_qty, quote_qty, base_asset: 1_000_000_000_000_000_000},
            constraints:Constraints {
                number_of_swaps_allowed: num_swaps_allowed,
                nonce:core.get_nonce(maker),
                router_signer,
                created_at: 0,
                duration_valid:3_294_967_295,
                stp:TakerSelfTradePreventionMode::NONE,
                min_receive_amount:0,
            },
            maker, price, ticker,  salt,
            fee: OrderFee {
                trade_fee:  FixedFee{recipient:fee_recipient, maker_pbips, taker_pbips, apply_to_receipt_amount},
                router_fee: router_fee,
                gas_fee: prepare_double_gas_fee_native(core, get_swap_gas_cost())
            },
            flags,
            source: 'layerakira',
            sign_scheme: 'ecdsa curve'
        };

        let hash = executor.get_order_hash(order);
        let (pub_addr, pk) = if maker == get_trader_address_1() {
            get_trader_signer_and_pk_1()
        } else  { get_trader_signer_and_pk_2()};
    
        let (r,s) = sign(hash, pub_addr, pk);
        return SignedOrder{order, sign: array![r,s].span(), router_sign:(0,0)};
    }

    fn register_router(akira:(ILayerAkiraCoreDispatcher,IExternalGrantorDispatcher,ILayerAkiraExecutorDispatcher), funds_account:ContractAddress, signer:ContractAddress, router_address:ContractAddress) {
        let (_,router,__) = akira;
        let (route_amount, base) = (router.get_route_amount(), router.get_base_token());

        
        
        start_cheat_caller_address(base, funds_account);
        IERC20Dispatcher{contract_address:base}.increaseAllowance(router.contract_address,  route_amount);
        stop_cheat_caller_address(base);
        
        start_cheat_caller_address(router.contract_address, funds_account);
        router.router_deposit(router_address, base, route_amount);
        stop_cheat_caller_address(router.contract_address);
        
        
        start_cheat_caller_address(router.contract_address, router_address);
        router.register_router();
        router.grant_access_to_executor();
        router.add_router_binding(signer);

        stop_cheat_caller_address(router.contract_address);
        
    }

}

#[cfg(test)]
mod tests_ecosystem_trade {
    use core::clone::Clone;
    use kurosawa_akira::test_utils::test_common::{deposit,get_eth_addr,tfer_eth_funds_to,get_fee_recipient_exchange,get_slow_mode, 
    get_trader_address_1,get_trader_address_2,get_trader_signer_and_pk_1,get_usdc_addr,tfer_usdc_funds_to,
    get_withdraw_action_cost,spawn_exchange, prepare_double_gas_fee_native, sign, get_trader_signer_and_pk_2};
    use core::{traits::Into,array::ArrayTrait,option::OptionTrait,traits::TryInto,result::ResultTrait};
    use starknet::{ContractAddress,info::get_block_number,get_caller_address};
    use debug::PrintTrait;
    use snforge_std::{start_cheat_caller_address,start_cheat_block_timestamp,stop_cheat_block_timestamp,stop_cheat_caller_address,declare,ContractClassTrait, start_cheat_block_number, stop_cheat_block_number};
    use core::dict::{Felt252Dict, Felt252DictTrait, SquashedFelt252Dict};
    use kurosawa_akira::utils::erc20::{IERC20DispatcherTrait,IERC20Dispatcher};
    use kurosawa_akira::Order::GasFee;
    use kurosawa_akira::utils::SlowModeLogic::SlowModeDelay;
    use serde::Serde;
    use kurosawa_akira::WithdrawComponent::{SignedWithdraw, Withdraw};
    use kurosawa_akira::FundsTraits::check_sign;
    use kurosawa_akira::Order::{SignedOrder, Order, FixedFee,OrderFee,OrderFlags, get_feeable_qty};
    use kurosawa_akira::signature::AkiraV0OffchainMessage::{OrderHashImpl,SNIP12MetadataImpl,IncreaseNonceHashImpl,WithdrawHashImpl};

    use kurosawa_akira::signature::V0OffchainMessage::{OffchainMessageHashImpl};

    use super::test_common_trade:: {prepare,get_maker_taker_fees,get_swap_gas_cost, spawn_order, spawn_double_qty_order, get_zero_router_fee,zero_router};
    use kurosawa_akira::LayerAkiraCore::{ILayerAkiraCoreDispatcher, ILayerAkiraCoreDispatcherTrait};
    use kurosawa_akira::LayerAkiraExternalGrantor::{IExternalGrantorDispatcher, IExternalGrantorDispatcherTrait};
    use kurosawa_akira::LayerAkiraExecutor::{ILayerAkiraExecutorDispatcher, ILayerAkiraExecutorDispatcherTrait};



    fn get_order_flags(full_fill_only:bool,best_level_only:bool,post_only:bool,is_sell_side:bool,is_market_order:bool,) -> OrderFlags{
        return OrderFlags{full_fill_only, best_level_only, post_only, is_sell_side, is_market_order, to_ecosystem_book: true, external_funds:false};
    }

    #[test]
    #[fork("block_based")]
    fn test_succ_match_single_buy_taker_trade_full() {
        // Taker buy, full match happens with maker of same px
        let (akira, tr1, tr2, eth, usdc, eth_amount, usdc_amount) = prepare();
        let(core, _, executor) = akira;
        
        deposit(tr1, eth_amount, eth, core); deposit(tr2, usdc_amount, usdc, core);


        let sell_limit_flags = get_order_flags(false,false,true,true,false);
        let sell_order = spawn_order(akira, tr1, usdc_amount, eth_amount, sell_limit_flags, 0, zero_router());
        let buy_limit_flags = get_order_flags(false, false, false, false, true);
        let buy_order = spawn_order(akira, tr2, usdc_amount, eth_amount, buy_limit_flags, 2, zero_router());

        start_cheat_caller_address(executor.contract_address, get_fee_recipient_exchange());
        executor.apply_ecosystem_trades(array![(buy_order,false)], array![sell_order], array![(1,false)], array![0], 100, get_swap_gas_cost());
        let maker_fee = get_feeable_qty(sell_order.order.fee.trade_fee, usdc_amount, true);
        assert(core.balanceOf(sell_order.order.maker, usdc) == usdc_amount - maker_fee,'WRONG_MATCH_RECIEVE_USDC');
        assert(core.balanceOf(buy_order.order.maker, usdc) == 0,'WRONG_MATCH_SEND_USDC');
                
        let taker_fee = get_feeable_qty(buy_order.order.fee.trade_fee, eth_amount, false);
        let gas_fee = 100 * get_swap_gas_cost().into();
        assert(core.balanceOf(buy_order.order.maker, eth) == eth_amount - gas_fee - taker_fee, 'WRONG_MATCH_RECIEVE_ETH');
        assert(core.balanceOf(sell_order.order.maker, eth) == 0, 'WRONG_MATCH_SEND_ETH');
       
        
        stop_cheat_caller_address(executor.contract_address);
    }  



    #[test]
    #[fork("block_based")]
    fn test_succ_match_single_sell_taker_trade_full() {
        // Taker buy, full match happens with maker of same px
        let (akira, tr1, tr2, eth, usdc, eth_amount, usdc_amount) = prepare();
        let(core, _, executor) = akira;
        
        let gas_required:u256 = 100 * get_swap_gas_cost().into(); 
        deposit(tr1, eth_amount, eth, core); deposit(tr2, usdc_amount, usdc, core);


        let sell_market_flags = get_order_flags(false, false, false, true, true);
        let sell_order = spawn_order(akira, tr1, usdc_amount, eth_amount - gas_required, sell_market_flags, 2, zero_router());

        let buy_limit_flags = get_order_flags(false, false, true, false, false);

        let buy_order = spawn_order(akira, tr2, usdc_amount, eth_amount, buy_limit_flags, 0,  zero_router());
        start_cheat_caller_address(executor.contract_address, get_fee_recipient_exchange());

        executor.apply_ecosystem_trades(array![(sell_order, false)], array![buy_order], array![(1,false)], array![0], 100, get_swap_gas_cost());

        //0 cause remaining eth was spent on gas
        assert!(core.balanceOf(sell_order.order.maker, eth) == 0, "WRONG_MATCH_ETH_SELL");
        stop_cheat_caller_address(executor.contract_address);
    }  


    #[test]
    #[fork("block_based")]
    fn test_succ_match_single_buy_taker_trade_full_router() {
        // Taker buy, full match happens with maker of same px
        let (akira, tr1, tr2, eth, usdc, eth_amount, usdc_amount) = prepare();
        let(core, _, executor) = akira;
        
        deposit(tr1, eth_amount, eth, core); deposit(tr2, usdc_amount, usdc, core);

        let sell_limit_flags = get_order_flags(false,false,true,true, false);
        let sell_order = spawn_order(akira, tr1, usdc_amount, eth_amount, sell_limit_flags, 0, zero_router());
        let buy_limit_flags = get_order_flags(false, false, false, false, true);
        let buy_order = spawn_order(akira, tr2, usdc_amount, eth_amount, buy_limit_flags, 2, zero_router());

        start_cheat_caller_address(executor.contract_address, get_fee_recipient_exchange());
        executor.apply_single_execution_step(buy_order, array![(sell_order, 0)], 0, 100, get_swap_gas_cost(), true);
        let maker_fee = get_feeable_qty(sell_order.order.fee.trade_fee, usdc_amount, true);
        assert(core.balanceOf(sell_order.order.maker, usdc) == usdc_amount - maker_fee,'WRONG_MATCH_RECIEVE_USDC');
        assert(core.balanceOf(buy_order.order.maker, usdc) == 0,'WRONG_MATCH_SEND_USDC');
                
        let taker_fee = get_feeable_qty(buy_order.order.fee.trade_fee, eth_amount, false);
        let gas_fee = 100 * get_swap_gas_cost().into();
        assert(core.balanceOf(buy_order.order.maker, eth) == eth_amount - gas_fee - taker_fee, 'WRONG_MATCH_RECIEVE_ETH');
        assert(core.balanceOf(sell_order.order.maker, eth) == 0, 'WRONG_MATCH_SEND_ETH');
       
        stop_cheat_caller_address(executor.contract_address);
    }  

    #[test]
    #[fork("block_based")]
    fn test_succ_match_single_sell_taker_trade_full_router() {
        // Taker buy, full match happens with maker of same px
        let (akira, tr1, tr2, eth, usdc, eth_amount, usdc_amount) = prepare();
        let(core, _, executor) = akira;
        
        let gas_required:u256 = 100 * get_swap_gas_cost().into(); 
        deposit(tr1, eth_amount, eth, core); deposit(tr2, usdc_amount, usdc, core);


        let sell_market_flags = get_order_flags(false, false, false, true, true);
        let sell_order = spawn_order(akira, tr1, usdc_amount, eth_amount - gas_required, sell_market_flags, 2, zero_router());

        let buy_limit_flags = get_order_flags(false, false, true, false, false);

        let buy_order = spawn_order(akira, tr2, usdc_amount, eth_amount, buy_limit_flags, 0,  zero_router());
        start_cheat_caller_address(executor.contract_address, get_fee_recipient_exchange());

        executor.apply_single_execution_step(sell_order, array![(buy_order,0)], 0, 100, get_swap_gas_cost(), false);

        //0 cause remaining eth was spent on gas
        assert!(core.balanceOf(sell_order.order.maker, eth) == 0, "WRONG_MATCH_ETH_SELL");
        stop_cheat_caller_address(executor.contract_address);
    }  


    #[test]
    #[fork("block_based")]
    fn test_double_qty_SELL_maker_01_oracle_qty() {
        // Taker buy, full match happens with maker of same px
        let (akira, tr1, tr2, eth, usdc, eth_amount, usdc_amount) = prepare();
        let(core, _, executor) = akira;
        
        let gas_required:u256 = 100 * get_swap_gas_cost().into(); 
        deposit(tr1, eth_amount, eth, core); deposit(tr2, usdc_amount, usdc, core);


        let sell_market_flags = get_order_flags(false, false, false, true, true);
        let sell_order = spawn_double_qty_order(akira, tr1, usdc_amount, eth_amount - gas_required, usdc_amount, sell_market_flags, 2, zero_router(), true);

        let buy_limit_flags = get_order_flags(false, false, true, false, false);

        let buy_order = spawn_order(akira, tr2, usdc_amount, eth_amount, buy_limit_flags, 0,  zero_router());
        start_cheat_caller_address(executor.contract_address, get_fee_recipient_exchange());

        executor.apply_ecosystem_trades(array![(sell_order, false)], array![buy_order], array![(1,false)], array![eth_amount - gas_required], 100, get_swap_gas_cost());

        //0 cause remaining eth was spent on gas
        assert!(core.balanceOf(sell_order.order.maker, eth) == 0 , "WRONG_MATCH_ETH_SELL");
        stop_cheat_caller_address(executor.contract_address);
    }  

}

#[cfg(test)]
mod tests_router_trade {
    use core::clone::Clone;
    use kurosawa_akira::test_utils::test_common::{deposit,get_eth_addr,tfer_eth_funds_to, get_fee_recipient_exchange, get_slow_mode, 
    get_trader_address_1,get_trader_address_2,get_trader_signer_and_pk_1,get_usdc_addr,tfer_usdc_funds_to,
    get_withdraw_action_cost,spawn_exchange,prepare_double_gas_fee_native,sign,get_trader_signer_and_pk_2};
    use core::{traits::Into,array::ArrayTrait,option::OptionTrait,traits::TryInto,result::ResultTrait};
    use starknet::{ContractAddress,info::get_block_number,get_caller_address};
    use debug::PrintTrait;
    use snforge_std::{start_cheat_caller_address,start_cheat_block_timestamp,stop_cheat_block_timestamp,stop_cheat_caller_address,declare,ContractClassTrait, start_cheat_block_number, stop_cheat_block_number};
    use core::dict::{Felt252Dict, Felt252DictTrait, SquashedFelt252Dict};
    use kurosawa_akira::utils::erc20::{IERC20DispatcherTrait,IERC20Dispatcher};
    use kurosawa_akira::Order::GasFee;
    use kurosawa_akira::utils::SlowModeLogic::SlowModeDelay;
    use serde::Serde;
    use kurosawa_akira::WithdrawComponent::{SignedWithdraw, Withdraw};
    use kurosawa_akira::FundsTraits::check_sign;
    use kurosawa_akira::Order::{SignedOrder, Order, FixedFee,OrderFee,OrderFlags, get_feeable_qty};
    use kurosawa_akira::signature::AkiraV0OffchainMessage::{OrderHashImpl,SNIP12MetadataImpl,IncreaseNonceHashImpl,WithdrawHashImpl};
    use kurosawa_akira::signature::V0OffchainMessage::{OffchainMessageHashImpl};


    use super::test_common_trade:: {prepare, get_maker_taker_fees, get_swap_gas_cost,spawn_order, spawn_double_qty_order, get_zero_router_fee, zero_router,register_router};
    use kurosawa_akira::LayerAkiraCore::{ILayerAkiraCoreDispatcher, ILayerAkiraCoreDispatcherTrait};
    use kurosawa_akira::LayerAkiraExternalGrantor::{IExternalGrantorDispatcher, IExternalGrantorDispatcherTrait};
    use kurosawa_akira::LayerAkiraExecutor::{ILayerAkiraExecutorDispatcher, ILayerAkiraExecutorDispatcherTrait};


    
    fn grant_allowances(spender:ContractAddress, trader:ContractAddress, token:ContractAddress, amount:u256) {
        start_cheat_caller_address((token), trader);
        IERC20Dispatcher{contract_address:token}.increaseAllowance(spender,amount);
        stop_cheat_caller_address((token));
    }

    // router ones
    fn get_order_flags(full_fill_only:bool, best_level_only:bool, post_only:bool, is_sell_side:bool, is_market_order:bool) -> OrderFlags{
        return OrderFlags{full_fill_only, best_level_only, post_only, is_sell_side, is_market_order, to_ecosystem_book: false, external_funds: is_market_order};
    }

     fn spawn_order_fee_spent(akira:(ILayerAkiraCoreDispatcher,IExternalGrantorDispatcher,ILayerAkiraExecutorDispatcher), maker:ContractAddress, price:u256, base_qty:u256,
            flags:OrderFlags,
            num_swaps_allowed:u16, router_signer:ContractAddress) ->SignedOrder {
        spawn_double_qty_order(akira, maker, price, base_qty, 0, flags, num_swaps_allowed, router_signer, false)
    }

    #[test]
    #[should_panic(expected: ("NOT_REGISTERED: not registered router 0",))]
    #[fork("block_based")]
    fn test_cant_execute_with_not_registered_router() {
        // Taker buy, full match happens with maker of same px
        let (akira, tr1, tr2, eth, usdc, eth_amount, usdc_amount) = prepare();
        let(core, _, executor) = akira;
        
        let sell_order = spawn_order(akira, tr1, usdc_amount, eth_amount, 
                get_order_flags(false, false, true, true, false), 0, zero_router());
        let buy_order = spawn_order(akira, tr2, usdc_amount, eth_amount, 
                get_order_flags(false, false, false, false, true), 2, zero_router());
        
        start_cheat_caller_address(executor.contract_address, get_fee_recipient_exchange());
        executor.apply_single_execution_step(buy_order, array![(sell_order,0)], usdc_amount*eth_amount / buy_order.order.qty.base_asset, 100,get_swap_gas_cost(), false);
        stop_cheat_caller_address(executor.contract_address);
    }  



    #[test]
    #[fork("block_based")]
    fn test_execute_with_buy_taker_succ() {
        // Taker buy, full match happens with maker of same px
        let (akira, tr1, tr2, eth, usdc, eth_amount, usdc_amount) = prepare();
        let(core, _, executor) = akira;
        

        let router:ContractAddress = 5.try_into().unwrap();
        let (signer, signer_pk) = get_trader_signer_and_pk_2();
        let signer:ContractAddress = signer.try_into().unwrap();
        
        deposit(tr1, eth_amount, eth, core);

        
        register_router(akira, tr1, signer, router);

        let gas_fee = 100 * get_swap_gas_cost().into();
        
        // grant necesasry allowances 
        grant_allowances(executor.contract_address, tr2, eth, gas_fee);
        grant_allowances(executor.contract_address, tr2, usdc, usdc_amount);

        let mut buy_order = spawn_order(akira, tr2, usdc_amount, eth_amount, 
                get_order_flags(false, false, false, false, true), 2, signer);

        buy_order.router_sign = sign(executor.get_order_hash(buy_order.order), signer.into(), signer_pk);

        let sell_order = spawn_order(akira, tr1, usdc_amount, eth_amount, 
                get_order_flags(false, false, true, true, false), 0, zero_router());
        

        let eth_erc = IERC20Dispatcher{contract_address:eth};
        let usdc_erc = IERC20Dispatcher{contract_address:usdc};
        let taker = buy_order.order.maker;

        let (eth_b, usdc_b, router_b) = (eth_erc.balanceOf(taker), usdc_erc.balanceOf(taker), core.balanceOf(router, eth));



        start_cheat_caller_address(executor.contract_address, get_fee_recipient_exchange());
        assert(executor.apply_single_execution_step(buy_order, array![(sell_order, 0)],  (usdc_amount) * eth_amount / buy_order.order.qty.base_asset, 100, get_swap_gas_cost(), false), 'FAILED_MATCH');
        stop_cheat_caller_address(executor.contract_address);



        let maker_fee = get_feeable_qty(sell_order.order.fee.trade_fee, usdc_amount, true);
        
        assert(core.balanceOf(sell_order.order.maker, usdc) == usdc_amount - maker_fee, 'WRONG_MATCH_RECIEVE_USDC');
        
        assert(core.balanceOf(buy_order.order.maker, usdc) == 0,'WRONG_MATCH_SEND_USDC');
                
        let taker_fee = get_feeable_qty(buy_order.order.fee.trade_fee, eth_amount, false);
        let router_fee = get_feeable_qty(buy_order.order.fee.router_fee, eth_amount, false);
        
        assert(core.balanceOf(sell_order.order.maker, eth) == 0, 'WRONG_MATCH_SEND_ETH');
       
        assert(core.balanceOf(buy_order.order.maker, eth) == 0, 'WRONG_ROUTER_T_BALANCE_ETH');
        assert(core.balanceOf(buy_order.order.maker, usdc) == 0, 'WRONG_ROUTER_T_BALANCE_USDC');

        let (eth_b, usdc_b) = (eth_erc.balanceOf(taker) - eth_b, usdc_b - usdc_erc.balanceOf(taker));
        assert(usdc_b == usdc_amount, 'DEDUCTED_AS_EXPECTED');
        assert(eth_b + gas_fee  + taker_fee + router_fee == eth_amount, 'RECEIVED_AS_EXPECTED');
        assert!(core.balanceOf(router, eth) - router_b == router_fee, "WRONG_ROUTER_RECEIVED {} {}", core.balanceOf(router, eth), router_b);
        
    } 

    #[test]
    #[fork("block_based")]
    fn test_execute_with_sell_taker_succ() {
        // Taker buy, full match happens with maker of same px
        let (akira, tr1, tr2, eth, usdc, eth_amount, usdc_amount) = prepare();
        let(core, _, executor) = akira;
        
        let router: ContractAddress = 5.try_into().unwrap();
        let (signer, signer_pk) = get_trader_signer_and_pk_2();
        let signer: ContractAddress = signer.try_into().unwrap();
        register_router(akira, tr1, signer, router);
        
        deposit(tr1, usdc_amount, usdc, core);
        let gas_fee = 100 * get_swap_gas_cost().into();
        
        grant_allowances(executor.contract_address, tr2, eth, gas_fee + eth_amount+10000000);
        
        let mut sell_order = spawn_order(akira, tr2, usdc_amount, eth_amount, 
                get_order_flags(false, false, false, true, true), 1, signer);
        sell_order.router_sign = sign(executor.get_order_hash(sell_order.order), signer.into(), signer_pk);


        let buy_order = spawn_order(akira, tr1, usdc_amount, eth_amount, 
                get_order_flags(false, false, true, false, false), 0, zero_router());


        let eth_erc = IERC20Dispatcher{contract_address:eth};
        let usdc_erc = IERC20Dispatcher{contract_address:usdc};
        let taker = sell_order.order.maker;
        let (eth_b, usdc_b, router_b) = (eth_erc.balanceOf(taker), usdc_erc.balanceOf(taker), core.balanceOf(router, usdc));

        start_cheat_caller_address(executor.contract_address, get_fee_recipient_exchange());
        assert(executor.apply_single_execution_step(sell_order, array![(buy_order,0)],  eth_amount, 100, get_swap_gas_cost(), false), 'FAILED_MATCH');
        stop_cheat_caller_address(executor.contract_address);
         
        assert(core.balanceOf(sell_order.order.maker, eth) == 0, 'WRONG_ROUTER_T_BALANCE_ETH');
        assert(core.balanceOf(sell_order.order.maker, usdc) == 0, 'WRONG_ROUTER_T_BALANCE_USDC');
        let taker_fee = get_feeable_qty(sell_order.order.fee.trade_fee, usdc_amount, false);
        let router_fee = get_feeable_qty(sell_order.order.fee.router_fee, usdc_amount, false);
        assert(core.balanceOf(router, usdc) - router_b == router_fee, 'WRONG_ROUTER_RECEIVED');

        let maker_fee = get_feeable_qty(buy_order.order.fee.trade_fee, eth_amount, true);
        assert(core.balanceOf(buy_order.order.maker, eth) == eth_amount - maker_fee, 'WRONG_MATCH_RECIEVE_ETH');
        assert(core.balanceOf(buy_order.order.maker, usdc) == 0, 'WRONG_SEND_USDC');


        let (eth_b, usdc_b) = (eth_b - eth_erc.balanceOf(taker), usdc_erc.balanceOf(taker) - usdc_b);
        assert(usdc_b + taker_fee + router_fee == usdc_amount, 'RECEIVED_AS_EXPECTED');

        assert(eth_b - gas_fee == eth_amount, 'DEDUCTED_AS_EXPECTED');



        start_cheat_caller_address(executor.contract_address, router);
        assert!(core.balanceOf(router, usdc) == router_fee, "WRONG_ROUTER_WITHDRAW: {}, {}", core.balanceOf(router, usdc),router_fee);
        
        stop_cheat_caller_address(executor.contract_address);

        
    }  

        #[test]
    #[fork("block_based")]
    fn test_execute_with_buy_taker_succ_spent_side_fee_for_both_parties() {
        // Taker buy, full match happens with maker of same px
        let (akira, tr1, tr2, eth, usdc, eth_amount, usdc_amount) = prepare();
        let(core, _, executor) = akira;
        
        let router:ContractAddress = 5.try_into().unwrap();
        let (signer, signer_pk) = get_trader_signer_and_pk_2();
        let signer:ContractAddress = signer.try_into().unwrap();
        
        register_router(akira, tr1, signer, router);

        let gas_fee = 100 * get_swap_gas_cost().into();
        

        let mut buy_order = spawn_order_fee_spent(akira, tr2, usdc_amount, eth_amount, 
                get_order_flags(false, false, false, false, true), 2, signer);

        buy_order.router_sign = sign(executor.get_order_hash(buy_order.order), signer.into(), signer_pk);

        let sell_order = spawn_order_fee_spent(akira, tr1, usdc_amount, eth_amount, 
                get_order_flags(false, false, true, true, false), 0, zero_router());
        

        let eth_erc = IERC20Dispatcher{contract_address:eth};
        let usdc_erc = IERC20Dispatcher{contract_address:usdc};
        let taker = buy_order.order.maker;


        
        // grant necesasry allowances 
        // grant_allowances(akira, tr2, eth, gas_fee);
        let maker_fee = get_feeable_qty(sell_order.order.fee.trade_fee, eth_amount, true);
        let taker_fee = get_feeable_qty(buy_order.order.fee.trade_fee, usdc_amount, false);
        let router_fee = get_feeable_qty(buy_order.order.fee.router_fee, usdc_amount, false);
        deposit(tr1, eth_amount + maker_fee, eth, core);
        grant_allowances(executor.contract_address, tr2, usdc, usdc_amount + taker_fee + router_fee);



        let (eth_b, usdc_b, router_b) = (eth_erc.balanceOf(taker), usdc_erc.balanceOf(taker), core.balanceOf(router, usdc));


        start_cheat_caller_address(executor.contract_address, get_fee_recipient_exchange());
        assert(executor.apply_single_execution_step(buy_order, array![(sell_order, 0)],  usdc_amount  + taker_fee + router_fee, 100, get_swap_gas_cost(), false), 'FAILED_MATCH');
        stop_cheat_caller_address(executor.contract_address);


        
        assert(core.balanceOf(sell_order.order.maker, usdc) == usdc_amount, 'WRONG_MATCH_RECIEVE_USDC');
        assert(core.balanceOf(buy_order.order.maker, usdc) == 0,'WRONG_MATCH_SEND_USDC');
                
        assert(core.balanceOf(sell_order.order.maker, eth) == 0, 'WRONG_MATCH_SEND_ETH');
       
        assert(core.balanceOf(buy_order.order.maker, eth) == 0, 'WRONG_ROUTER_T_BALANCE_ETH');
        assert(core.balanceOf(buy_order.order.maker, usdc) == 0, 'WRONG_ROUTER_T_BALANCE_USDC');

        let (eth_b, usdc_b) = (eth_erc.balanceOf(taker) - eth_b, usdc_b - usdc_erc.balanceOf(taker));
        assert(usdc_b == usdc_amount + taker_fee + router_fee, 'DEDUCTED_AS_EXPECTED');
        assert(eth_b + gas_fee  == eth_amount, 'RECEIVED_AS_EXPECTED');
        assert(core.balanceOf(router, usdc) - router_b == router_fee, 'WRONG_ROUTER_RECEIVED');
        
    } 


    #[test]
    #[fork("block_based")]
    fn test_punish_router() {
        // Taker buy, full match happens with maker of same px
        let (akira, tr1, tr2, eth, usdc, eth_amount, usdc_amount) = prepare();
        let(core, router_contract, executor) = akira;
        
        let router:ContractAddress = 5.try_into().unwrap();
        let (signer, signer_pk) = get_trader_signer_and_pk_2();
        let signer:ContractAddress = signer.try_into().unwrap();
        
        deposit(tr1, eth_amount, eth, core);
        register_router(akira, tr1, signer, router);
        let gas_fee = 100 * get_swap_gas_cost().into();
        
        //miss  grant of  necesasry allowances 

        let mut buy_order = spawn_order(akira, tr2, usdc_amount, eth_amount, 
                get_order_flags(false, false, false, false, true), 2, signer);

        buy_order.router_sign = sign(executor.get_order_hash(buy_order.order), signer.into(), signer_pk);

        let sell_order = spawn_order(akira, tr1, usdc_amount, eth_amount, 
                get_order_flags(false, false, true, true, false), 0, zero_router());
        

        let router_b = router_contract.balance_of_router(router, eth);

        start_cheat_caller_address(executor.contract_address, get_fee_recipient_exchange());
        assert(!executor.apply_single_execution_step(buy_order, array![(sell_order, 0)],  usdc_amount * eth_amount / buy_order.order.qty.base_asset, 100, get_swap_gas_cost(), false), 'EXPECTS_FAIL');
        stop_cheat_caller_address(executor.contract_address);
        let charge = 2 * gas_fee * router_contract.get_punishment_factor_bips().into() / 10000;
        assert(router_b - router_contract.balance_of_router(router, eth) == charge, 'WRONG_RECEIVED');
    }  

}

#[cfg(test)]
mod tests_quote_qty_ecosystem_trade_01 {
    use core::clone::Clone;
    use kurosawa_akira::test_utils::test_common::{deposit,get_eth_addr,tfer_eth_funds_to,get_fee_recipient_exchange,get_slow_mode, 
    get_trader_address_1,get_trader_address_2,get_trader_signer_and_pk_1,get_usdc_addr,tfer_usdc_funds_to,
    get_withdraw_action_cost,spawn_exchange, prepare_double_gas_fee_native, sign, get_trader_signer_and_pk_2};
    use core::{traits::Into,array::ArrayTrait,option::OptionTrait,traits::TryInto,result::ResultTrait};
    use starknet::{ContractAddress,info::get_block_number,get_caller_address};
    use debug::PrintTrait;
    use snforge_std::{start_cheat_caller_address,start_cheat_block_timestamp,stop_cheat_block_timestamp,stop_cheat_caller_address,declare,ContractClassTrait, start_cheat_block_number, stop_cheat_block_number};
    use core::dict::{Felt252Dict, Felt252DictTrait, SquashedFelt252Dict};
    use kurosawa_akira::utils::erc20::{IERC20DispatcherTrait,IERC20Dispatcher};
    use kurosawa_akira::Order::GasFee;
    use kurosawa_akira::utils::SlowModeLogic::SlowModeDelay;
    use serde::Serde;
    use kurosawa_akira::WithdrawComponent::{SignedWithdraw, Withdraw};
    use kurosawa_akira::FundsTraits::check_sign;
    use kurosawa_akira::Order::{SignedOrder, Order, FixedFee,OrderFee,OrderFlags, get_feeable_qty};
    use kurosawa_akira::signature::AkiraV0OffchainMessage::{OrderHashImpl,SNIP12MetadataImpl,IncreaseNonceHashImpl,WithdrawHashImpl};
    use kurosawa_akira::signature::V0OffchainMessage::{OffchainMessageHashImpl};

    use kurosawa_akira::LayerAkiraCore::{ILayerAkiraCoreDispatcher, ILayerAkiraCoreDispatcherTrait};
    use kurosawa_akira::LayerAkiraExternalGrantor::{IExternalGrantorDispatcher, IExternalGrantorDispatcherTrait};
    use kurosawa_akira::LayerAkiraExecutor::{ILayerAkiraExecutorDispatcher, ILayerAkiraExecutorDispatcherTrait};



    use super::test_common_trade:: {prepare,get_maker_taker_fees,get_swap_gas_cost,spawn_order, spawn_double_qty_order, get_zero_router_fee,zero_router};



    fn get_order_flags(full_fill_only:bool,best_level_only:bool,post_only:bool,is_sell_side:bool,is_market_order:bool,) -> OrderFlags{
        return OrderFlags{full_fill_only, best_level_only, post_only, is_sell_side, is_market_order, to_ecosystem_book: true, external_funds:false};
    }

    fn test_quote_qty_draft(quote_qty_01: u256, quote_qty_02: u256, actual_qty: u256) {
        // Taker buy, full match happens with maker of same px
        let (akira, tr1, tr2, eth, usdc, eth_amount, usdc_amount) = prepare();
        let(core, _, executor) = akira;
        
        
        let gas_required:u256 = 100 * get_swap_gas_cost().into(); 
        deposit(tr1, eth_amount + gas_required, eth, core); deposit(tr2, usdc_amount, usdc, core);


        let sell_market_flags = get_order_flags(false, false, false, true, true);
        let sell_order = spawn_double_qty_order(akira, tr1, usdc_amount, eth_amount, quote_qty_01, sell_market_flags, 2, zero_router(), true);

        let buy_limit_flags = get_order_flags(false, false, true, false, false);

        let buy_order = spawn_double_qty_order(akira, tr2, usdc_amount, eth_amount, quote_qty_02, buy_limit_flags, 0,  zero_router(), true);
        start_cheat_caller_address(executor.contract_address, get_fee_recipient_exchange());

        executor.apply_ecosystem_trades(array![(sell_order, false)], array![buy_order], array![(1,false)], array![0], 100, get_swap_gas_cost());

        //0 cause remaining eth was spent on gas
        assert!(core.balanceOf(sell_order.order.maker, eth) == (usdc_amount - actual_qty) * (eth_amount / usdc_amount), "WRONG_MATCH_ETH_SELL {}, {}", core.balanceOf(sell_order.order.maker, eth), (usdc_amount - actual_qty) * (eth_amount / usdc_amount));
        stop_cheat_caller_address(executor.contract_address);
    }  



    #[test]
    #[fork("block_based")]
    fn test_double_qty_SELL_maker_01() {
        let quote_qty = 2000_000_000;
        test_quote_qty_draft(quote_qty, 0, quote_qty);
    }  

    #[test]
    #[fork("block_based")]
    fn test_double_qty_SELL_maker_02_match_quote_qty() {
        let quote_qty = 2000_000_000 - 1;
        test_quote_qty_draft(quote_qty, 0, quote_qty);
    }  


    #[test]
    #[fork("block_based")]
    fn test_double_qty_SELL_maker_03_match_base_qty() {
        let quote_qty = 2000_000_000 + 1;
        test_quote_qty_draft(quote_qty, 0, quote_qty - 1);
    }  

    #[test]
    #[fork("block_based")]
    fn test_double_qty_SELL_maker_04_double() {
        let quote_qty = 2000_000_000;
        test_quote_qty_draft(quote_qty - 2, quote_qty - 3, quote_qty - 3);
    }  

    #[test]
    #[fork("block_based")]
    fn test_double_qty_SELL_maker_05_double() {
        let quote_qty = 2000_000_000;
        test_quote_qty_draft(quote_qty - 3, quote_qty - 2, quote_qty - 3);
    }  

    #[test]
    #[fork("block_based")]
    fn test_double_qty_BUY_maker_01_match_quote_qty() {
        // Taker buy, full match happens with maker of same px
        let (akira, tr1, tr2, eth, usdc, eth_amount, usdc_amount) = prepare();
        let(core, _, executor) = akira;
        
        let quote_qty = usdc_amount - 1;
        
        let gas_required:u256 = 100 * get_swap_gas_cost().into(); 
        assert(core.balanceOf(tr1, eth) == 0, 'failed balance check');
        deposit(tr2, eth_amount, eth, core);
        deposit(tr1, usdc_amount, usdc, core);


        let buy_limit_flags = get_order_flags(false, false, false, false, true);
        let buy_order = spawn_order(akira, tr1, usdc_amount, eth_amount, buy_limit_flags, 2, zero_router());

        let sell_market_flags = get_order_flags(false, false, true, true, false);

        let sell_order = spawn_double_qty_order(akira, tr2, usdc_amount, eth_amount, quote_qty, sell_market_flags, 0,  zero_router(), true);
        start_cheat_caller_address(executor.contract_address, get_fee_recipient_exchange());

        executor.apply_ecosystem_trades(array![(buy_order, false)], array![sell_order], array![(1,false)], array![0], 100, get_swap_gas_cost());

        //0 cause remaining eth was spent on gas
        assert!(core.balanceOf(buy_order.order.maker, usdc) == 1, "WRONG_MATCH");
        stop_cheat_caller_address(executor.contract_address);
    }  
}

#[cfg(test)]
mod tests_quote_qty_ecosystem_trade_02 {
    use core::clone::Clone;
    use kurosawa_akira::test_utils::test_common::{deposit,get_eth_addr,tfer_eth_funds_to, get_fee_recipient_exchange, get_slow_mode, 
    get_trader_address_1,get_trader_address_2,get_trader_signer_and_pk_1,get_usdc_addr,tfer_usdc_funds_to,
    get_withdraw_action_cost,spawn_exchange,prepare_double_gas_fee_native,sign,get_trader_signer_and_pk_2};
    use core::{traits::Into,array::ArrayTrait,option::OptionTrait,traits::TryInto,result::ResultTrait};
    use starknet::{ContractAddress,info::get_block_number,get_caller_address};
    use debug::PrintTrait;
    use snforge_std::{start_cheat_caller_address,start_cheat_block_timestamp,stop_cheat_block_timestamp,stop_cheat_caller_address,declare,ContractClassTrait, start_cheat_block_number, stop_cheat_block_number};
    use core::dict::{Felt252Dict, Felt252DictTrait, SquashedFelt252Dict};
    use kurosawa_akira::utils::erc20::{IERC20DispatcherTrait,IERC20Dispatcher};
    use kurosawa_akira::Order::GasFee;
    use kurosawa_akira::utils::SlowModeLogic::SlowModeDelay;
    use serde::Serde;
    use kurosawa_akira::WithdrawComponent::{SignedWithdraw, Withdraw};
    use kurosawa_akira::FundsTraits::check_sign;
    use kurosawa_akira::Order::{SignedOrder, Order, FixedFee,OrderFee,OrderFlags, get_feeable_qty};
    use kurosawa_akira::signature::AkiraV0OffchainMessage::{OrderHashImpl,SNIP12MetadataImpl,IncreaseNonceHashImpl,WithdrawHashImpl};

    use kurosawa_akira::signature::V0OffchainMessage::{OffchainMessageHashImpl};

    use super::test_common_trade:: {prepare, get_maker_taker_fees, get_swap_gas_cost,spawn_order, spawn_double_qty_order, get_zero_router_fee, zero_router,register_router};
    use kurosawa_akira::LayerAkiraCore::{ILayerAkiraCoreDispatcher, ILayerAkiraCoreDispatcherTrait};
    use kurosawa_akira::LayerAkiraExternalGrantor::{IExternalGrantorDispatcher, IExternalGrantorDispatcherTrait};
    use kurosawa_akira::LayerAkiraExecutor::{ILayerAkiraExecutorDispatcher, ILayerAkiraExecutorDispatcherTrait};


    fn grant_allowances(akira:ILayerAkiraCoreDispatcher, trader:ContractAddress, token:ContractAddress, amount:u256) {
        start_cheat_caller_address((token), trader);
        IERC20Dispatcher{contract_address:token}.increaseAllowance(akira.contract_address,amount);
        stop_cheat_caller_address((token));
    }

    // router ones
    fn get_order_router_flags(full_fill_only:bool, best_level_only:bool, post_only:bool, is_sell_side:bool, is_market_order:bool) -> OrderFlags{
        return OrderFlags{full_fill_only, best_level_only, post_only, is_sell_side, is_market_order, to_ecosystem_book: false, external_funds: is_market_order};
    }

    fn get_order_ecosystem_flags(full_fill_only:bool,best_level_only:bool,post_only:bool,is_sell_side:bool,is_market_order:bool,) -> OrderFlags{
        return OrderFlags{full_fill_only, best_level_only, post_only, is_sell_side, is_market_order, to_ecosystem_book: true, external_funds:false};
    }

    fn test_draft(sell_order_01_base_qty: u256, sell_order_01_quote_qty: u256, sell_order_02_base_qty: u256, sell_order_02_quote_qty: u256) {
        // Taker buy, full match happens with maker of same px
        let (akira, tr1, tr2, eth, usdc, eth_amount, usdc_amount) = prepare();
        let(core, _, executor) = akira;
        
        let gas_required:u256 = 2 * 100 * get_swap_gas_cost().into(); 
        deposit(tr1, eth_amount + gas_required, eth, core); deposit(tr2, usdc_amount, usdc, core);


        let sell_market_flags = get_order_ecosystem_flags(false, false, false, true, true);
        let sell_order_01 = spawn_double_qty_order(akira, tr1, usdc_amount, sell_order_01_base_qty, sell_order_01_quote_qty, sell_market_flags, 2, zero_router(),  true);
        let sell_order_02 = spawn_double_qty_order(akira, tr1, usdc_amount, sell_order_02_base_qty, sell_order_02_quote_qty, sell_market_flags, 4, zero_router(), true);

        let buy_limit_flags = get_order_ecosystem_flags(false, false, true, false, false);

        let buy_order = spawn_double_qty_order(akira, tr2, usdc_amount, eth_amount, 0, buy_limit_flags, 0,  zero_router(), true);
        start_cheat_caller_address(executor.contract_address, get_fee_recipient_exchange());

        executor.apply_ecosystem_trades(array![(sell_order_01, false), (sell_order_02, false)], array![buy_order], array![(1,false), (1,true)], array![0, 0], 100, get_swap_gas_cost());

        //0 cause remaining eth was spent on gas
        assert!(core.balanceOf(sell_order_01.order.maker, eth) == 0, "WRONG_MATCH_ETH_SELL {}, {}", core.balanceOf(sell_order_01.order.maker, eth), 0);
        assert!(core.balanceOf(buy_order.order.maker, usdc) == 0, "WRONG_MATCH {}, {}", core.balanceOf(buy_order.order.maker, usdc), 0);
        stop_cheat_caller_address(executor.contract_address);
    }  


    #[test]
    #[fork("block_based")]
    fn test_quote_qty_only_base() {
        let base_qty = 1_000_000_000_000_000_000;
        let quote_qty = 2000_000_000;
        test_draft(base_qty / 2, 0, base_qty / 2, 0);
    }  

    #[test]
    #[fork("block_based")]
    fn test_quote_qty_only_quote() {
        let base_qty = 1_000_000_000_000_000_000;
        let quote_qty = 2000_000_000;
        test_draft(0, quote_qty / 2, 0, quote_qty / 2);
    }  

        #[test]
    #[fork("block_based")]
    fn test_quote_qty_both() {
        let base_qty = 1_000_000_000_000_000_000;
        let quote_qty = 2000_000_000;
        test_draft(0, quote_qty / 2, base_qty / 2, 0);
    }  

    #[test]
    #[fork("block_based")]
    fn test_quote_qty_both_02() {
        let base_qty = 1_000_000_000_000_000_000;
        let quote_qty = 2000_000_000;
        test_draft(base_qty / 2, 0, 0, quote_qty / 2);
    }  
}

#[cfg(test)]
mod tests_quote_qty_router_trade_01 {
    use core::clone::Clone;
    use kurosawa_akira::test_utils::test_common::{deposit,get_eth_addr,tfer_eth_funds_to, get_fee_recipient_exchange, get_slow_mode, 
    get_trader_address_1,get_trader_address_2,get_trader_signer_and_pk_1,get_usdc_addr,tfer_usdc_funds_to,
    get_withdraw_action_cost,spawn_exchange,prepare_double_gas_fee_native,sign,get_trader_signer_and_pk_2};
    use core::{traits::Into,array::ArrayTrait,option::OptionTrait,traits::TryInto,result::ResultTrait};
    use starknet::{ContractAddress,info::get_block_number,get_caller_address};
    use debug::PrintTrait;
    use snforge_std::{start_cheat_caller_address,start_cheat_block_timestamp,stop_cheat_block_timestamp,stop_cheat_caller_address,declare,ContractClassTrait, start_cheat_block_number, stop_cheat_block_number};
    use core::dict::{Felt252Dict, Felt252DictTrait, SquashedFelt252Dict};
    use kurosawa_akira::utils::erc20::{IERC20DispatcherTrait,IERC20Dispatcher};
    use kurosawa_akira::Order::GasFee;
    use kurosawa_akira::utils::SlowModeLogic::SlowModeDelay;
    use serde::Serde;
    use kurosawa_akira::WithdrawComponent::{SignedWithdraw, Withdraw};
    use kurosawa_akira::FundsTraits::check_sign;
    use kurosawa_akira::Order::{SignedOrder, Order, FixedFee,OrderFee,OrderFlags, get_feeable_qty};
    use kurosawa_akira::signature::AkiraV0OffchainMessage::{OrderHashImpl,SNIP12MetadataImpl,IncreaseNonceHashImpl,WithdrawHashImpl};
    use kurosawa_akira::signature::V0OffchainMessage::{OffchainMessageHashImpl};
    use kurosawa_akira::LayerAkiraCore::{ILayerAkiraCoreDispatcher, ILayerAkiraCoreDispatcherTrait};
    use kurosawa_akira::LayerAkiraExternalGrantor::{IExternalGrantorDispatcher, IExternalGrantorDispatcherTrait};
    use kurosawa_akira::LayerAkiraExecutor::{ILayerAkiraExecutorDispatcher, ILayerAkiraExecutorDispatcherTrait};


    use super::test_common_trade:: {prepare, get_maker_taker_fees, get_swap_gas_cost,spawn_order, spawn_double_qty_order, get_zero_router_fee, zero_router,register_router};
    
    fn grant_allowances(akira:ContractAddress, trader:ContractAddress, token:ContractAddress, amount:u256) {
        start_cheat_caller_address((token), trader);
        IERC20Dispatcher{contract_address:token}.increaseAllowance(akira,amount);
        stop_cheat_caller_address((token));
    }

    // router ones
    fn get_order_flags(full_fill_only:bool, best_level_only:bool, post_only:bool, is_sell_side:bool, is_market_order:bool) -> OrderFlags{
        return OrderFlags{full_fill_only, best_level_only, post_only, is_sell_side, is_market_order, to_ecosystem_book: false, external_funds: is_market_order};
    }

    fn test_roter_trade_double_qty_semantic_BUY_maker_draft(change_side: bool, price: u256, base_qty: u256, quote_qty: u256, expected_qty: u256) {
        let (akira, tr1, tr2, eth, usdc, eth_amount, usdc_amount) = prepare();
        let(core, _, executor) = akira;
        
        let router: ContractAddress = 5.try_into().unwrap();
        let (signer, signer_pk) = get_trader_signer_and_pk_2();
        let signer: ContractAddress = signer.try_into().unwrap();
        register_router(akira, tr1, signer, router);
        
        if ! change_side {deposit(tr1, usdc_amount, usdc, core);} else {deposit(tr1, eth_amount, eth, core);}
        let gas_fee = 100 * get_swap_gas_cost().into();
        
        grant_allowances(executor.contract_address, tr2, eth, gas_fee + eth_amount+10000000);
        grant_allowances(executor.contract_address, tr2, usdc, usdc_amount+10000000);
        
        let mut taker_order = spawn_double_qty_order(akira, tr2, price, base_qty, quote_qty, 
                get_order_flags(false, false, false, !change_side, true), 1, signer, true);
        taker_order.router_sign = sign(executor.get_order_hash(taker_order.order), signer.into(), signer_pk);


        let maker_order = spawn_order(akira, tr1, price, base_qty, 
                get_order_flags(false, false, true, change_side, false), 0, zero_router());


        let eth_erc = IERC20Dispatcher{contract_address:eth};
        let usdc_erc = IERC20Dispatcher{contract_address:usdc};
        let taker = taker_order.order.maker;
        let (eth_b, usdc_b) = (eth_erc.balanceOf(taker), usdc_erc.balanceOf(taker));
        let router_b = if !change_side{core.balanceOf(router, usdc)} else {core.balanceOf(router, eth)};

        let actual_matched_qty = if !change_side {(base_qty / price) * expected_qty} else {expected_qty * 1};

        start_cheat_caller_address(executor.contract_address, get_fee_recipient_exchange());
        assert(executor.apply_single_execution_step(taker_order, array![(maker_order,0)],  actual_matched_qty, 100, get_swap_gas_cost(), false), 'FAILED_MATCH');
        stop_cheat_caller_address(executor.contract_address);
         
        assert(core.balanceOf(taker_order.order.maker, eth) == 0, 'WRONG_ROUTER_T_BALANCE_ETH');
        assert(core.balanceOf(taker_order.order.maker, usdc) == 0, 'WRONG_ROUTER_T_BALANCE_USDC');
        let mut router_fee = 0;
        if !change_side{
            router_fee = get_feeable_qty(taker_order.order.fee.router_fee, expected_qty, false);
            assert(core.balanceOf(router, usdc) - router_b == router_fee, 'WRONG_ROUTER_RECEIVED');
        }
        else {
            router_fee = get_feeable_qty(taker_order.order.fee.router_fee, (base_qty / price) * expected_qty, false);
            assert!(core.balanceOf(router, eth) - router_b == router_fee, "WRONG_ROUTER_RECEIVED: {}, {}", core.balanceOf(router, eth) - router_b, router_fee);
        }


        let maker_fee = get_feeable_qty(maker_order.order.fee.trade_fee, actual_matched_qty, true);
        if !change_side{
            assert(core.balanceOf(maker_order.order.maker, eth) == actual_matched_qty - maker_fee, 'WRONG_MATCH_RECIEVE_ETH');
            assert(core.balanceOf(maker_order.order.maker, usdc) == price - expected_qty, 'WRONG_SEND_USDC');
        }
        else {
            assert(core.balanceOf(maker_order.order.maker, eth) == (price - expected_qty) * base_qty / price, 'WRONG_MATCH_RECIEVE_ETH');
            assert(core.balanceOf(maker_order.order.maker, usdc) == expected_qty - maker_fee, 'WRONG_SEND_USDC');
        }


        start_cheat_caller_address(executor.contract_address, router);
        if !change_side{
            let r_b = usdc_erc.balanceOf(router);
            // akira.router_withdraw(usdc, router_fee, router);
            assert(core.balanceOf(router,usdc) == router_fee, 'WRONG_ROUTER_WITHDRAW');
        }
        else {
            let r_b = eth_erc.balanceOf(router);
            // akira.router_withdraw(eth, router_fee, router);
            assert(core.balanceOf(router,eth) == router_fee, 'WRONG_ROUTER_WITHDRAW');
        }
        stop_cheat_caller_address(executor.contract_address);
    }  

    #[test]
    #[fork("block_based")]
    fn test_roter_trade_double_qty_semantic_BUY_maker_01() {

        let price = 2000_000_000; // 2000 usdc
        let base_qty = 1_000_000_000_000_000_000; // 1 eth
        let quote_qty = price;
        test_roter_trade_double_qty_semantic_BUY_maker_draft(false, price, base_qty, quote_qty, quote_qty);
    }  

    #[test]
    #[fork("block_based")]
    fn test_roter_trade_double_qty_semantic_BUY_maker_02_match_quote_qty() {
        let price = 2000_000_000; // 2000 usdc
        let base_qty = 1_000_000_000_000_000_000; // 1 eth
        let quote_qty = price - 1;
        test_roter_trade_double_qty_semantic_BUY_maker_draft(false, price, base_qty, quote_qty, quote_qty);
    }  

     #[test]
    #[fork("block_based")]
    fn test_roter_trade_double_qty_semantic_BUY_maker_03_match_base_qty() {
        let price = 2000_000_000; // 2000 usdc
        let base_qty = 1_000_000_000_000_000_000; // 1 eth
        let quote_qty = price + 1;
        test_roter_trade_double_qty_semantic_BUY_maker_draft(false, price, base_qty, quote_qty, quote_qty - 1);
    }  

    #[test]
    #[fork("block_based")]
    fn test_roter_trade_double_qty_semantic_SELL_maker_01() {
        let price = 2000_000_000; // 2000 usdc
        let base_qty = 1_000_000_000_000_000_000; // 1 eth
        let quote_qty = price;
        test_roter_trade_double_qty_semantic_BUY_maker_draft(true, price, base_qty, quote_qty, quote_qty);
    }  

    #[test]
    #[fork("block_based")]
    fn test_roter_trade_double_qty_semantic_SELL_maker_02_match_quote_qty() {
        let price = 2000_000_000; // 2000 usdc
        let base_qty = 1_000_000_000_000_000_000; // 1 eth
        let quote_qty = price - 1;
        test_roter_trade_double_qty_semantic_BUY_maker_draft(true, price, base_qty, quote_qty, quote_qty);
    }  


    #[test]
    #[fork("block_based")]
    fn test_roter_trade_double_qty_semantic_SELL_maker_03_match_base_qty() {
        let price = 2000_000_000; // 2000 usdc
        let base_qty = 1_000_000_000_000_000_000; // 1 eth
        let quote_qty = price + 1;
        test_roter_trade_double_qty_semantic_BUY_maker_draft(true, price, base_qty, quote_qty, quote_qty - 1);
    }  
}


#[cfg(test)]
mod tests_quote_qty_router_trade_02 {
    use core::clone::Clone;
    use kurosawa_akira::test_utils::test_common::{deposit,get_eth_addr,tfer_eth_funds_to, get_fee_recipient_exchange, get_slow_mode, 
    get_trader_address_1,get_trader_address_2,get_trader_signer_and_pk_1,get_usdc_addr,tfer_usdc_funds_to,
    get_withdraw_action_cost,spawn_exchange,prepare_double_gas_fee_native,sign,get_trader_signer_and_pk_2};
    use core::{traits::Into,array::ArrayTrait,option::OptionTrait,traits::TryInto,result::ResultTrait};
    use starknet::{ContractAddress,info::get_block_number,get_caller_address};
    use debug::PrintTrait;
    use snforge_std::{start_cheat_caller_address,start_cheat_block_timestamp,stop_cheat_block_timestamp,stop_cheat_caller_address,declare,ContractClassTrait, start_cheat_block_number, stop_cheat_block_number};
    use core::dict::{Felt252Dict, Felt252DictTrait, SquashedFelt252Dict};
    use kurosawa_akira::utils::erc20::{IERC20DispatcherTrait,IERC20Dispatcher};
    use kurosawa_akira::Order::GasFee;
    use kurosawa_akira::utils::SlowModeLogic::SlowModeDelay;
    use serde::Serde;
    use kurosawa_akira::WithdrawComponent::{SignedWithdraw, Withdraw};
    use kurosawa_akira::FundsTraits::check_sign;
    use kurosawa_akira::Order::{SignedOrder, Order, FixedFee,OrderFee,OrderFlags, get_feeable_qty};
    use kurosawa_akira::signature::AkiraV0OffchainMessage::{OrderHashImpl,SNIP12MetadataImpl,IncreaseNonceHashImpl,WithdrawHashImpl};
    use kurosawa_akira::signature::V0OffchainMessage::{OffchainMessageHashImpl};
    use kurosawa_akira::LayerAkiraCore::{ILayerAkiraCoreDispatcher, ILayerAkiraCoreDispatcherTrait};
    use kurosawa_akira::LayerAkiraExternalGrantor::{IExternalGrantorDispatcher, IExternalGrantorDispatcherTrait};
    use kurosawa_akira::LayerAkiraExecutor::{ILayerAkiraExecutorDispatcher, ILayerAkiraExecutorDispatcherTrait};


    use super::test_common_trade:: {prepare, get_maker_taker_fees, get_swap_gas_cost,spawn_order, spawn_double_qty_order, get_zero_router_fee, zero_router,register_router};
    
    fn grant_allowances(akira:ContractAddress, trader:ContractAddress, token:ContractAddress, amount:u256) {
        start_cheat_caller_address((token), trader);
        IERC20Dispatcher{contract_address:token}.increaseAllowance(akira,amount);
        stop_cheat_caller_address((token));
    }

    // router ones
    fn get_order_router_flags(full_fill_only:bool, best_level_only:bool, post_only:bool, is_sell_side:bool, is_market_order:bool) -> OrderFlags{
        return OrderFlags{full_fill_only, best_level_only, post_only, is_sell_side, is_market_order, to_ecosystem_book: false, external_funds: is_market_order};
    }

    fn get_order_ecosystem_flags(full_fill_only:bool,best_level_only:bool,post_only:bool,is_sell_side:bool,is_market_order:bool,) -> OrderFlags{
        return OrderFlags{full_fill_only, best_level_only, post_only, is_sell_side, is_market_order, to_ecosystem_book: true, external_funds:false};
    }

    fn test_draft(sell_order_01_base_qty: u256, sell_order_01_quote_qty: u256, sell_order_02_base_qty: u256, sell_order_02_quote_qty: u256, apply_fee_to_receipt:bool) {
        let (akira, tr1, tr2, eth, usdc, eth_amount, usdc_amount) = prepare();
        let(core, _, executor) = akira;
        
        let router: ContractAddress = 5.try_into().unwrap();
        let (signer, signer_pk) = get_trader_signer_and_pk_2();
        let signer: ContractAddress = signer.try_into().unwrap();
        register_router(akira, tr1, signer, router);
        
        deposit(tr1, usdc_amount, usdc, core);
        let gas_fee = 100 * get_swap_gas_cost().into();
        
        grant_allowances(executor.contract_address, tr2, eth, gas_fee + eth_amount+10000000);

        let price = 2000_000_000; // 2000 usdc
        let base_qty = 1_000_000_000_000_000_000; // 1 eth
        
        let mut sell_order_01 = spawn_double_qty_order(akira, tr2, price, sell_order_01_base_qty, sell_order_01_quote_qty, 
                get_order_router_flags(false, false, false, true, true), 1, signer, true);
        sell_order_01.router_sign = sign(executor.get_order_hash(sell_order_01.order), signer.into(), signer_pk);
        let mut sell_order_02 = spawn_double_qty_order(akira, tr2, price, sell_order_02_base_qty, sell_order_02_quote_qty, 
                get_order_router_flags(false, false, false, true, true), 2, signer, true);
        sell_order_02.router_sign = sign(executor.get_order_hash(sell_order_02.order), signer.into(), signer_pk);


        let buy_order = spawn_order(akira, tr1, price, base_qty, 
                get_order_router_flags(false, false, true, false, false), 0, zero_router());


        let eth_erc = IERC20Dispatcher{contract_address:eth};
        let usdc_erc = IERC20Dispatcher{contract_address:usdc};
        let taker = sell_order_01.order.maker;
        let (eth_b, usdc_b, router_b) = (eth_erc.balanceOf(taker), usdc_erc.balanceOf(taker), core.balanceOf(router, usdc));

        start_cheat_caller_address(executor.contract_address, get_fee_recipient_exchange());
        assert(executor.apply_single_execution_step(sell_order_01, array![(buy_order,0)],  base_qty / 2, 100, get_swap_gas_cost(), false), 'FAILED_MATCH');
        assert(executor.apply_single_execution_step(sell_order_02, array![(buy_order,0)],  base_qty / 2, 100, get_swap_gas_cost(), false), 'FAILED_MATCH');
        stop_cheat_caller_address(executor.contract_address);
         
        assert(core.balanceOf(sell_order_01.order.maker, eth) == 0, 'WRONG_ROUTER_T_BALANCE_ETH');
        assert(core.balanceOf(sell_order_01.order.maker, usdc) == 0, 'WRONG_ROUTER_T_BALANCE_USDC');
        let router_fee = get_feeable_qty(sell_order_01.order.fee.router_fee, price / 2, false) + get_feeable_qty(sell_order_02.order.fee.router_fee, price / 2, false);
        assert!(core.balanceOf(router, usdc) - router_b == router_fee, "WRONG_ROUTER_RECEIVED {} {}", core.balanceOf(router, usdc) - router_b, router_fee);

        let maker_fee = get_feeable_qty(buy_order.order.fee.trade_fee, base_qty, true);
        assert(core.balanceOf(buy_order.order.maker, eth) == base_qty  - maker_fee, 'WRONG_MATCH_RECIEVE_ETH');
        assert(core.balanceOf(buy_order.order.maker, usdc) == 0, 'WRONG_SEND_USDC');


        start_cheat_caller_address(executor.contract_address, router);
        // akira.router_withdraw(usdc, router_fee, router);
        assert!(core.balanceOf(router, usdc) == router_fee, "WRONG_ROUTER_WITHDRAW: {}, {}", core.balanceOf(router, usdc),router_fee);
        stop_cheat_caller_address(executor.contract_address);
    }  


    #[test]
    #[fork("block_based")]
    fn test_quote_qty_only_base() {
        let base_qty = 1_000_000_000_000_000_000;
        let quote_qty = 2000_000_000;
        test_draft(base_qty / 2, 0, base_qty / 2, 0, true);
    }  

        #[test]
    #[fork("block_based")]
    fn test_quote_qty_only_quote() {
        let base_qty = 1_000_000_000_000_000_000;
        let quote_qty = 2000_000_000;
        test_draft(0, quote_qty / 2, 0, quote_qty / 2, true);
    }  

            #[test]
    #[fork("block_based")]
    fn test_quote_qty_both() {
        let base_qty = 1_000_000_000_000_000_000;
        let quote_qty = 2000_000_000;
        test_draft(0, quote_qty / 2, base_qty / 2, 0, true);
    }  

    #[test]
    #[fork("block_based")]
    fn test_quote_qty_both_02() {
        let base_qty = 1_000_000_000_000_000_000;
        let quote_qty = 2000_000_000;
        test_draft(base_qty / 2, 0, 0, quote_qty / 2, true);
    }  
}

