use starknet::ContractAddress;

#[starknet::interface]
trait IAccesorableImpl<TContractState> {
        fn get_approved_executor(self: @TContractState, user:ContractAddress) -> (ContractAddress, u16);

        fn is_approved_executor(self: @TContractState, user:ContractAddress) -> bool;

        fn get_owner(self: @TContractState) -> ContractAddress;
    
        fn get_executor(self: @TContractState) -> (ContractAddress, u16);
    
        fn set_owner(ref self: TContractState, new_owner:ContractAddress);

        fn set_executor(ref self: TContractState, new_executor:ContractAddress);
        fn grant_access_to_executor(ref self: TContractState);
}



#[starknet::component]
mod accessor_logic_component {
    use starknet::{ContractAddress, get_caller_address};
    use super::{IAccesorableImpl};


    #[storage]
    struct Storage {
        owner: ContractAddress, // owner of contact that have permissions to grant and revoke role for invokers and update slow mode 
        executor: ContractAddress,
        user_to_executor_granted: starknet::storage::Map::<ContractAddress, ContractAddress>, 
        user_to_executor_epoch: starknet::storage::Map::<ContractAddress, u16>, // prevent re grant logic for old executors
        executor_epoch:u16   
    }


    #[embeddable_as(Accesorable)]
    impl AccsesorableImpl<TContractState, +HasComponent<TContractState>> of IAccesorableImpl<ComponentState<TContractState>> {
        
        fn get_approved_executor(self: @ComponentState<TContractState>, user:ContractAddress) -> (ContractAddress, u16) {
            (self.user_to_executor_granted.read(user), self.user_to_executor_epoch.read(user))
        }

        fn is_approved_executor(self: @ComponentState<TContractState>, user:ContractAddress) -> bool {
            let (current_executor, current_epoch) = (self.executor.read(), self.executor_epoch.read());
            let (approved, user_epoch) = (self.user_to_executor_granted.read(user), self.user_to_executor_epoch.read(user));      
            return (current_executor == approved && current_epoch == user_epoch);
        }

        fn get_owner(self: @ComponentState<TContractState>) -> ContractAddress { self.owner.read()}
    
        fn get_executor(self: @ComponentState<TContractState>) -> (ContractAddress, u16) { (self.executor.read(), self.executor_epoch.read())}
    
        fn set_owner(ref self: ComponentState<TContractState>, new_owner:ContractAddress) {
            self.only_owner();
            self.owner.write(new_owner);
            self.emit(OwnerChanged{new_owner});
        }

        fn set_executor(ref self: ComponentState<TContractState>, new_executor:ContractAddress) {
            self.only_owner();
            self.executor.write(new_executor);
            self.executor_epoch.write(self.executor_epoch.read() + 1);
            self.emit(ExecutorChanged{new_executor,new_epoch:self.executor_epoch.read()});
        }
        fn grant_access_to_executor(ref self: ComponentState<TContractState>) { 
            // invoked by client to whitelist current executor to perform actions on his behalf
            let (user, executor) = (get_caller_address(), self.executor.read());
            assert!(self.user_to_executor_granted.read(user) != executor, "Executor access already granted");
            self.user_to_executor_granted.write(user, executor);
            self.user_to_executor_epoch.write(user, self.executor_epoch.read());
            self.emit(ApprovalGranted{executor, user, epoch:self.executor_epoch.read() })
        }
    }

    
    #[generate_trait]
    impl InternalAccesorableImpl<TContractState, +HasComponent<TContractState>> of InternalAccesorable<TContractState> {
        
        fn only_authorized_by_user(self: @ComponentState<TContractState>, user:ContractAddress) {
            let (current_executor, current_epoch) = (self.executor.read(), self.executor_epoch.read());
            let (approved, user_epoch) = (self.user_to_executor_granted.read(user), self.user_to_executor_epoch.read(user));      
            assert(approved == current_executor && user_epoch == current_epoch, 'Access denied: not granted');
        }
        fn only_owner(self: @ComponentState<TContractState>) { assert!(self.owner.read() == get_caller_address(), "Access denied: only for the owner's use");}
        fn only_executor(self: @ComponentState<TContractState>) { assert(self.executor.read() == get_caller_address(), 'Access denied: only executor');}
        fn only_owner_or_executor(self: @ComponentState<TContractState>) {
             assert!(self.owner.read() == get_caller_address() || self.executor.read() == get_caller_address(), "Access denied: only for the owner's or executor's use");}
        
    }



    #[derive(Drop, starknet::Event)]
    struct OwnerChanged {new_owner:ContractAddress}
    #[derive(Drop, starknet::Event)]
    struct ExecutorChanged {new_executor:ContractAddress, new_epoch:u16}
    #[derive(Drop, starknet::Event)]
    struct ApprovalGranted {#[key] executor:ContractAddress, user:ContractAddress, epoch:u16}

        #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        OwnerChanged: OwnerChanged,
        ExecutorChanged: ExecutorChanged,
        ApprovalGranted:ApprovalGranted
    }
}