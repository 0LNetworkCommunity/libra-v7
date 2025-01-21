/// Publishes configuration information for validators, and issues reconfiguration events
/// to synchronize configuration changes for the validators.
module diem_framework::reconfiguration {
    use std::error;
    // use std::features;
    use std::signer;

    use diem_framework::account;
    use diem_framework::event;
    use diem_framework::stake;
    use diem_framework::system_addresses;
    use diem_framework::timestamp;
    use diem_framework::chain_status;
    use diem_framework::storage_gas;
    use ol_framework::epoch_helper;

    // use diem_std::debug::print;

    friend diem_framework::block;
    friend diem_framework::diem_governance;
    friend diem_framework::epoch_boundary;
    friend diem_framework::consensus_config;
    // TODO: check if these are necessary
    friend diem_framework::execution_config;
    friend diem_framework::gas_schedule;
    friend diem_framework::genesis;
    friend diem_framework::version;

    /// Event that signals consensus to start a new epoch,
    /// with new configuration information. This is also called a
    /// "reconfiguration event"
    struct NewEpochEvent has drop, store {
        epoch: u64,
    }

    /// Holds information about state of reconfiguration
    struct Configuration has key {
        /// Epoch number
        epoch: u64,
        /// Time of last reconfiguration. Only changes on reconfiguration events.
        last_reconfiguration_time: u64,
        /// Event handle for reconfiguration events
        events: event::EventHandle<NewEpochEvent>,
    }

    /// Convenience struct to hold the epoch interval outside of the block::resource
    struct EpochInterval has key {
      epoch_interval: u64
    }


    /// Reconfiguration will be disabled if this resource is published under the
    /// diem_framework system address
    struct DisableReconfiguration has key {}

    /// The `Configuration` resource is in an invalid state
    const ECONFIGURATION: u64 = 1;
    /// A `Reconfiguration` resource is in an invalid state
    const ECONFIG: u64 = 2;
    /// A `ModifyConfigCapability` is in a different state than was expected
    const EMODIFY_CAPABILITY: u64 = 3;
    /// An invalid block time was encountered.
    const EINVALID_BLOCK_TIME: u64 = 4;
    /// An invalid block time was encountered.
    const EINVALID_GUID_FOR_EVENT: u64 = 5;


    /// Only called during genesis.
    /// Publishes `Configuration` resource. Can only be invoked by diem framework account, and only a single time in Genesis.
    public(friend) fun initialize(diem_framework: &signer) {
        system_addresses::assert_diem_framework(diem_framework);

        // assert it matches `new_epoch_event_key()`, otherwise the event can't be recognized
        assert!(account::get_guid_next_creation_num(signer::address_of(diem_framework)) == 2, error::invalid_state(EINVALID_GUID_FOR_EVENT));
        move_to<Configuration>(
            diem_framework,
            Configuration {
                epoch: 0,
                last_reconfiguration_time: 0,
                events: account::new_event_handle<NewEpochEvent>(diem_framework),
            }
        );
    }

    /// Private function to temporarily halt reconfiguration.
    /// This function should only be used for offline WriteSet generation purpose and should never be invoked on chain.
    fun disable_reconfiguration(diem_framework: &signer) {
        system_addresses::assert_diem_framework(diem_framework);
        assert!(reconfiguration_enabled(), error::invalid_state(ECONFIGURATION));
        move_to(diem_framework, DisableReconfiguration {})
    }

    /// Private function to resume reconfiguration.
    /// This function should only be used for offline WriteSet generation purpose and should never be invoked on chain.
    fun enable_reconfiguration(diem_framework: &signer) acquires DisableReconfiguration {
        system_addresses::assert_diem_framework(diem_framework);

        assert!(!reconfiguration_enabled(), error::invalid_state(ECONFIGURATION));
        DisableReconfiguration {} = move_from<DisableReconfiguration>(signer::address_of(diem_framework));
    }

    fun reconfiguration_enabled(): bool {
        !exists<DisableReconfiguration>(@diem_framework)
    }

    /// Signal validators to start using new configuration. Must be called from friend config modules.
    public(friend) fun reconfigure() acquires Configuration {

        // Do not do anything if genesis has not finished.
        if (chain_status::is_genesis() || timestamp::now_microseconds() == 0) {
            return
        };

        // Do not do anything if a reconfiguration event is already emitted within this transaction.
        //
        // This is OK because:
        // - The time changes in every non-empty block
        // - A block automatically ends after a transaction that emits a reconfiguration event, which is guaranteed by
        //   VM spec that all transactions coming after a reconfiguration transaction will be returned as Retry
        //   status.
        // - Each transaction must emit at most one reconfiguration event
        //
        // Thus, this check ensures that a transaction that does multiple "reconfiguration required" actions emits only
        // one reconfiguration event.
        //

        // Reconfiguration "forces the block" to end, as mentioned above. Therefore, we must process the collected fees
        // explicitly so that staking can distribute them.
        // transaction_fee::process_collected_fees();

        // On ordinary production cases we want to check time
        // Note: we don't want to check the time at times on off chain
        // governance (rescue misssions, that produce a fork)
        let check_timestamp = true;

        if(maybe_bump_epoch(check_timestamp)) {
          // recompute the gas costs if there have been module publish/updates
          storage_gas::on_reconfig();
          emit_epoch_event()
        }
    }

    fun maybe_bump_epoch(check_time: bool): bool acquires Configuration {
        let config_ref = borrow_global_mut<Configuration>(@diem_framework);

        let current_time = timestamp::now_microseconds();
        if (check_time) { // sometimes we don't want to check the time, e.g. on
        // offchain governance (fork) where the blockchain failed at the epoch boundary
        if (current_time == config_ref.last_reconfiguration_time) {
            // do nothing
            return false
          };
        };

        config_ref.last_reconfiguration_time = current_time;
        config_ref.epoch = config_ref.epoch + 1;

        epoch_helper::set_epoch(config_ref.epoch);
        return true
    }
     /// Signal validators to start using new configuration. Must be called from friend config modules.
    fun emit_epoch_event() acquires Configuration {
        let config_ref = borrow_global_mut<Configuration>(@diem_framework);

        event::emit_event<NewEpochEvent>(
            &mut config_ref.events,
            NewEpochEvent {
                epoch: config_ref.epoch,
            },
        );
    }

    public fun last_reconfiguration_time(): u64 acquires Configuration {
        borrow_global<Configuration>(@diem_framework).last_reconfiguration_time
    }

    public fun current_epoch(): u64 acquires Configuration {
        borrow_global<Configuration>(@diem_framework).epoch
    }

    /// Emit a `NewEpochEvent` event. This function will be invoked by genesis directly to generate the very first
    /// reconfiguration event.
    fun emit_genesis_reconfiguration_event() acquires Configuration {
        let config_ref = borrow_global_mut<Configuration>(@diem_framework);
        assert!(config_ref.epoch == 0 && config_ref.last_reconfiguration_time == 0, error::invalid_state(ECONFIGURATION));
        config_ref.epoch = 1;

        event::emit_event<NewEpochEvent>(
            &mut config_ref.events,
            NewEpochEvent {
                epoch: config_ref.epoch,
            },
        );
    }

    /// set the epoch interval on each block
    public(friend) fun set_epoch_interval(framework: &signer, epoch_interval: u64) acquires EpochInterval {
      if (!exists<EpochInterval>(@ol_framework)) {
        move_to(framework, EpochInterval {
          epoch_interval
        })
      } else {
        let state = borrow_global_mut<EpochInterval>(@ol_framework);
        state.epoch_interval = epoch_interval
      }
    }

    #[view]
    /// Return epoch interval in seconds.
    public fun get_epoch_interval_secs(): u64 acquires EpochInterval {
      let state = borrow_global_mut<EpochInterval>(@ol_framework);
        state.epoch_interval / 1000000
    }

    #[view]
    /// Return rough remaining seconds in epoch
    public fun get_remaining_epoch_secs(): u64 acquires Configuration, EpochInterval {
      let now = timestamp::now_seconds();
      let last_epoch_secs = last_reconfiguration_time() / 1000000;
      let interval = get_epoch_interval_secs();
      if (now < last_epoch_secs) { // impossible underflow, some thign bad, or tests
          return 0
      };

      let deadline = last_epoch_secs + interval;

      if (now > deadline) { // we've run over the deadline
        return 0
      };

      // belt and suspenders
      if (deadline > now) {
        return deadline - now
      };

      return 0

    }
    // For tests, skips the guid validation.
    #[test_only]
    public fun initialize_for_test(account: &signer) {
        system_addresses::assert_diem_framework(account);
        move_to<Configuration>(
            account,
            Configuration {
                epoch: 0,
                last_reconfiguration_time: 0,
                events: account::new_event_handle<NewEpochEvent>(account),
            }
        );
    }

    // TODO: from v5 evaluate if this is needed or is obviated by
    // block::emit_writeset_block_event, which updates the timestamp.
    /// Danger: use for extreme edge case where we don't want to check
    /// timestamp.
    /// For rescue missions we want to ignore timestamps since we may be at an
    /// epoch boundary and may be stuck because of the timestamp checking.
    public(friend) fun danger_reconfigure_ignore_timestamp(vm: &signer) acquires Configuration {
        system_addresses::assert_ol(vm);

        let check_timestamp = false;
        if(maybe_bump_epoch(check_timestamp)) {
          storage_gas::on_reconfig();
          emit_epoch_event()
        }
    }

    #[test_only]
    public fun reconfigure_for_test() acquires Configuration {
        reconfigure();
    }

    // This is used together with stake::end_epoch() for testing with last_reconfiguration_time
    // It must be called each time an epoch changes
    #[test_only]
    public fun test_helper_increment_epoch_dont_reconfigure(count: u64) acquires Configuration {
        let config_ref = borrow_global_mut<Configuration>(@diem_framework);
        let current_time = timestamp::now_microseconds();
        // if (current_time == config_ref.last_reconfiguration_time) {
        //     return
        // };
        config_ref.last_reconfiguration_time = current_time;
        config_ref.epoch = config_ref.epoch + count;

        epoch_helper::set_epoch(config_ref.epoch);

    }
}
