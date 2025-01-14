use starknet::{ContractAddress};
use kurosawa_akira::WithdrawComponent::{SignedWithdraw, Withdraw,SlowModeDelay};
use kurosawa_akira::NonceComponent::{SignedIncreaseNonce, IncreaseNonce};
    
    
#[starknet::interface]
trait ILayerAkiraCore<TContractState> {

    fn total_supply(self: @TContractState, token: ContractAddress) -> u256;
    fn balanceOf(self: @TContractState, address: ContractAddress, token: ContractAddress) -> u256;
    fn balancesOf(self: @TContractState, addresses: Span<ContractAddress>, tokens: Span<ContractAddress>) -> Array<Array<u256>>;
    fn get_wrapped_native_token(self: @TContractState) -> ContractAddress;
    fn get_fee_recipient(self: @TContractState) -> ContractAddress;
    fn get_owner(self: @TContractState) -> ContractAddress;
    



    fn set_executor(ref self: TContractState, new_executor:ContractAddress);
    fn grant_access_to_executor(ref self: TContractState);

    fn deposit(ref self: TContractState, receiver:ContractAddress, token:ContractAddress, amount:u256);

    fn get_pending_withdraw(self:@TContractState, maker:ContractAddress,token:ContractAddress)->(SlowModeDelay,Withdraw);
    fn request_onchain_withdraw(ref self: TContractState, withdraw: Withdraw);
    // can only be performed by the owner
    fn apply_onchain_withdraw(ref self: TContractState, token:ContractAddress, key:felt252);


    fn bind_to_signer(ref self: TContractState, signer: ContractAddress);

    
    fn is_approved_executor(self: @TContractState, user: ContractAddress) -> bool;
    fn get_withdraw_hash(self: @TContractState, withdraw: Withdraw) -> felt252;
    fn get_increase_nonce_hash(self: @TContractState, increase_nonce: IncreaseNonce) -> felt252;
    fn get_nonce(self: @TContractState, user:ContractAddress) -> u32;
    fn transfer(ref self: TContractState, from: ContractAddress, to: ContractAddress, amount: u256, token: ContractAddress);
    fn safe_mint(ref self: TContractState, to: ContractAddress, amount: u256, token: ContractAddress); // invoke after we erc.transfer(), positive delta
    fn safe_burn(ref self: TContractState, to: ContractAddress, amount: u256, token: ContractAddress) -> u256; // invoke
    fn rebalance_after_trade(ref self: TContractState, maker:ContractAddress, taker:ContractAddress, ticker:(ContractAddress, ContractAddress),
            amount_base:u256, amount_quote:u256, is_maker_seller:bool);

    fn apply_increase_nonce(ref self: TContractState, signed_nonce: SignedIncreaseNonce, gas_price: u256, cur_gas_per_action: u32);
    fn apply_increase_nonces(ref self: TContractState, signed_nonces: Array<SignedIncreaseNonce>, gas_price: u256, cur_gas_per_action: u32);
    fn apply_withdraw(ref self: TContractState, signed_withdraw: SignedWithdraw, gas_price: u256, cur_gas_per_action: u32);
    fn apply_withdraws(ref self: TContractState, signed_withdraws: Array<SignedWithdraw>, gas_price: u256, cur_gas_per_action: u32);
    
    fn check_sign(self: @TContractState, trader: ContractAddress, message: felt252, signature: Span<felt252>, sign_scheme:felt252) -> bool;
    fn get_signer(self: @TContractState, trader: ContractAddress);
}




#[starknet::contract]
mod LayerAkiraCore {
    use kurosawa_akira::ExchangeBalanceComponent::exchange_balance_logic_component as  exchange_balance_logic_component;
    use kurosawa_akira::SignerComponent::signer_logic_component as  signer_logic_component;
    use kurosawa_akira::DepositComponent::deposit_component as  deposit_component;
    use kurosawa_akira::WithdrawComponent::withdraw_component as withdraw_component;
    use kurosawa_akira::NonceComponent::nonce_component as nonce_component;
    use kurosawa_akira::AccessorComponent::accessor_logic_component as  accessor_logic_component;
    
    
    use signer_logic_component::InternalSignableImpl;
    use exchange_balance_logic_component::InternalExchangeBalanceble;
    use accessor_logic_component::InternalAccesorable;
    use withdraw_component::InternalWithdrawable;
    use nonce_component::InternalNonceable;
    use deposit_component::InternalDepositable;
    
    use kurosawa_akira::utils::SlowModeLogic::SlowModeDelay;
    use kurosawa_akira::WithdrawComponent::{SignedWithdraw, Withdraw};
    use kurosawa_akira::NonceComponent::{SignedIncreaseNonce, IncreaseNonce};
    use kurosawa_akira::signature::V0OffchainMessage::{OffchainMessageHashImpl};
    use kurosawa_akira::signature::AkiraV0OffchainMessage::{OrderHashImpl,SNIP12MetadataImpl,IncreaseNonceHashImpl,WithdrawHashImpl};
    use starknet::{ContractAddress, get_caller_address};
    
    
    component!(path: exchange_balance_logic_component,storage: balancer_s, event:BalancerEvent);
    component!(path: signer_logic_component,storage: signer_s, event:SignerEvent);
    component!(path: deposit_component,storage: deposit_s, event:DepositEvent);
    component!(path: withdraw_component,storage: withdraw_s, event:WithdrawEvent);    
    component!(path: nonce_component, storage: nonce_s, event:NonceEvent);
    component!(path: accessor_logic_component, storage: accessor_s, event:AccessorEvent);
    
    

    #[abi(embed_v0)]
    impl ExchangeBalancebleImpl = exchange_balance_logic_component::ExchangeBalanceble<ContractState>;
    #[abi(embed_v0)]
    impl DepositableImpl = deposit_component::Depositable<ContractState>;
    #[abi(embed_v0)]
    impl SignableImpl = signer_logic_component::Signable<ContractState>;
    #[abi(embed_v0)]
    impl WithdrawableImpl = withdraw_component::Withdrawable<ContractState>;
    #[abi(embed_v0)]
    impl NonceableImpl = nonce_component::Nonceable<ContractState>;
    #[abi(embed_v0)]
    impl AccsesorableImpl = accessor_logic_component::Accesorable<ContractState>;
    
    

    #[storage]
    struct Storage {
        #[substorage(v0)]
        balancer_s: exchange_balance_logic_component::Storage,
        #[substorage(v0)]
        deposit_s: deposit_component::Storage,
        #[substorage(v0)]
        signer_s: signer_logic_component::Storage,
        #[substorage(v0)]
        withdraw_s: withdraw_component::Storage,
        #[substorage(v0)]
        nonce_s: nonce_component::Storage,
        #[substorage(v0)]
        accessor_s: accessor_logic_component::Storage,
        
        
        max_slow_mode_delay:SlowModeDelay, // upper bound for all delayed actions
    }


    #[constructor]
    fn constructor(ref self: ContractState,
                wrapped_native_token:ContractAddress,
                fee_recipient:ContractAddress,
                max_slow_mode_delay:SlowModeDelay, 
                withdraw_action_cost:u32, // propably u16
                owner:ContractAddress) {
        self.max_slow_mode_delay.write(max_slow_mode_delay);

        self.balancer_s.initializer(fee_recipient, wrapped_native_token);
        self.withdraw_s.initializer(max_slow_mode_delay, withdraw_action_cost);
        self.accessor_s.owner.write(owner);
        self.accessor_s.executor.write(0.try_into().unwrap());
        self.accessor_s.executor_epoch.write(0);
    }

    
    #[external(v0)]
    fn get_withdraw_delay_params(self: @ContractState)->SlowModeDelay { self.withdraw_s.delay.read()}

    #[external(v0)]
    fn get_max_delay_params(self: @ContractState)->SlowModeDelay { self.max_slow_mode_delay.read()}

    #[external(v0)]
    fn get_withdraw_hash(self: @ContractState, withdraw: Withdraw) -> felt252 { withdraw.get_message_hash(withdraw.maker)}
    
    #[external(v0)]
    fn get_increase_nonce_hash(self: @ContractState, increase_nonce:IncreaseNonce) -> felt252 { increase_nonce.get_message_hash(increase_nonce.maker)}
    

    #[external(v0)]
    fn add_signer_scheme(ref self: ContractState, verifier_address:ContractAddress) {
        // Add new signer scheme that user can use to authorize actions on behalf of his account
        self.accessor_s.only_owner();
        self.signer_s.add_signer_scheme(verifier_address);
    }


    #[external(v0)]
    fn transfer(ref self: ContractState, from: ContractAddress, to: ContractAddress, amount: u256, token: ContractAddress) {
        self.accessor_s.only_executor(); self.accessor_s.only_authorized_by_user(from);        
        self.balancer_s.internal_transfer(from, to, amount, token);
    }
    
    #[external(v0)]
    fn safe_mint(ref self: ContractState, to: ContractAddress, amount: u256, token: ContractAddress) {
         self.accessor_s.only_owner_or_executor();
         self.deposit_s.nonatomic_deposit(to, token, amount);
    }

    #[external(v0)]
    fn safe_burn(ref self: ContractState, to: ContractAddress, amount: u256, token: ContractAddress) -> u256 {
        self.accessor_s.only_owner_or_executor(); self.accessor_s.only_authorized_by_user(to); 
        return self.withdraw_s.safe_withdraw(to, amount, token);
    }

    #[external(v0)]
    fn rebalance_after_trade(ref self: ContractState, maker:ContractAddress, taker:ContractAddress, ticker:(ContractAddress, ContractAddress),
            amount_base:u256, amount_quote:u256, is_maker_seller:bool) {
        self.accessor_s.only_executor(); self.accessor_s.only_authorized_by_user(maker); self.accessor_s.only_authorized_by_user(taker);
        self.balancer_s.rebalance_after_trade(maker,taker,ticker,amount_base,amount_quote, is_maker_seller);          
    }
 
    #[external(v0)]
    fn update_withdraw_component_params(ref self: ContractState, new_delay:SlowModeDelay) {
        self.accessor_s.only_owner();
        let max = self.max_slow_mode_delay.read();
        assert!(new_delay.block <= max.block && new_delay.ts <= max.ts, "Failed withdraw params update: new_delay <= max_slow_mode_delay");
        self.withdraw_s.delay.write(new_delay);
        self.emit(WithdrawComponentUpdate{new_delay});
    }

    #[external(v0)]
    fn update_fee_recipient(ref self: ContractState, new_fee_recipient: ContractAddress) {
        self.accessor_s.only_owner();
        assert!(new_fee_recipient != 0.try_into().unwrap(), "NEW_FEE_RECIPIENT_CANT_BE_ZERO");        
        self.balancer_s.fee_recipient.write(new_fee_recipient);
        self.emit(FeeRecipientUpdate{new_fee_recipient});
    }

    #[external(v0)]
    fn update_base_token(ref self: ContractState, new_base_token:ContractAddress) {
        self.accessor_s.only_owner();
        self.balancer_s.wrapped_native_token.write(new_base_token);
        self.emit(BaseTokenUpdate{new_base_token});
        // important to reset, to avoid any malicious actions; relevant to Executor contaract; 
        //not relevant for router since it has no funds of other tokens than base one
        let (executor, _) = self.get_executor();
        self.set_executor(executor);
    }

    #[external(v0)]
    fn apply_increase_nonce(ref self: ContractState, signed_nonce: SignedIncreaseNonce, gas_price:u256, cur_gas_per_action:u32) {
        self.accessor_s.only_executor();
        self.accessor_s.only_authorized_by_user(signed_nonce.increase_nonce.maker);
        self.nonce_s.apply_increase_nonce(signed_nonce, gas_price, cur_gas_per_action);
    }


    #[external(v0)]
    fn apply_increase_nonces(ref self: ContractState, mut signed_nonces: Array<SignedIncreaseNonce>, gas_price:u256, cur_gas_per_action:u32) {
        self.accessor_s.only_executor();
        loop {
            match signed_nonces.pop_front(){
                Option::Some(signed_nonce) => { 
                    self.accessor_s.only_authorized_by_user(signed_nonce.increase_nonce.maker);
                    self.nonce_s.apply_increase_nonce(signed_nonce, gas_price, cur_gas_per_action);
                    },
                Option::None(_) => {break;}
            };
        };
    }

    #[external(v0)]
    fn apply_withdraw(ref self: ContractState, signed_withdraw: SignedWithdraw, gas_price:u256, cur_gas_per_action:u32) {
        self.accessor_s.only_executor();
        self.accessor_s.only_authorized_by_user(signed_withdraw.withdraw.maker);
        self.withdraw_s.apply_withdraw(signed_withdraw, gas_price, cur_gas_per_action);
        self.withdraw_s.gas_steps.write(cur_gas_per_action);
    }

    #[external(v0)]
    fn apply_withdraws(ref self: ContractState, mut signed_withdraws: Array<SignedWithdraw>, gas_price:u256, cur_gas_per_action:u32) {
        self.accessor_s.only_executor();
        loop {
            match signed_withdraws.pop_front(){
                Option::Some(signed_withdraw) => {
                    self.accessor_s.only_authorized_by_user(signed_withdraw.withdraw.maker);
                    self.withdraw_s.apply_withdraw(signed_withdraw, gas_price, cur_gas_per_action)
                },
                Option::None(_) => {break;}
            };
        };
        self.withdraw_s.gas_steps.write(cur_gas_per_action);
    }


    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        BalancerEvent: exchange_balance_logic_component::Event,
        DepositEvent: deposit_component::Event,
        SignerEvent: signer_logic_component::Event,
        WithdrawEvent: withdraw_component::Event,
        AccessorEvent: accessor_logic_component::Event,
        NonceEvent: nonce_component::Event,
        BaseTokenUpdate: BaseTokenUpdate,
        FeeRecipientUpdate: FeeRecipientUpdate,
        WithdrawComponentUpdate: WithdrawComponentUpdate,
    }

    #[derive(Drop, starknet::Event)]
    struct BaseTokenUpdate {new_base_token: ContractAddress}
    #[derive(Drop, starknet::Event)]
    struct FeeRecipientUpdate {new_fee_recipient: ContractAddress}
    
    #[derive(Drop, starknet::Event)]
    struct WithdrawComponentUpdate {new_delay:SlowModeDelay}

}

