module ol_framework::epoch_helper {
    use diem_framework::system_addresses;

    friend diem_framework::genesis;
    friend diem_framework::reconfiguration;

    // too many cyclic dependencies from reconfiguration being the only place to reach epoch.
    struct EpochHelper has key {
      epoch: u64
    }

    public(friend) fun initialize(framework: &signer) {
      // must be framework address
      system_addresses::assert_diem_framework(framework);

      if (!exists<EpochHelper>(@ol_framework)){
        move_to(framework, EpochHelper {
          epoch: 0
        })
      };
    }

    public(friend) fun set_epoch(epoch: u64) acquires EpochHelper{
      let state = borrow_global_mut<EpochHelper>(@ol_framework);
      state.epoch = epoch;
    }

    #[view]
    public fun get_current_epoch():u64 acquires EpochHelper {
      if (!exists<EpochHelper>(@ol_framework)) return 0; // for unit tests

      let state = borrow_global<EpochHelper>(@ol_framework);
      state.epoch
    }

    #[test_only]
    public fun test_set_epoch(framework: &signer, epoch: u64) acquires EpochHelper {
      system_addresses::assert_diem_framework(framework);
      initialize(framework);
      set_epoch(epoch);

    }
}
