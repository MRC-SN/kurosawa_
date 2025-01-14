use starknet::ContractAddress;
use kurosawa_akira::FundsTraits::{check_sign};
    

#[starknet::interface]
trait ISignerLogic<TContractState> {
    // Binds caller contract address (trading account) to signer.
    // Signer is responsible for generating signature on behalf of caller address
    fn bind_to_signer(ref self: TContractState, signer: ContractAddress);
    
    // set expiration time
    fn set_till_time_approved_scheme(ref self: TContractState, sign_scheme:felt252, expire_at:u32);
    // return expiration time for approval
    fn get_till_time_approved_scheme(self: @TContractState, client:ContractAddress, sign_scheme:felt252) -> u32;

    // Validates that trader's  signer is correct signer of the message
    fn check_sign(self: @TContractState, trader: ContractAddress, message: felt252, signature: Span<felt252>, sign_scheme:felt252) -> bool;
    //  returns zero address in case of no binding
    fn get_signer(self: @TContractState, trader: ContractAddress) -> ContractAddress;
    //  returns zero address in case of no binding
    fn get_signers(self: @TContractState, traders: Span<ContractAddress>) -> Array<ContractAddress>;
    // get address of verifier for sign_scheme
    fn get_verifier_address(self: @TContractState, sign_scheme:felt252) -> ContractAddress;
    

    // TODO: later support rebinding 
}

#[starknet::interface]
trait SignatureVerifier<TContractState> {
    fn verify(self: @TContractState, signer: ContractAddress, message: felt252,  signature: Span<felt252>, account: ContractAddress,)->bool;
    fn alias(self: @TContractState)->felt252;
}



#[starknet::component]
mod signer_logic_component {
    use super::SignatureVerifierDispatcherTrait;
    use starknet::{ContractAddress, get_caller_address, get_block_timestamp};
    use ecdsa::check_ecdsa_signature;
    use super::ISignerLogic;
    use kurosawa_akira::utils::common::DisplayContractAddress;


    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        NewBinding: NewBinding,
        NewSignScheme: NewSignScheme,
        ApprovalSignScheme: ApprovalSignScheme
    }

    #[derive(Drop, starknet::Event)]
    struct NewBinding {
        #[key]
        trading_account: ContractAddress,
        #[key]
        signer: ContractAddress,
    }
    #[derive(Drop, starknet::Event)]
    struct NewSignScheme {
        verifier_address: ContractAddress,
        sign_scheme: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct ApprovalSignScheme {
        #[key]
        trading_account: ContractAddress,
        #[key]
        sign_scheme: felt252,
        expire_at:u32
    }



    #[storage]
    struct Storage {
        trader_to_signer: starknet::storage::Map::<ContractAddress, ContractAddress>,
        signer_scheme_to_verifier: starknet::storage::Map::<felt252, ContractAddress>,
        client_to_scheme_to_expiration_time: starknet::storage::Map::<(ContractAddress,felt252), u32>
    }

    #[embeddable_as(Signable)]
    impl SignableImpl<
        TContractState, +HasComponent<TContractState>
    > of ISignerLogic<ComponentState<TContractState>> {
        fn bind_to_signer(ref self: ComponentState<TContractState>, signer: ContractAddress) {
            let caller = get_caller_address();
            assert!(self.trader_to_signer.read(caller) == 0.try_into().unwrap(), "ALREADY BINDED: signer = {}", self.trader_to_signer.read(caller));
            assert!(signer != 0.try_into().unwrap(), "SIGNER_CANT_BE_SET_TO_ZERO");
            
            self.trader_to_signer.write(caller, signer);
            self.emit(NewBinding { trading_account: caller, signer: signer });
        }

        fn set_till_time_approved_scheme(ref self: ComponentState<TContractState>, sign_scheme:felt252, expire_at:u32) {
            self.use_no_default_scheme(sign_scheme); self.use_defined_scheme(sign_scheme);
            let (current_expire_at, block_timestamp) = (self.client_to_scheme_to_expiration_time.read((get_caller_address(), sign_scheme)),get_block_timestamp());
            assert(current_expire_at < expire_at, 'NEW EXPIRE MUST BE HIGHER'); assert(expire_at.into() > block_timestamp, 'ALREADY EXPIRED');
            self.client_to_scheme_to_expiration_time.write((get_caller_address(), sign_scheme), expire_at);
            self.emit(ApprovalSignScheme{trading_account:get_caller_address(),sign_scheme,expire_at});
        }
        
        fn get_till_time_approved_scheme(self: @ComponentState<TContractState>, client:ContractAddress, sign_scheme:felt252) -> u32 {
            return self.client_to_scheme_to_expiration_time.read((client, sign_scheme));
        }


        fn get_signer(self: @ComponentState<TContractState>, trader: ContractAddress) -> ContractAddress {
            return self.trader_to_signer.read(trader);
        }

        fn get_signers(self: @ComponentState<TContractState>, traders: Span<ContractAddress>) -> Array<ContractAddress> {
            //Note traders should not be empty
            let mut res: Array<ContractAddress> = ArrayTrait::new();
            let sz = traders.len();
            let mut idx = 0;
            loop {
                let trader = *traders.at(idx);
                res.append(self.trader_to_signer.read(trader));
                idx += 1;
                if (idx == sz) {
                    break;
                }
            };
            return res;
        }
        fn get_verifier_address(self: @ComponentState<TContractState>, sign_scheme:felt252) -> ContractAddress {
            self.signer_scheme_to_verifier.read(sign_scheme)}

        fn check_sign(self: @ComponentState<TContractState>, trader: ContractAddress, message: felt252, signature: Span<felt252>, 
            sign_scheme:felt252) -> bool {
            let signer: ContractAddress = self.trader_to_signer.read(trader);
            if (sign_scheme == 'ecdsa curve') {
                assert(signature.len() == 2,'WRONG SIGN SIZE SIMPLE');
                let (sig_r, sig_s) = (signature.at(0).deref(), signature.at(1).deref());
                assert!(signer != 0.try_into().unwrap(), "UNDEFINED_SIGNER: no signer for this trader {}", trader);
                return check_ecdsa_signature(message, signer.into(), sig_r, sig_s);
            }
            if (sign_scheme == 'account') { return super::check_sign(trader, message, signature);}
            if (sign_scheme == 'direct') { return get_caller_address() == trader;}
            let verifier_address = self.signer_scheme_to_verifier.read(sign_scheme);
            
            self.use_defined_scheme(sign_scheme);
            assert(self.get_till_time_approved_scheme(trader, sign_scheme).into() > get_block_timestamp(), 'NOT APPROVED SCHEME');
            let dispatcher = super::SignatureVerifierDispatcher { contract_address: verifier_address };
            return dispatcher.verify(signer, message, signature, trader);
        }
    }
    #[generate_trait]
    impl InternalSignableImpl<TContractState, +HasComponent<TContractState>> of InternalSignable<TContractState> {
        fn add_signer_scheme(ref self: ComponentState<TContractState>, verifier_address:ContractAddress) {
            let dispatcher = super::SignatureVerifierDispatcher { contract_address: verifier_address };
            let sign_scheme = dispatcher.alias();
            self.use_no_default_scheme(sign_scheme);
            
            assert(self.signer_scheme_to_verifier.read(sign_scheme) == 0.try_into().unwrap(), 'ALREADY SPECIALIZED');
            self.signer_scheme_to_verifier.write(sign_scheme, verifier_address);
            self.emit(NewSignScheme{verifier_address, sign_scheme})
        }

        fn use_no_default_scheme(self: @ComponentState<TContractState>,sign_scheme:felt252) {
            assert(sign_scheme != 'account' && sign_scheme != 'ecdsa curve' && sign_scheme != 'direct', 'NO DEFAULT SCHEME');
        }
        fn use_defined_scheme(self: @ComponentState<TContractState>,sign_scheme:felt252) {
            assert(self.signer_scheme_to_verifier.read(sign_scheme) != 0.try_into().unwrap(), 'USE DEFINED SCHEME');
        }
    }
}

