// Epoch Module - The global clock of the protocol.
// Converts the continuous time of the blockchain into discrete weekly blocks.
// All system modules must synchronize through this module.
module dao_factory::pilgrim {
    use supra_framework::timestamp;

    // Constants 
    // 1 week in seconds. All epochs have this duration.
    const EPOCH_DURATION: u64 = 604_800;

    // Public Functions 

    // Returns the current epoch number (starts at 0 at chain genesis).
    #[view]
    public fun now(): u64 {
        timestamp::now_seconds() / EPOCH_DURATION
    }

    // Returns the duration in seconds of each epoch.
    #[view]
    public fun duration(): u64 {
        EPOCH_DURATION
    }

    // Returns the UNIX timestamp (in seconds) of the start of epoch `e`.
    // Useful for calculating exact time windows.
    #[view]
    public fun epoch_start(e: u64): u64 {
        e * EPOCH_DURATION
    }

    // Returns the UNIX timestamp of the start of the NEXT epoch.
    #[view]
    public fun next_epoch_start(): u64 {
        (now() + 1) * EPOCH_DURATION
    }

    // Returns how many seconds are left until the current epoch ends.
    #[view]
    public fun seconds_until_next_epoch(): u64 {
        next_epoch_start() - timestamp::now_seconds()
    }

    // Tests 
    #[test]
    fun test_epoch_math() {
        // Epoch 0 starts at t=0, ends at t=604799
        // Epoch 1 starts at t=604800
        assert!(epoch_start(0) == 0, 0);
        assert!(epoch_start(1) == 604_800, 1);
        assert!(epoch_start(2) == 1_209_600, 2);
    }
}
