/// This module defines a struct storing the metadata of the block and new block events.
module diem_framework::block {
    use std::bcs;
    use std::error;
    use std::option;
    use std::vector;
    // TODO: restore this
    // use std::features;
    use std::string;
    use diem_framework::account;
    use diem_framework::event::{Self, EventHandle};
    use diem_framework::randomness;
    use diem_framework::reconfiguration;
    use diem_framework::stake;
    use diem_framework::state_storage;
    use diem_framework::system_addresses;
    use diem_framework::timestamp;
    use diem_std::debug::print;
    use ol_framework::testnet;

    //////// 0L ////////
    use ol_framework::epoch_boundary;

    friend diem_framework::genesis;

    const MAX_U64: u64 = 18446744073709551615;

    /// Should be in-sync with BlockResource rust struct in new_block.rs
    struct BlockResource has key {
        /// Height of the current block
        height: u64,
        /// Time period between epochs.
        epoch_interval: u64,
        /// Handle where events with the time of new blocks are emitted
        new_block_events: EventHandle<NewBlockEvent>,
        update_epoch_interval_events: EventHandle<UpdateEpochIntervalEvent>,
    }

    /// Should be in-sync with NewBlockEvent rust struct in new_block.rs
    struct NewBlockEvent has drop, store {
        hash: address,
        epoch: u64,
        round: u64,
        height: u64,
        previous_block_votes_bitvec: vector<u8>,
        proposer: address,
        failed_proposer_indices: vector<u64>,
        /// On-chain time during the block at the given height
        time_microseconds: u64,
    }

    /// Event emitted when a proposal is created.
    struct UpdateEpochIntervalEvent has drop, store {
        old_epoch_interval: u64,
        new_epoch_interval: u64,
    }

    /// The number of new block events does not equal the current block height.
    const ENUM_NEW_BLOCK_EVENTS_DOES_NOT_MATCH_BLOCK_HEIGHT: u64 = 1;
    /// An invalid proposer was provided. Expected the proposer to be the VM or an active validator.
    const EINVALID_PROPOSER: u64 = 2;
    /// Epoch interval cannot be 0.
    const EZERO_EPOCH_INTERVAL: u64 = 3;

    /// This can only be called during Genesis.
    public(friend) fun initialize(diem_framework: &signer, epoch_interval_microsecs: u64) {
        system_addresses::assert_diem_framework(diem_framework);
        assert!(epoch_interval_microsecs > 0, error::invalid_argument(EZERO_EPOCH_INTERVAL));

        reconfiguration::set_epoch_interval(diem_framework, epoch_interval_microsecs);

        move_to<BlockResource>(
            diem_framework,
            BlockResource {
                height: 0,
                epoch_interval: epoch_interval_microsecs,
                new_block_events: account::new_event_handle<NewBlockEvent>(diem_framework),
                update_epoch_interval_events: account::new_event_handle<UpdateEpochIntervalEvent>(diem_framework),
            }
        );
    }

    /// Update the epoch interval.
    /// Can only be called as part of the Diem governance proposal process established by the DiemGovernance module.
    public(friend) fun update_epoch_interval_microsecs(
        diem_framework: &signer,
        new_epoch_interval: u64,
    ) acquires BlockResource {
        system_addresses::assert_diem_framework(diem_framework); //TODO: remove after testing fork
        assert!(new_epoch_interval > 0, error::invalid_argument(EZERO_EPOCH_INTERVAL));

        let block_resource = borrow_global_mut<BlockResource>(@diem_framework);
        let old_epoch_interval = block_resource.epoch_interval;

        // NOTE this data is duplicated since block.move
        // cannot be accessed by other system modules without creating
        // circular dependencies.
        // update locally
        block_resource.epoch_interval = new_epoch_interval;
        // and set in reconfigurations
        reconfiguration::set_epoch_interval(diem_framework, new_epoch_interval);

        event::emit_event<UpdateEpochIntervalEvent>(
            &mut block_resource.update_epoch_interval_events,
            UpdateEpochIntervalEvent { old_epoch_interval, new_epoch_interval },
        );
    }

    /// Set the metadata for the current block.
    /// The runtime always runs this before executing the transactions in a block.
    fun block_prologue(
        vm: signer,
        hash: address,
        epoch: u64,
        round: u64,
        proposer: address,
        failed_proposer_indices: vector<u64>,
        previous_block_votes_bitvec: vector<u8>,
        timestamp: u64
    ) acquires BlockResource {
        // Operational constraint: can only be invoked by the VM.
        system_addresses::assert_vm(&vm);

        // Blocks can only be produced by a valid proposer or by the VM itself for Nil blocks (no user txs).
        assert!(
            proposer == @vm_reserved || stake::is_current_epoch_validator(proposer),
            error::permission_denied(EINVALID_PROPOSER),
        );

        let proposer_index = option::none();
        if (proposer != @vm_reserved) {
            proposer_index = option::some(stake::get_validator_index(proposer));
        };

        let block_metadata_ref = borrow_global_mut<BlockResource>(@diem_framework);
        block_metadata_ref.height = event::counter(&block_metadata_ref.new_block_events);

        let new_block_event = NewBlockEvent {
            hash,
            epoch,
            round,
            height: block_metadata_ref.height,
            previous_block_votes_bitvec,
            proposer,
            failed_proposer_indices,
            time_microseconds: timestamp,
        };
        emit_new_block_event(&vm, &mut block_metadata_ref.new_block_events, new_block_event);

        // if (features::collect_and_distribute_gas_fees()) {
        //     // Assign the fees collected from the previous block to the previous block proposer.
        //     // If for any reason the fees cannot be assigned, this function burns the collected coins.
        //     transaction_fee::process_collected_fees();
        //     // Set the proposer of this block as the receiver of the fees, so that the fees for this
        //     // block are assigned to the right account.
        //     transaction_fee::register_proposer_for_fee_collection(proposer);
        // };

        // Performance scores have to be updated before the epoch transition as the transaction that triggers the
        // transition is the last block in the previous epoch.
        stake::update_performance_statistics(proposer_index, failed_proposer_indices);
        state_storage::on_new_block(reconfiguration::current_epoch());

        // update randomness seed for this block
        let seed = bcs::to_bytes(&hash);
        randomness::on_new_block(&vm, epoch, round, option::some(seed));

        // seperate logic for epoch advancment to allow for testing
        maybe_advance_epoch(&vm, timestamp, block_metadata_ref, round);

    }

    #[view]
    /// Get the current block height
    public fun get_current_block_height(): u64 acquires BlockResource {
        borrow_global<BlockResource>(@diem_framework).height
    }

    /// Emit the event and update height and global timestamp
    fun emit_new_block_event(vm: &signer, event_handle: &mut EventHandle<NewBlockEvent>, new_block_event: NewBlockEvent) {
        timestamp::update_global_time(vm, new_block_event.proposer, new_block_event.time_microseconds);
        assert!(
            event::counter(event_handle) == new_block_event.height,
            error::invalid_argument(ENUM_NEW_BLOCK_EVENTS_DOES_NOT_MATCH_BLOCK_HEIGHT),
        );
        event::emit_event<NewBlockEvent>(event_handle, new_block_event);
    }

    /// Emit a `NewBlockEvent` event. This function will be invoked by genesis directly to generate the very first
    /// reconfiguration event.
    fun emit_genesis_block_event(vm: signer) acquires BlockResource {
        let block_metadata_ref = borrow_global_mut<BlockResource>(@diem_framework);
        let genesis_id = @0x0;
        emit_new_block_event(
            &vm,
            &mut block_metadata_ref.new_block_events,
            NewBlockEvent {
                hash: genesis_id,
                epoch: 0,
                round: 0,
                height: 0,
                previous_block_votes_bitvec: vector::empty(),
                proposer: @vm_reserved,
                failed_proposer_indices: vector::empty(),
                time_microseconds: 0,
            }
        );
    }

    ///  Emit a `NewBlockEvent` event. This function will be invoked by write set script directly to generate the
    ///  new block event for WriteSetPayload.
    // NOTE: This function is not `(friend)` because governance scripts need to
    // call it.
    // TODO: refactor diem_governance so that this can again have only
    // friend visibility.
    public fun emit_writeset_block_event(vm_signer: &signer, fake_block_hash: address) acquires BlockResource {
        system_addresses::assert_vm(vm_signer);
        let block_metadata_ref = borrow_global_mut<BlockResource>(@diem_framework);
        block_metadata_ref.height = event::counter(&block_metadata_ref.new_block_events);

        event::emit_event<NewBlockEvent>(
            &mut block_metadata_ref.new_block_events,
            NewBlockEvent {
                hash: fake_block_hash,
                epoch: reconfiguration::current_epoch(),
                round: MAX_U64,
                height: block_metadata_ref.height,
                previous_block_votes_bitvec: vector::empty(),
                proposer: @vm_reserved,
                failed_proposer_indices: vector::empty(),
                time_microseconds: timestamp::now_microseconds(),
            }
        );
    }

    fun maybe_advance_epoch(
        vm: &signer,
        timestamp: u64,
        block_metadata_ref: &mut BlockResource,
        round: u64
        ) {

            // Check to prevent underflow, return quietly if the check fails
            if (timestamp < reconfiguration::last_reconfiguration_time()) {
                print(&string::utf8(b"Timestamp is less than the last reconfiguration time, returning early to prevent underflow. Check block prologue in block.move"));
                return
            };

            if (timestamp - reconfiguration::last_reconfiguration_time() >= block_metadata_ref.epoch_interval) {
                if (testnet::is_testnet()) {
                    epoch_boundary::epoch_boundary(
                        vm,
                        reconfiguration::current_epoch(),
                        round
                    );
                } else {
                    epoch_boundary::enable_epoch_trigger(vm, reconfiguration::current_epoch());
                }
            }
    }

    #[test_only]
    public fun initialize_for_test(account: &signer, epoch_interval_microsecs: u64) {
        initialize(account, epoch_interval_microsecs);
    }

    #[test_only]
    public fun test_maybe_advance_epoch(
        vm: &signer,
        timestamp: u64,
        round: u64,
    ) acquires BlockResource {
        let block_metadata_ref = borrow_global_mut<BlockResource>(@diem_framework);
        maybe_advance_epoch(vm, timestamp, block_metadata_ref, round);
    }

    #[test(diem_framework = @diem_framework)]
    #[ignore] //TODO: remove after testing fork
    public entry fun test_update_epoch_interval(diem_framework: signer) acquires BlockResource {
        account::create_account_for_test(@diem_framework);
        initialize(&diem_framework, 1);
        assert!(borrow_global<BlockResource>(@diem_framework).epoch_interval == 1, 0);
        update_epoch_interval_microsecs(&diem_framework, 2);
        assert!(borrow_global<BlockResource>(@diem_framework).epoch_interval == 2, 1);
    }

    #[test(diem_framework = @diem_framework, account = @0x123)]
    #[expected_failure(abort_code = 0x50003, location = diem_framework::system_addresses)]
    public entry fun test_update_epoch_interval_unauthorized_should_fail(
        diem_framework: signer,
        account: signer,
    ) acquires BlockResource {
        account::create_account_for_test(@diem_framework);
        initialize(&diem_framework, 1);
        update_epoch_interval_microsecs(&account, 2);
    }
}
