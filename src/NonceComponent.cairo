use kurosawa_akira::Order::{GasFee, get_gas_fee_and_coin};
use starknet::ContractAddress;


use kurosawa_akira::signature::V0OffchainMessage::{OffchainMessageHashImpl};
use kurosawa_akira::signature::AkiraV0OffchainMessage::{IncreaseNonceHashImpl, SNIP12MetadataImpl};


#[derive(Copy, Drop, Serde, PartialEq, Hash)]
struct IncreaseNonce {
    maker: ContractAddress,
    new_nonce: u32,
    gas_fee: GasFee,
    salt: felt252,
    sign_scheme:felt252
}


#[derive(Copy, Drop, Serde)]
struct SignedIncreaseNonce {
    increase_nonce: IncreaseNonce,
    sign: Span<felt252>,
}

#[starknet::interface]
trait INonceLogic<TContractState> {
    fn get_nonce(self: @TContractState, maker: ContractAddress) -> u32;
    fn get_nonces(self: @TContractState, makers: Span<ContractAddress>)-> Array<u32>;
}



#[starknet::component]
mod nonce_component {
    use kurosawa_akira::signature::IOffchainMessage::IOffchainMessageHash;
    use kurosawa_akira::ExchangeBalanceComponent::INewExchangeBalance;
    use kurosawa_akira::ExchangeBalanceComponent::exchange_balance_logic_component as balance_component;
    use balance_component::{InternalExchangeBalancebleImpl,ExchangeBalancebleImpl};
    use super::{GasFee,ContractAddress};
    use kurosawa_akira::SignerComponent::{ISignerLogic};
    
    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        NonceIncrease: NonceIncrease,
    }

    #[derive(Drop, starknet::Event)]
    struct NonceIncrease {
        #[key]
        maker: ContractAddress,
        new_nonce: u32,
    }

    #[storage]
    struct Storage {
        nonces: starknet::storage::Map::<ContractAddress, u32>, // user address to his trading nonce
    }

    #[embeddable_as(Nonceable)]
    impl NonceableImpl<TContractState, +HasComponent<TContractState>,
    +balance_component::HasComponent<TContractState>,+Drop<TContractState>,+ISignerLogic<TContractState>> of super::INonceLogic<ComponentState<TContractState>> {

        
        fn get_nonce(self: @ComponentState<TContractState>, maker: ContractAddress) -> u32 { self.nonces.read(maker)}

        fn get_nonces(self: @ComponentState<TContractState>, makers: Span<ContractAddress>) -> Array<u32> {
            //Note makers should not be zero
            let mut res: Array<u32> = ArrayTrait::new();
            let mut idx = 0;
            let sz = makers.len(); 
            loop {
                let item = *makers.at(idx);
                res.append(self.nonces.read(item));
                idx += 1;
                if idx == sz { break;}
            };
            return res;
        }
    }

     #[generate_trait]
    impl InternalWithdrawableImpl<TContractState, +HasComponent<TContractState>,
    impl Balance:balance_component::HasComponent<TContractState>,+Drop<TContractState>,+ISignerLogic<TContractState>> of InternalNonceable<TContractState> {
        fn apply_increase_nonce(ref self: ComponentState<TContractState>, signed_nonce_increase: super::SignedIncreaseNonce, gas_price:u256, cur_gas_per_action:u32) {
            let nonce_increase = signed_nonce_increase.increase_nonce;
            let key = nonce_increase.get_message_hash(nonce_increase.maker);
            assert!(self.get_contract().check_sign(nonce_increase.maker, key, signed_nonce_increase.sign, nonce_increase.sign_scheme), "Failed maker signature check (key, r, s) = ({})", key);
            assert!(nonce_increase.new_nonce > self.nonces.read(nonce_increase.maker), "Wrong nonce (Failed new_nonce ({}) > prev_nonce ({}))", nonce_increase.new_nonce, self.nonces.read(nonce_increase.maker));
            
            let mut balancer = get_dep_component_mut!(ref self, Balance);
            let (gas_fee_amount, coin) = super::get_gas_fee_and_coin(nonce_increase.gas_fee, gas_price, balancer.get_wrapped_native_token(), cur_gas_per_action, 1);
            balancer.internal_transfer(nonce_increase.maker, balancer.get_fee_recipient(), gas_fee_amount, coin);
            
            self.nonces.write(nonce_increase.maker, nonce_increase.new_nonce);

            self.emit(NonceIncrease{ maker: nonce_increase.maker, new_nonce:nonce_increase.new_nonce});
        }
    }
}