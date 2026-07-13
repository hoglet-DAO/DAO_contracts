// Sentinel Module - Emergency Circuit Breaker
//
// Allows the Guardian (a highly trusted address or cold wallet) to pause the protocol in case
// of emergency. The pause has an auto-expire of 2 epochs (2 weeks) to
// prevent the Guardian from abusing the power indefinitely.
//
// Pause rules:
// - Pausable: create_lock, propose, cast_vote, execute_proposal
// - NEVER pausable: withdraw, claim_rewards, claim_bribe (user funds are sacred)
//
module dao_factory::sentinel {
    friend dao_factory::petra;

    use std::signer;
    use supra_framework::event;
    use std::error;
    use std::option;

    use dao_factory::pilgrim;
    use dao_factory::charter;

    // Errors 
    const E_NOT_GUARDIAN: u64 = 1;
    const E_NO_GUARDIAN: u64 = 2;
    const E_PROTOCOL_PAUSED: u64 = 3;
    const E_ALREADY_PAUSED: u64 = 5;
    const E_NOT_PAUSED: u64 = 6;
    const E_COOLDOWN_ACTIVE: u64 = 7;

    // Constants 
    // The pause auto-expires after 2 epochs (2 weeks).
    // The Guardian must renew if the danger persists.
    const PAUSE_DURATION_EPOCHS: u64 = 2;
    
    // Cooldown between pauses: 1 epoch.
    // Prevents pause/unpause spam.
    const PAUSE_COOLDOWN_EPOCHS: u64 = 1;

    // Structs 
    struct PauseState has key {
        // If true, pausable functions are blocked
        is_paused: bool,
        // Epoch in which the pause was activated (0 if not active)
        pause_epoch: u64,
        // Epoch in which the pause expires automatically
        pause_expiry_epoch: u64,
        // Last epoch in which it was unpaused (for cooldown)
        last_unpause_epoch: u64,
    }

    // Events 
    #[event]
    struct ProtocolPaused has drop, store {
        dao_address: address,
        guardian: address,
        pause_epoch: u64,
        expiry_epoch: u64,
    }

    #[event]
    struct ProtocolUnpaused has drop, store {
        dao_address: address,
        caller: address,
        epoch: u64,
        was_auto_expired: bool,
    }

    // Initialization 
    // Initializes the pause state for a DAO.
    // Called by petra when creating the DAO.
    public(friend) fun initialize(dao_signer: &signer) {
        move_to(dao_signer, PauseState {
            is_paused: false,
            pause_epoch: 0,
            pause_expiry_epoch: 0,
            last_unpause_epoch: 0,
        });
    }

    // Core Functions 

    // Pauses the protocol. Only the Guardian can call this.
    //
    // The pause auto-expires after PAUSE_DURATION_EPOCHS.
    public entry fun pause(
        guardian: &signer, 
        dao_address: address
    ) acquires PauseState {
        // Verify that it is the Guardian
        let guardian_opt = charter::get_guardian(dao_address);
        assert!(option::is_some(&guardian_opt), error::invalid_state(E_NO_GUARDIAN));
        let guardian_addr = *option::borrow(&guardian_opt);
        assert!(signer::address_of(guardian) == guardian_addr, error::permission_denied(E_NOT_GUARDIAN));

        let state = borrow_global_mut<PauseState>(dao_address);
        let current_epoch = pilgrim::now();

        // Cannot pause if already paused (must unpause first or wait for expiry)
        assert!(!state.is_paused || current_epoch >= state.pause_expiry_epoch, error::invalid_state(E_ALREADY_PAUSED));

        // Cooldown: cannot re-pause immediately after unpausing
        assert!(
            state.last_unpause_epoch == 0 || current_epoch >= state.last_unpause_epoch + PAUSE_COOLDOWN_EPOCHS,
            error::invalid_state(E_COOLDOWN_ACTIVE)
        );

        state.is_paused = true;
        state.pause_epoch = current_epoch;
        state.pause_expiry_epoch = current_epoch + PAUSE_DURATION_EPOCHS;

        event::emit(ProtocolPaused {
            dao_address,
            guardian: guardian_addr,
            pause_epoch: current_epoch,
            expiry_epoch: state.pause_expiry_epoch,
        });
    }

    // Unpauses the protocol manually. Only the Guardian can call this.
    public entry fun unpause(
        guardian: &signer, 
        dao_address: address
    ) acquires PauseState {
        let guardian_opt = charter::get_guardian(dao_address);
        assert!(option::is_some(&guardian_opt), error::invalid_state(E_NO_GUARDIAN));
        let guardian_addr = *option::borrow(&guardian_opt);
        assert!(signer::address_of(guardian) == guardian_addr, error::permission_denied(E_NOT_GUARDIAN));

        let state = borrow_global_mut<PauseState>(dao_address);
        assert!(state.is_paused, error::invalid_state(E_NOT_PAUSED));

        state.is_paused = false;
        state.last_unpause_epoch = pilgrim::now();

        event::emit(ProtocolUnpaused {
            dao_address,
            caller: guardian_addr,
            epoch: pilgrim::now(),
            was_auto_expired: false,
        });
    }

    // Verification Function (Called by other modules) 
    // Verifies that the protocol is NOT paused for a DAO.
    // Modules that must respect the pause call this before executing.
    //
    // If the pause expired automatically, it unpauses and allows continuing.
    public fun assert_not_paused(dao_address: address) acquires PauseState {
        if (!exists<PauseState>(dao_address)) return; // DAOs without sentinel = never paused

        let state = borrow_global_mut<PauseState>(dao_address);
        
        if (state.is_paused) {
            let current_epoch = pilgrim::now();
            
            // Auto-expire: if the deadline has passed, unpause automatically
            if (current_epoch >= state.pause_expiry_epoch) {
                state.is_paused = false;
                state.last_unpause_epoch = current_epoch;
                
                event::emit(ProtocolUnpaused {
                    dao_address,
                    caller: @0x0, // Auto-expired, there is no caller
                    epoch: current_epoch,
                    was_auto_expired: true,
                });
                // Continue - the protocol is no longer paused
            } else {
                // Still paused and has not expired
                abort error::unavailable(E_PROTOCOL_PAUSED)
            }
        };
        // Not paused = continue normally
    }

    // Views 
    #[view]
    public fun is_paused(dao_address: address): bool acquires PauseState {
        if (!exists<PauseState>(dao_address)) return false;
        let state = borrow_global<PauseState>(dao_address);
        state.is_paused && pilgrim::now() < state.pause_expiry_epoch
    }

    #[view]
    public fun pause_expiry_epoch(dao_address: address): u64 acquires PauseState {
        if (!exists<PauseState>(dao_address)) return 0;
        borrow_global<PauseState>(dao_address).pause_expiry_epoch
    }

    #[view]
    public fun can_pause(dao_address: address): bool acquires PauseState {
        if (!exists<PauseState>(dao_address)) return false;
        let state = borrow_global<PauseState>(dao_address);
        let current_epoch = pilgrim::now();
        
        // Can pause if: not currently paused (or expired) AND cooldown passed
        let not_actively_paused = !state.is_paused || current_epoch >= state.pause_expiry_epoch;
        let cooldown_passed = state.last_unpause_epoch == 0 || 
                              current_epoch >= state.last_unpause_epoch + PAUSE_COOLDOWN_EPOCHS;
        
        not_actively_paused && cooldown_passed
    }
}
