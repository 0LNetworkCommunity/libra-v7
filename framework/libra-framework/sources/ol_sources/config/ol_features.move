
module ol_framework::ol_features_constants {
    use std::features;
    ///////// KEEP COMMENTED ////////
    // NOTE: this feature is deprecated
    // since epoch trigger was an experimental feature
    // but is permanent since v7.0.3.
    // The code and ID are  kept here for reference
    // /// Whether the new epoch trigger logic is enabled.
    // /// Lifetime: transient
    // const EPOCH_TRIGGER_ENABLED: u64 = 24;
    // public fun get_epoch_trigger(): u64 { EPOCH_TRIGGER_ENABLED }
    // public fun epoch_trigger_enabled(): bool {
    //     features::is_enabled(EPOCH_TRIGGER_ENABLED)
    // }


    /// GOVERNANCE MODE
    /// Certain transactions are disabled during deliberation and
    /// execution of on-chain hot upgrades.
    const GOVERNANCE_MODE_ENABLED: u64 = 25;
    public fun get_governance_mode(): u64 { GOVERNANCE_MODE_ENABLED }
    public fun is_governance_mode_enabled(): bool {
        features::is_enabled(GOVERNANCE_MODE_ENABLED)
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
