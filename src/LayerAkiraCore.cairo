
#[starknet::contract]
mod LayerAkiraCore {
    use kurosawa_akira::ExchangeBalanceComponent::exchange_balance_logic_component as  exchange_balance_logic_component;
    use kurosawa_akira::SignerComponent::signer_logic_component as  signer_logic_component;
    use kurosawa_akira::DepositComponent::deposit_component as  deposit_component;
    use kurosawa_akira::WithdrawComponent::withdraw_component as withdraw_component;
    use kurosawa_akira::NonceComponent::nonce_component as nonce_component;
    
    use signer_logic_component::InternalSignableImpl;
    use exchange_balance_logic_component::InternalExchangeBalanceble;
    use withdraw_component::InternalWithdrawable;
    use nonce_component::InternalNonceable;

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
        
        max_slow_mode_delay:SlowModeDelay, // upper bound for all delayed actions
        owner: ContractAddress, // owner of contact that have permissions to grant and revoke role for invokers and update slow mode 
        executor: ContractAddress,
        user_to_executor_granted: starknet::storage::Map::<ContractAddress, ContractAddress>, 
        user_to_executor_epoch: starknet::storage::Map::<ContractAddress, u16>, // prevent re grant logic for old executors
        executor_epoch:u16   
    }


    #[constructor]
    fn constructor(ref self: ContractState,
                wrapped_native_token:ContractAddress,
                fee_recipient:ContractAddress,
                max_slow_mode_delay:SlowModeDelay, 
                withdraw_action_cost:u32, // propably u16
                exchange_invoker:ContractAddress,
                min_to_route:u256, // minimum amount neccesary to start to provide 
                owner:ContractAddress) {
        self.max_slow_mode_delay.write(max_slow_mode_delay);

        self.balancer_s.initializer(fee_recipient, wrapped_native_token);
        self.withdraw_s.initializer(max_slow_mode_delay, withdraw_action_cost);
        self.owner.write(owner);
        self.executor.write(0.try_into().unwrap());
        self.executor_epoch.write(0);
    }


    #[external(v0)]
    fn get_approved_executor(self: @ContractState, user:ContractAddress) -> (ContractAddress, u16) {
        (self.user_to_executor_granted.read(user), self.user_to_executor_epoch.read(user))
    }

    #[external(v0)]
    fn get_owner(self: @ContractState) -> ContractAddress { self.owner.read()}
    
    #[external(v0)]
    fn get_executor(self: @ContractState) -> ContractAddress { self.executor.read()}
    
    #[external(v0)]
    fn get_executor_epoch(self: @ContractState) -> u16 { self.executor_epoch.read()}
    
    #[external(v0)]
    fn get_withdraw_delay_params(self: @ContractState)->SlowModeDelay { self.withdraw_s.delay.read()}

    #[external(v0)]
    fn get_max_delay_params(self: @ContractState)->SlowModeDelay { self.max_slow_mode_delay.read()}

    #[external(v0)]
    fn get_withdraw_hash(self: @ContractState, withdraw: Withdraw) -> felt252 { withdraw.get_message_hash(withdraw.maker)}
    
    #[external(v0)]
    fn get_increase_nonce_hash(self: @ContractState, increase_nonce:IncreaseNonce) -> felt252 { increase_nonce.get_message_hash(increase_nonce.maker)}



    #[external(v0)]
    fn grant_access_to_executor(ref self: ContractState) { 
        // invoked by client to whitelist current executor to perform actions on his behalf
        let (user, executor) = (get_caller_address(), self.executor.read());
        assert!(self.user_to_executor_granted.read(user) != executor, "Executor access already granted");
        self.user_to_executor_granted.write(user, executor);
        self.user_to_executor_epoch.write(user, self.executor_epoch.read());
        self.emit(ApprovalGranted{executor, user})
    }

    #[external(v0)]
    fn add_signer_scheme(ref self: ContractState, verifier_address:ContractAddress) {
        // Add new signer scheme that user can use to authorize actions on behalf of his account
        only_owner(@self);
        self.signer_s.add_signer_scheme(verifier_address);
    }

    #[external(v0)]
    fn set_owner(ref self: ContractState, new_owner:ContractAddress) {
        only_owner(@self);
        self.owner.write(new_owner);
        self.emit(OwnerChanged{new_owner});
    }

    #[external(v0)]
    fn set_executor(ref self: ContractState, new_executor:ContractAddress) {
        only_owner(@self);
        self.executor.write(new_executor);
        self.executor_epoch.write(self.executor_epoch.read() + 1);
        self.emit(ExecutorChanged{new_executor,new_epoch:self.executor_epoch.read()});
    }

    #[external(v0)]
    fn transfer(ref self: ContractState, from: ContractAddress, to: ContractAddress, amount: u256, token: ContractAddress) {
        only_executor(@self); // is redundant?
        only_authorized_by_user(@self, from);        
        self.balancer_s.internal_transfer(from, to, amount, token);
    }
            
    #[external(v0)]
    fn update_withdraw_component_params(ref self: ContractState, new_delay:SlowModeDelay) {
        only_owner(@self);
        let max = self.max_slow_mode_delay.read();
        assert!(new_delay.block <= max.block && new_delay.ts <= max.ts, "Failed withdraw params update: new_delay <= max_slow_mode_delay");
        self.withdraw_s.delay.write(new_delay);
        self.emit(WithdrawComponentUpdate{new_delay});
    }

    #[external(v0)]
    fn update_fee_recipient(ref self: ContractState, new_fee_recipient: ContractAddress) {
        only_owner(@self);
        assert!(new_fee_recipient != 0.try_into().unwrap(), "NEW_FEE_RECIPIENT_CANT_BE_ZERO");        
        self.balancer_s.fee_recipient.write(new_fee_recipient);
        self.emit(FeeRecipientUpdate{new_fee_recipient});
    }

    #[external(v0)]
    fn update_base_token(ref self: ContractState, new_base_token:ContractAddress) {
        only_owner(@self);
        self.balancer_s.wrapped_native_token.write(new_base_token);
        self.emit(BaseTokenUpdate{new_base_token});
    }



    #[external(v0)]
    fn apply_increase_nonce(ref self: ContractState, signed_nonce: SignedIncreaseNonce, gas_price:u256, cur_gas_per_action:u32) {
        only_executor(@self);
        only_authorized_by_user(@self, signed_nonce.increase_nonce.maker);
        self.nonce_s.apply_increase_nonce(signed_nonce, gas_price, cur_gas_per_action);
    }


    #[external(v0)]
    fn apply_increase_nonces(ref self: ContractState, mut signed_nonces: Array<SignedIncreaseNonce>, gas_price:u256, cur_gas_per_action:u32) {
        only_executor(@self);
        loop {
            match signed_nonces.pop_front(){
                Option::Some(signed_nonce) => { 
                    only_authorized_by_user(@self, signed_nonce.increase_nonce.maker);
                    self.nonce_s.apply_increase_nonce(signed_nonce, gas_price, cur_gas_per_action);
                    },
                Option::None(_) => {break;}
            };
        };
    }

    #[external(v0)]
    fn apply_withdraw(ref self: ContractState, signed_withdraw: SignedWithdraw, gas_price:u256, cur_gas_per_action:u32) {
        only_owner(@self);
        only_authorized_by_user(@self,signed_withdraw.withdraw.maker);
        self.withdraw_s.apply_withdraw(signed_withdraw, gas_price, cur_gas_per_action);
        self.withdraw_s.gas_steps.write(cur_gas_per_action);
    }

    #[external(v0)]
    fn apply_withdraws(ref self: ContractState, mut signed_withdraws: Array<SignedWithdraw>, gas_price:u256, cur_gas_per_action:u32) {
        only_owner(@self);
        loop {
            match signed_withdraws.pop_front(){
                Option::Some(signed_withdraw) => {
                    only_authorized_by_user(@self,signed_withdraw.withdraw.maker);
                    self.withdraw_s.apply_withdraw(signed_withdraw, gas_price, cur_gas_per_action)
                },
                Option::None(_) => {break;}
            };
        };
        self.withdraw_s.gas_steps.write(cur_gas_per_action);
    }


    fn only_authorized_by_user(self: @ContractState, user:ContractAddress) {
        let (current_executor, current_epoch) = (self.executor.read(), self.executor_epoch.read());
        let (approved, user_epoch) = (self.user_to_executor_granted.read(user), self.user_to_executor_epoch.read(user));      
        assert(approved == current_executor && user_epoch == current_epoch, 'Access denied: not granted');
    }
    fn only_owner(self: @ContractState) { assert!(self.owner.read() == get_caller_address(), "Access denied: set_executor is only for the owner's use");}
    fn only_executor(self: @ContractState) { assert(self.executor.read() == get_caller_address(), 'Access denied: only executor');}


    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        BalancerEvent: exchange_balance_logic_component::Event,
        DepositEvent: deposit_component::Event,
        SignerEvent: signer_logic_component::Event,
        WithdrawEvent: withdraw_component::Event,
        NonceEvent: nonce_component::Event,
        BaseTokenUpdate: BaseTokenUpdate,
        FeeRecipientUpdate: FeeRecipientUpdate,
        WithdrawComponentUpdate: WithdrawComponentUpdate,
        OwnerChanged: OwnerChanged,
        ExecutorChanged: ExecutorChanged,
        ApprovalGranted:ApprovalGranted
    }

    #[derive(Drop, starknet::Event)]
    struct BaseTokenUpdate {new_base_token: ContractAddress}
    #[derive(Drop, starknet::Event)]
    struct FeeRecipientUpdate {new_fee_recipient: ContractAddress}
    
    #[derive(Drop, starknet::Event)]
    struct WithdrawComponentUpdate {new_delay:SlowModeDelay}
    
    #[derive(Drop, starknet::Event)]
    struct OwnerChanged {new_owner:ContractAddress}
    #[derive(Drop, starknet::Event)]
    struct ExecutorChanged {new_executor:ContractAddress, new_epoch:u16}
    #[derive(Drop, starknet::Event)]
    struct ApprovalGranted {user:ContractAddress, #[key] executor:ContractAddress}

}