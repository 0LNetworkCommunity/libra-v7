
module ol_framework::ol_features_constants {
    use std::features;
    /// Whether the new epoch trigger logic is enabled.
    /// Lifetime: transient
    const EPOCH_TRIGGER_ENABLED: u64 = 24;
    public fun get_epoch_trigger(): u64 { EPOCH_TRIGGER_ENABLED }
    public fun epoch_trigger_enabled(): bool {
        features::is_enabled(EPOCH_TRIGGER_ENABLED)
    }


    //////// TEST HELPERS ////////
    #[test_only]
    const TEST_DUMMY_FLAG: u64 = 8675309;
    #[test_only]
    public fun test_get_dummy_flag(): u64 { TEST_DUMMY_FLAG }
    #[test_only]
    public fun test_dummy_flag_enabled(): bool {
        features::is_enabled(TEST_DUMMY_FLAG)
    }
}
