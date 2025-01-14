use starknet::ContractAddress;
use serde::Serde;
use kurosawa_akira::Order::{GasFee, get_gas_fee_and_coin};
use kurosawa_akira::utils::SlowModeLogic::SlowModeDelay;

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq,Hash)]
struct Withdraw {
    #[key]
    maker: ContractAddress, // trading account that want to withdraw
    token: ContractAddress, // address of erc20 token of interest, 
    amount: u256, // amount of token, at the end user will receive amount of token diff from gas fee or amount - gas_fee, so user can always withdraw all his balances 
    salt: felt252, // random salt
    gas_fee: GasFee, // for some paths, this activity to be executed requires gasfee
    receiver: ContractAddress, // receiver of withdrawal tokens
    sign_scheme:felt252 // sign scheme
}

#[derive(Copy, Drop, Serde, PartialEq)]
struct SignedWithdraw {
    withdraw: Withdraw,
    sign: Span<felt252>
}

#[starknet::interface]
trait IWithdraw<TContractState> {
    // schedules onchain withdrawal, so user can actually withdraw by invoking apply_onchain_withdraw
    fn request_onchain_withdraw(ref self: TContractState, withdraw: Withdraw);
    // get information about current pending onchain withdrawal by (maker, token), it returns ts and block when it happened and withdrawal struct
    fn get_pending_withdraw(self:@TContractState, maker:ContractAddress, token:ContractAddress)->(SlowModeDelay,Withdraw);

    fn get_pending_withdraws(self:@TContractState,reqs:Array<(ContractAddress, ContractAddress)>)-> Array<(SlowModeDelay,Withdraw)>;
    
    // once user requested onchain withdraw and passed enouhg time user can execute apply_onchain_withdraw and therefore finalizing 2-step delayed withdrawal 
    // after request_onchain_withdraw user must wait some seconds and blocks pass
    // this is neccesary to not break trading flow other exchange participants
    fn apply_onchain_withdraw(ref self: TContractState, token:ContractAddress, key:felt252);

    // for user to build GasFee for onchain withdrawal he need withdraw_steps and gas_price (get_latest_gas())
    fn get_withdraw_steps(self: @TContractState) -> u32;

    // checks if withdraw request (w_hash is poseidon hash of Withdraw) completed or not
    fn is_request_completed(self: @TContractState, w_hash: felt252) -> bool;
    fn is_requests_completed(self: @TContractState, reqs: Array<felt252>) -> Array<bool>;
}


#[starknet::component]
mod withdraw_component {
    use core::traits::Into;
    use kurosawa_akira::ExchangeBalanceComponent::INewExchangeBalance;
    use kurosawa_akira::ExchangeBalanceComponent::exchange_balance_logic_component as balance_component;
    use balance_component::{InternalExchangeBalancebleImpl,ExchangeBalancebleImpl};
    use super::{Withdraw, SignedWithdraw, SlowModeDelay, IWithdraw, GasFee};
    use kurosawa_akira::SignerComponent::{ISignerLogic};
    use kurosawa_akira::utils::erc20::{IERC20DispatcherTrait, IERC20Dispatcher};
    use starknet::{get_caller_address, get_contract_address, get_block_timestamp, ContractAddress};
    use starknet::info::get_block_number;
    use kurosawa_akira::utils::common::DisplayContractAddress;
    use kurosawa_akira::signature::V0OffchainMessage::{OffchainMessageHashImpl};
    use kurosawa_akira::signature::AkiraV0OffchainMessage::{WithdrawHashImpl, SNIP12MetadataImpl};



    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        ReqOnChainWithdraw: ReqOnChainWithdraw,
        Withdrawal: Withdrawal
    }

    #[derive(Drop, starknet::Event)]
    struct ReqOnChainWithdraw {
        #[key]
        maker: ContractAddress,
        withdraw:Withdraw
    }

    #[derive(Drop, starknet::Event)]
    struct Withdrawal {
        #[key]
        maker: ContractAddress,
        token: ContractAddress,
        receiver: ContractAddress,
        salt: felt252,
        amount: u256,
        gas_price: u256,
        gas_fee: GasFee,
        direct: bool
    }

    #[storage]
    struct Storage {
        delay: SlowModeDelay, // set by exchange, can be updated but no more then original
        pending_reqs: starknet::storage::Map::<(ContractAddress,ContractAddress),(SlowModeDelay, Withdraw)>,
        completed_reqs: starknet::storage::Map::<felt252,bool>,
        gas_steps: u32, //set by us, during exec of rollups of withdraws, same semantic as with latest gas
    }

    #[embeddable_as(Withdrawable)]
    impl WithdrawableImpl<TContractState, +HasComponent<TContractState>,+balance_component::HasComponent<TContractState>,+Drop<TContractState>,+ISignerLogic<TContractState>> of IWithdraw<ComponentState<TContractState>> {

        fn is_request_completed(self:@ComponentState<TContractState>, w_hash:felt252) -> bool { self.completed_reqs.read(w_hash)}
        fn is_requests_completed(self:@ComponentState<TContractState>, mut reqs:Array<felt252>) -> Array<bool> {
            let mut res: Array = ArrayTrait::new();            
            loop {
                match reqs.pop_front(){ Option::Some(hash) => { res.append(self.completed_reqs.read(hash));}, Option::None(_) => {break;}};
            };
            return res;
        }


        fn get_pending_withdraw(self:@ComponentState<TContractState>,maker:ContractAddress, token:ContractAddress)->(SlowModeDelay, Withdraw) {
            return self.pending_reqs.read((token, maker));
        }

        fn get_pending_withdraws(self:@ComponentState<TContractState>, mut reqs:Array<(ContractAddress, ContractAddress)>) -> Array<(SlowModeDelay,Withdraw)> {
            //note reqs must not be empty
            let mut res: Array = ArrayTrait::new();            
            loop {
                match reqs.pop_front(){
                    Option::Some((maker,token)) => { res.append(self.pending_reqs.read((token, maker)));}, Option::None(_) => {break;}
                };
            };
            return res;
        }

        fn request_onchain_withdraw(ref self: ComponentState<TContractState>, withdraw: Withdraw) {
            // Onchain withdrawals have several constraints:
            // 1) Only maker itself can execute it
            // 2) Only one in progress onchain withdrawal per token allowed
            // 3) We require user to have GasFee with latest_gas_price * 2 for exchange be able to execute it on behalf of user once it is possible
            assert!(get_caller_address() == withdraw.maker, "WRONG_MAKER: withdraw maker ({}) should be equal caller ({})", withdraw.maker, get_caller_address());
            assert!(withdraw.amount > 0, "WITHDRAW_CANT_BE_ZERO");
            assert!(withdraw.receiver != 0.try_into().unwrap(), "RECIPIENT_CANT_BE_ZERO");
            assert!(withdraw.sign_scheme == '', "Should not be specified");
            let key = (withdraw.token, withdraw.maker);            
            let (_, w_prev): (SlowModeDelay, Withdraw)  = self.pending_reqs.read(key);
            let w_hash = withdraw.get_message_hash(withdraw.maker);

            assert!(w_prev != withdraw, "ALREADY_REQUESTED: withdraw for this token already requested");
            assert!(w_prev.amount == 0 || self.completed_reqs.read(w_prev.get_message_hash(w_prev.maker)), "NOT_YET_COMPLETED_PREV: previous withdraw has not been completed yet");
           
            assert!(!self.completed_reqs.read(w_hash), "ALREADY_COMPLETED: requested withdraw has already been completed");
            self.validate(withdraw.maker, withdraw.token, withdraw.amount, withdraw.gas_fee);
            
            self.pending_reqs.write(key, (SlowModeDelay {block:get_block_number(), ts: get_block_timestamp()}, withdraw));
            self.emit(ReqOnChainWithdraw{maker:withdraw.maker, withdraw});
        }

        fn get_withdraw_steps(self: @ComponentState<TContractState>) -> u32 { self.gas_steps.read().into()}


        fn apply_onchain_withdraw(ref self: ComponentState<TContractState>, token:ContractAddress, key:felt252) {
            // Here user will not be charged for gasFee because he is the actual executor
            let caller = get_caller_address();
            let (delay, w_req): (SlowModeDelay,Withdraw) = self.pending_reqs.read((token, caller));
            assert!(caller == w_req.maker, "WRONG_MAKER: withdraw maker ({}) should be equal caller ({})", w_req.maker, get_caller_address());
            assert!(key == w_req.get_message_hash(w_req.maker),"WRONG_WITHDRAW: wrong key ({}) for pending withdraw ({})", key, w_req.get_message_hash(w_req.maker));
            assert!(!self.completed_reqs.read(key), "ALREADY_COMPLETED: withdraw has been completed already");
            
            let limit:SlowModeDelay = self.delay.read();
            let (block_delta, ts_delta) = (get_block_number() - delay.block, get_block_timestamp() - delay.ts);
            assert!(block_delta >= limit.block && ts_delta >= limit.ts, "FEW_TIME_PASSED: wait at least {} block and {} ts (for now its {} and {})", delay.block, delay.ts, block_delta, ts_delta);

            self._transfer(w_req, key, w_req.amount, 0, true);
        }

    }

     #[generate_trait]
    impl InternalWithdrawableImpl<TContractState, +HasComponent<TContractState>,
    impl Balance:balance_component::HasComponent<TContractState>,+Drop<TContractState>,+ISignerLogic<TContractState>> of InternalWithdrawable<TContractState> {
        fn initializer(ref self: ComponentState<TContractState> ,delay:SlowModeDelay, gas_steps_cost:u32) {
            self.delay.write(delay);
            self.gas_steps.write(gas_steps_cost);
        }

        // Exchange can execute offchain withdrawal by makers if siganture is correct
        // or if there is ongoing pending withdrawal, exchange can process, 
        // in this case no need for signature verifaction because user already scheduled withdrawal onchain
        fn apply_withdraw(ref self: ComponentState<TContractState>, signed_withdraw: SignedWithdraw, gas_price:u256, cur_gas_per_action:u32) {
            assert!(signed_withdraw.withdraw.receiver != 0.try_into().unwrap(), "RECIPIENT_CANT_BE_ZERO");
            
            let hash = signed_withdraw.withdraw.get_message_hash(signed_withdraw.withdraw.maker);
            let (_, w_req):(SlowModeDelay, Withdraw) = self.pending_reqs.read((signed_withdraw.withdraw.token, signed_withdraw.withdraw.maker));
            assert!(!self.completed_reqs.read(hash), "ALREADY_COMPLETED: withdraw (hash = {})", hash);
            let is_onchain_withdrawal: bool = w_req == signed_withdraw.withdraw;
            if !is_onchain_withdrawal { // need to check sign cause offchain withdrawal
                let w = signed_withdraw.withdraw;
                assert!(self.get_contract().check_sign(w.maker, hash, signed_withdraw.sign, w.sign_scheme), "WRONG_SIGN: (hash) = ({})", hash);
                self.completed_reqs.write(w_req.get_message_hash(w_req.maker), true) // invalidate pending one to avoid bad user experience
            }
            let w_req = signed_withdraw.withdraw;
        
            let mut balancer = get_dep_component_mut!(ref self, Balance);

             // payment to exchange for gas
            let (gas_fee_amount, coin) = super::get_gas_fee_and_coin(w_req.gas_fee, gas_price, balancer.get_wrapped_native_token(), cur_gas_per_action, 1);
            balancer.internal_transfer(w_req.maker, balancer.get_fee_recipient(), gas_fee_amount, coin);
            
            // let gas_fee_amount = contract.validate_and_apply_gas_fee_internal(w_req.maker, w_req.gas_fee, gas_price, 1, cur_gas_per_action, contract.get_wrapped_native_token());
            
            let tfer_amount = if w_req.token == w_req.gas_fee.fee_token {w_req.amount - gas_fee_amount } else { w_req.amount};
            self._transfer(w_req, hash, tfer_amount, gas_price, is_onchain_withdrawal);
        }
        fn validate(self:@ComponentState<TContractState>, maker:ContractAddress, token:ContractAddress, amount:u256, gas_fee:GasFee) {
            // User must specify gas fee, by specifying adequate max_gas_price it will allow to exchange to finalizing withdrawal on user behalf bypassing delay
            let balancer =  get_dep_component!(self, Balance);
            let balance = balancer.balanceOf(maker, token);
            let gas_steps = self.gas_steps.read().into();
            assert!(gas_fee.gas_per_action == gas_steps, "WRONG_GAS_PER_ACTION: expected {} got {}", gas_steps, gas_fee.gas_per_action);
            assert!(gas_fee.fee_token == balancer.wrapped_native_token.read(), "WRONG_GAS_FEE_TOKEN: expected {} got {}", balancer.wrapped_native_token.read(), gas_fee.fee_token);
            let required_gas = gas_fee.max_gas_price * gas_fee.gas_per_action.into();
            assert!(balance >= amount , "FEW_BALANCE: need at least {}, but have only {}", amount, balance);
            assert!(!(gas_fee.fee_token == token) || amount >= required_gas, "GAS_MORE_THAN_REQUESTED: failed amount ({}) >= required_gas ({})", amount, required_gas);
            assert!(gas_fee.fee_token == token || balancer.balanceOf(maker, gas_fee.fee_token) >= required_gas, "FEW_BALANCE_GAS: failed maker_balance ({}) >= required_gas ({}) -- gas token {}", balancer.balanceOf(maker, gas_fee.fee_token), required_gas, gas_fee.fee_token);
        }

        fn _transfer(ref self: ComponentState<TContractState>, w_req:Withdraw, w_hash:felt252, tfer_amount:u256, gas_price:u256, direct:bool) {
            // burn tokens on exchange
            // tfer them to recipient via erc20 interface, validate that tfer was correct i.e exhancge didnt spend more then burnt
            let mut contract = get_dep_component_mut!(ref self, Balance);
            contract.burn(w_req.maker, tfer_amount, w_req.token);
            let erc20 = IERC20Dispatcher { contract_address: w_req.token };
            let balance_before = erc20.balanceOf(get_contract_address());
            
            erc20.transfer(w_req.receiver, tfer_amount);
            
            let transferred = balance_before - erc20.balanceOf(get_contract_address());
            assert!(transferred <= tfer_amount, "WRONG_TRANSFER_AMOUNT expected {} actual {}",  tfer_amount, transferred);

            self.emit(Withdrawal{maker:w_req.maker, token:w_req.token, amount: w_req.amount, salt:w_req.salt, receiver:w_req.receiver, gas_price,
                        gas_fee:w_req.gas_fee, direct:direct});
            self.completed_reqs.write(w_hash, true);    
        }

        fn safe_withdraw(ref self: ComponentState<TContractState>, to:ContractAddress, amount:u256, token:ContractAddress) -> u256 {
            let (erc20, mut contract, exchange) = (IERC20Dispatcher { contract_address: token },get_dep_component_mut!(ref self, Balance), get_contract_address());
            let balance_before = erc20.balanceOf(exchange);
            contract.burn(to, amount, token); erc20.transfer(to, amount);
            let transferred = balance_before - erc20.balanceOf(exchange);
            assert!(transferred <= amount, "WRONG_TRANSFER_AMOUNT expected {} actual {}",  amount, transferred);
            return transferred;
        }        
    }   

}
