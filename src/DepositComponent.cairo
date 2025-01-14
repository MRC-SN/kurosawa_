use starknet::ContractAddress;

#[starknet::interface]
trait IDeposit<TContractState> {
    fn deposit(ref self: TContractState, receiver:ContractAddress, token:ContractAddress, amount:u256);
    fn deposit_s(ref self: TContractState, token:ContractAddress, amount:u256);
}

#[starknet::component]
mod deposit_component {
    use kurosawa_akira::ExchangeBalanceComponent::exchange_balance_logic_component::InternalExchangeBalanceble;
    use kurosawa_akira::ExchangeBalanceComponent::exchange_balance_logic_component as balance_component;
    use balance_component::{InternalExchangeBalancebleImpl, ExchangeBalancebleImpl};
    use kurosawa_akira::utils::erc20::{IERC20DispatcherTrait, IERC20Dispatcher};
    use starknet::{get_caller_address, get_contract_address, ContractAddress};

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Deposit: Deposit,
    }

    #[derive(Drop, starknet::Event)]
    struct Deposit {
        #[key]
        receiver: ContractAddress,
        token: ContractAddress,
        funder:ContractAddress,
        amount: u256
    }


    #[storage]
    struct Storage {}

    #[embeddable_as(Depositable)]
    impl DepositableImpl<TContractState, +HasComponent<TContractState>,impl Balance: balance_component::HasComponent<TContractState>,+Drop<TContractState>,> of super::IDeposit<ComponentState<TContractState>> {

        fn deposit(ref self: ComponentState<TContractState>, receiver:ContractAddress, token:ContractAddress, amount:u256) {
            // User invokes this method and exchange will tfer amount of token to receiver
            // Note user must grant allowance to exchange to invoke transferFrom method
            let (caller, contract, mut b_contract) = (get_caller_address(), get_contract_address(), get_dep_component_mut!(ref self, Balance));
            let erc20 = IERC20Dispatcher { contract_address: token };

            let pre = erc20.balanceOf(contract);
            erc20.transferFrom(caller, contract, amount);
            let fact_received = erc20.balanceOf(contract) - pre;
            assert!(fact_received == amount, "WRONG_AMOUNT: expected {}, got {}", amount, fact_received);

            b_contract.mint(receiver, amount, token);
            self.emit(Deposit{receiver:receiver, token:token, funder:caller, amount:amount});
        }

        fn deposit_s(ref self: ComponentState<TContractState>, token:ContractAddress, amount:u256) { self.deposit(get_caller_address(), token, amount);}



    }

    #[generate_trait]
    impl InternalDepositableImpl<TContractState, +HasComponent<TContractState>,
    impl Balance:balance_component::HasComponent<TContractState>,+Drop<TContractState>> of InternalDepositable<TContractState> {
        fn nonatomic_deposit(ref self: ComponentState<TContractState>, receiver:ContractAddress, token:ContractAddress, amount:u256) {
            let (erc20, mut b_contract) = (IERC20Dispatcher { contract_address: token }, get_dep_component_mut!(ref self, Balance));
            let (before, after) = (b_contract.total_supply(token), erc20.balanceOf(get_contract_address()));
            assert!(after > before && amount <= after - before, "WRONG_AMOUNT: expected {}, got after {}, get before {}", amount, after, before);
            b_contract.mint(receiver, amount, token);
        }
    }  
}
