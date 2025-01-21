module ol_framework::musical_chairs {
  use std::error;
  use std::fixed_point32;
  use std::vector;
  use diem_framework::chain_status;
  use diem_framework::system_addresses;
  use diem_framework::stake;
  use ol_framework::grade;
  use ol_framework::jail;
  use ol_framework::testnet;

  // use diem_std::debug::print;

  friend diem_framework::genesis;
  friend diem_framework::diem_governance;
  friend ol_framework::epoch_boundary;
  #[test_only]
  friend ol_framework::mock;

  //////// ERROR CODES ////////
  /// non_compliant vals, should not appear in compliant
  const EBAD_APPLE_IN_COMPLIANT: u64 = 0;


  ///////// STATIC ////////
  /// We don't want to play the validator selection games
  /// before we're clear out of genesis
  const EPOCH_TO_START_EVAL: u64 = 2;
  /// We can't evaluate the performance of validators
  /// when there are too few rounds committed
  const MINIMUM_ROUNDS_PER_EPOCH: u64 = 1000;


  struct Chairs has key {
    // The number of chairs in the game
    seats_offered: u64,
    // TODO: A small history, for future use.
    history: vector<u64>,
  }

  // With musical chairs we are trying to estimate
  // the number of nodes which the network can support
  // BFT has upperbounds in the low hundreds, but we
  // don't need to hard code it.
  // There also needs to be an upper bound so that there is some
  // competition among validators.
  // Instead of hard coding a number, and needing to reach social
  // consensus to change it:  we'll determine the size based on
  // the network's performance as a whole.
  // There are many metrics that can be used. For now we'll use
  // a simple heuristic that is already on chain: compliant node cardinality.
  // Other heuristics may be explored, so long as the information
  // reliably committed to the chain.

  // The rules:
  // Validators who perform, are not guaranteed entry into the
  // next epoch of the chain. All we are establishing is the ceiling
  // for validators.
  // When the 100% of the validators are performing well
  // the network can safely increase the threshold by 1 node.
  // We can also say if less that 5% fail, no change happens.
  // When the network is performing poorly, greater than 5%,
  // the threshold is reduced not by a predetermined unit, but
  // to the number of compliant and performant nodes.

  /// Called by root in genesis to initialize the GAS coin
  public(friend) fun initialize(
      vm: &signer,
      genesis_seats: u64,
  ) {
    // system_addresses::assert_vm(vm);
    // TODO: replace with VM
    system_addresses::assert_ol(vm);

    chain_status::is_genesis();
    if (exists<Chairs>(@ol_framework)) {
      return
    };

    move_to(vm, Chairs {
      seats_offered: genesis_seats,
      history: vector::empty<u64>(),
    });
  }

  /// get the number of seats in the game
  /// returns the list of compliant validators and the number of seats
  /// we should offer in the next epoch
  /// (compliant_vals, seats_offered)
  public(friend) fun stop_the_music(
    vm: &signer,
    epoch: u64,
    round: u64,
  ): (vector<address>, u64) acquires Chairs {
    system_addresses::assert_ol(vm);

    let chairs = borrow_global_mut<Chairs>(@ol_framework);
    let validators = stake::get_current_validators();
    let (compliant_vals, bad, fail_ratio) = eval_compliance_impl(validators, epoch, round);

    // jail the non-compliant
    // commit note: we moved this from epoch_boundary process_outgoing, which
    // is concerned mostly with payment.
    // TODO:L Ideally stop_the_music would be a pure function.
    // move the jailing to top level in epoch_boundary.
    vector::for_each(bad, |addr| {
      jail::jail(vm, addr);
    });


    let num_compliant_vals = vector::length(&compliant_vals);

    // Error handle. We should not have gone into an epoch where we had MORE validators than seats offered.
    // If this happens it's because we are in some kind of a fork condition. Return with no changes
    if (num_compliant_vals > chairs.seats_offered) {
      return (compliant_vals, chairs.seats_offered)
    };

    // Calculate the number of seats to offer
    chairs.seats_offered = calculate_seats_to_offer(
      num_compliant_vals,
      fail_ratio,
      chairs.seats_offered
    );

    (compliant_vals, chairs.seats_offered)
  }

  // Case: All seats performed well in the last epoch
  // - The happiest case: All filled seats performed well in the last epoch.
  // - Increment the number of seats offered by 1.
  //
  // Case: Non-compliance detected
  // - If non-compliance is detected (> 5%), reduce the number of seats offered to the number of compliant nodes.
  // - Otherwise, if non-compliance is between 0 and 5%, increment the number of seats offered by 1.
  //
  // Error Handling
  // - If there are more validators than seats offered, it indicates a fork condition. In such a case, return with no changes.
  //
  // Bootstrap Mode
  // - If the network is bootstrapping, ensure that the seat count does not fall below the number of compliant nodes.
  // - Ensure that the number of seats offered is not less than 4, especially during genesis or in testnets.

  public fun calculate_seats_to_offer(
    num_compliant_vals: u64,
    fail_ratio: fixed_point32::FixedPoint32,
    current_seats_offered: u64
  ): u64 {
    let new_seats_offered = if (fixed_point32::is_zero(fail_ratio)) {
      // The happiest case. All filled seats performed well in the last epoch
      current_seats_offered + 1
    } else {
      let non_compliance_pct = fixed_point32::multiply_u64(100, fail_ratio);
      if (non_compliance_pct > 5) {
        // Sad case. If we are not getting compliance, need to ratchet down the offer of seats in the next epoch.
        // See below find_safe_set_size, how we determine what that number should be
        num_compliant_vals
      } else {
        // Ok case. If it's between 0 and 5% then we accept that margin as if it was fully compliant
        current_seats_offered + 1
      }
    };

    // Catch failure mode mostly for genesis, or testnets
    if (new_seats_offered < 4) {
      4
    } else {
      new_seats_offered
    }
  }

  // Update seat count to match filled seats post-PoF auction.
  // in case we were not able to fill all the seats offered
  // we don't want to keep incrementing from a baseline which we cannot fill
  // it can spiral out of range.
  public(friend) fun set_current_seats(framework: &signer, filled_seats: u64): u64 acquires Chairs{
    system_addresses::assert_diem_framework(framework);
    let chairs = borrow_global_mut<Chairs>(@ol_framework);
    chairs.seats_offered = filled_seats;
    chairs.seats_offered
  }

  // use the Case statistic to determine what proportion of the network is compliant.
  // private function prevent list DoS.
  fun eval_compliance_impl(
    validators: vector<address>,
    epoch: u64,
    _round: u64,
  ): (vector<address>, vector<address>, fixed_point32::FixedPoint32) {
    let val_set_len = vector::length(&validators);

    // skip first epoch, don't evaluate if the network doesn't have sufficient data
    if (epoch < EPOCH_TO_START_EVAL) return (validators, vector::empty<address>(), fixed_point32::create_from_rational(1, 1));

    let (compliant_nodes, non_compliant_nodes) = grade::eval_compliant_vals(validators);

    let good_len = vector::length(&compliant_nodes) ;
    let bad_len = vector::length(&non_compliant_nodes);

    // sanity check that the bad ones are not in the compliant list
    vector::for_each_ref(&non_compliant_nodes, |el| {
      assert!(!vector::contains(&compliant_nodes, el), error::invalid_state(EBAD_APPLE_IN_COMPLIANT));
    });

    // Note: sorry for repetition but necessary for writing tests and debugging.
    let null = fixed_point32::create_from_raw_value(0);
    if (good_len > val_set_len) { // safety
      return (vector::empty(), vector::empty(), null)
    };

    if (bad_len > val_set_len) { // safety
      return (vector::empty(), vector::empty(), null)
    };

    if ((good_len + bad_len) != val_set_len) { // safety
      return (vector::empty(), vector::empty(), null)
    };

    // commit note: if it's zero we want to know, and set it explicitly
    let ratio = fixed_point32::create_from_rational(bad_len, val_set_len);

    (compliant_nodes, non_compliant_nodes, ratio)
  }

  // Check for genesis, upgrade or recovery mode scenarios
  // if we are at genesis or otherwise at start of an epoch and don't
  // have a sufficient amount of history to evaluate nodes
  // we might reduce the validator set too agressively.
  // Musical chairs should not evaluate performance with less than 1000 rounds
  // created on mainnet,
  // there's something else very wrong in that case.

  fun is_booting_up(epoch: u64, round: u64): bool {
    !testnet::is_testnet() &&
    (epoch < EPOCH_TO_START_EVAL ||
    round < MINIMUM_ROUNDS_PER_EPOCH)
  }

  //////// GETTERS ////////

  #[view]
  public fun get_current_seats(): u64 acquires Chairs {
      borrow_global<Chairs>(@ol_framework).seats_offered
  }

  //////// TEST HELPERS ////////

  #[test_only]
  use diem_framework::chain_id;

  #[test_only]
  public fun test_stop(vm: &signer, epoch: u64, epoch_round: u64): (vector<address>, u64) acquires Chairs {
    stop_the_music(vm, epoch, epoch_round)
  }

  #[test_only]
  public fun test_eval_compliance(root: &signer, validators: vector<address>,
  epoch: u64, round: u64): (vector<address>, vector<address>,
  fixed_point32::FixedPoint32) {
    system_addresses::assert_ol(root);
    eval_compliance_impl(validators, epoch, round)

  }

  //////// TESTS ////////

  #[test(vm = @ol_framework)]
  public entry fun initialize_chairs(vm: signer) acquires Chairs {
    chain_id::initialize_for_test(&vm, 4);
    initialize(&vm, 10);
    assert!(get_current_seats() == 10, 1004);
  }

  #[test]
  fun test_calculate_seats_to_offer() {
    // Test case: all seats are compliant
    let result = calculate_seats_to_offer(5, fixed_point32::create_from_rational(0, 1), 5);
    assert!(result == 6, 1001);

    // Test case: more than 5% non-compliance
    let result = calculate_seats_to_offer(18, fixed_point32::create_from_rational(2, 20), 20);
    assert!(result == 18, 1002);

    // Test case: 5% non-compliance
    let result = calculate_seats_to_offer(19, fixed_point32::create_from_rational(1, 20), 20);
    assert!(result == 21, 1003);

    // Test case: less than 5% non-compliance
    let result = calculate_seats_to_offer(98, fixed_point32::create_from_rational(2, 100), 100);
    assert!(result == 101, 1003);

    // Test case: seats offered should not be less than 4
    let result = calculate_seats_to_offer(2, fixed_point32::create_from_rational(1, 1), 2);
    assert!(result == 4, 1004);
  }
}
