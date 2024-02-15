module ol_framework::testnet {
    ///////////////////////////////////////////////////////////////////////////
    // sets an env variable for test constants for devs and ci testing
    // File Prefix for errors: 2002
    ///////////////////////////////////////////////////////////////////////////
    use std::error;
    use std::chain_id;
    use diem_framework::system_addresses;

    /// trying something that should only be done on testnet, out satan!
    const ENOT_TESTNET: u64 = 1;
    /// yo! only root should be trying this
    const EWHY_U_NO_ROOT: u64 = 2;

    public fun is_testnet(): bool {
        chain_id::get() == 4
    }

    //commit note: confusing is_not_mainnet

    public fun assert_testnet(root: &signer): bool {
      system_addresses::assert_ol(root);
      assert!(is_testnet(), error::invalid_state(ENOT_TESTNET));
      true
    }

    public fun is_staging_net(): bool {
        // NOTE: confusingly in vendor's rust code chain=2 is called TESTNET
        chain_id::get() == 2
    }

    #[test_only]
    public fun unset(vm: &signer) {
      use diem_framework::system_addresses;
      system_addresses::assert_ol(vm);
      chain_id::set_for_test(vm, 1);

    }
}
