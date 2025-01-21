#[test_only]
module ol_framework::test_pof {
  use ol_framework::mock;
  use ol_framework::account;
  use ol_framework::epoch_helper;
  use ol_framework::proof_of_fee;
  use ol_framework::reconfiguration;
  use ol_framework::jail;
  use ol_framework::slow_wallet;
  use ol_framework::vouch;
  use ol_framework::testnet;
  use ol_framework::globals;
  use ol_framework::secret_bid;
  use diem_framework::stake;
  use diem_framework::chain_id;
  use std::vector;

  // use diem_std::debug::print;

  const Alice: address = @0x1000a;
  const Bob: address = @0x1000b;
  const Carol: address = @0x1000c;
  const Dave: address = @0x1000d;
  const Eve: address = @0x1000e;
  const Frank: address = @0x1000f;

  #[test_only]
  fun mock_good_bid(root: &signer, alice: &address) {
    let a_sig = account::create_signer_for_test(*alice);

    let epoch = 0; // we are at genesis in tests
    secret_bid::mock_revealed_bid(root, &a_sig, 1, epoch);
    let bid = secret_bid::get_bid_unchecked(*alice);
    assert!(bid == 1, 1001);

    let coin = slow_wallet::unlocked_amount(*alice);
    let (r, _, _, _) = proof_of_fee::get_consensus_reward();
    let bid_cost = (bid * r) / 1000;
    assert!(coin > bid_cost, 1002);
  }


  #[test(root = @ol_framework)]
  fun audit_happy (root: signer) {

    let set = mock::genesis_n_vals(&root, 4);
    mock::ol_initialize_coin_and_fund_vals(&root, 10000, true);

    let alice = *vector::borrow(&set, 0);

    assert!(stake::is_valid(alice), 1000);
    assert!(!jail::is_jailed(alice), 1001);

    mock_good_bid(&root, &alice);

    let (_err, pass) = proof_of_fee::audit_qualification(alice);
    assert!(pass, 1006);
  }

  #[test(root = @ol_framework)]
  fun meta_get_bidders (root: signer) {
    let set = mock::genesis_n_vals(&root, 4);
    mock::ol_initialize_coin_and_fund_vals(&root, 10000, true);

    let alice = *vector::borrow(&set, 0);

    assert!(!jail::is_jailed(alice), 1001);

    let exclude_bad = true;

    // all bidders will be 4
    let bidders = proof_of_fee::get_bidders(!exclude_bad);
    assert!(vector::length(&bidders) == 4, 1002);

    // filtering for qualified should have no impact, since they all qualify
    let bidders_filtered = proof_of_fee::get_bidders(exclude_bad);
    assert!(vector::length(&bidders_filtered) == 4, 1002);

    // now jail one
    jail::jail(&root, alice);
    assert!(jail::is_jailed(alice), 1002);

    let bidders_filtered = proof_of_fee::get_bidders(exclude_bad);
    assert!(vector::length(&bidders_filtered) == 3, 1003);
  }



  #[test(root = @ol_framework)]
  fun audit_vouch (root: signer) {
    let set = mock::genesis_n_vals(&root, 4);
    mock::ol_initialize_coin_and_fund_vals(&root, 10000, true);

    let alice = *vector::borrow(&set, 0);

    assert!(!jail::is_jailed(alice), 1001);

    mock_good_bid(&root, &alice);

    // need to unset testnet for vouch to be tested
    testnet::unset(&root);

    let val_set = stake::get_current_validators();
    let (frens_in_val_set, _found) = vouch::true_friends_in_list(alice, &val_set);
    let threshold = globals::get_validator_vouch_threshold();
    // ENOUGH VOUCHES
    assert!(vector::length(&frens_in_val_set) > threshold, 1001);

    // assert!(vouch::unrelated_buddies_above_thresh(alice, globals::get_validator_vouch_threshold()), 1001);
    let (_, pass) = proof_of_fee::audit_qualification(alice);
    assert!(pass, 1003);

    vouch::test_set_buddies(alice, vector::empty());

    let val_set = stake::get_current_validators();
    let (frens_in_val_set, _found) = vouch::true_friends_in_list(alice, &val_set);
    let threshold = globals::get_validator_vouch_threshold();
    // TOO few vouches
    assert!(vector::length(&frens_in_val_set) < threshold, 1001);

    let (_, pass) = proof_of_fee::audit_qualification(alice);
    assert!(!pass, 1005);
  }

  #[test(root = @ol_framework)]
  fun audit_no_funds (root: signer) {
    let set = mock::genesis_n_vals(&root, 4);
    let alice = *vector::borrow(&set, 0);

    assert!(!jail::is_jailed(alice), 7357001);
    let a_sig = account::create_signer_for_test(alice);

    let epoch = epoch_helper::get_current_epoch();
    secret_bid::mock_revealed_bid(&root, &a_sig, 100, epoch);
    let bid = secret_bid::get_bid_unchecked(alice);
    assert!(bid == 100, 7357001);

    // NOT ENOUGH FUNDS WERE UNLOCKED
    slow_wallet::slow_wallet_epoch_drip(&root, 500);
    let coin = slow_wallet::unlocked_amount(alice);

    // calculate consensus reward
    proof_of_fee::fill_seats_and_get_price(&root, 4, &set, &set);

    let (r, _, _, _) = proof_of_fee::get_consensus_reward();
    let bid_cost = (bid * r) / 1000;
    assert!(coin < bid_cost, 7357005);

    // should NOT pass audit.
    let (err, pass) = proof_of_fee::audit_qualification(alice);
    assert!(*vector::borrow(&err, 0) == 17, 7357006);
    assert!(!pass, 7357007);
  }

  #[test(root = @ol_framework)]
  fun audit_expired(root: signer) {
    use ol_framework::epoch_helper;
    let set = mock::genesis_n_vals(&root, 7);
    mock::ol_initialize_coin_and_fund_vals(&root, 10000, true);
    let alice = *vector::borrow(&set, 0);

    assert!(!jail::is_jailed(alice), 1001);

    // initially set a good bid
    mock_good_bid(&root, &alice);

    // needs friends
    let (_err, pass) = proof_of_fee::audit_qualification(alice);
    assert!(pass, 1002);

    // we just need to increment for testing expiry
    reconfiguration::test_helper_increment_epoch_dont_reconfigure(1);


    let a_sig = account::create_signer_for_test(alice);

    // set a bid in the past
    secret_bid::mock_revealed_bid(&root, &a_sig, 100, 0);

    let bid = secret_bid::get_bid_unchecked(alice);
    assert!(bid == 100, 1003);

    // should NOT pass audit.
    let (_err, pass) = proof_of_fee::audit_qualification(alice);
    assert!(!pass, 1004);

    // fix it
    let epoch = epoch_helper::get_current_epoch();
    secret_bid::mock_revealed_bid(&root, &a_sig, 100, epoch);


    let (_err, pass) = proof_of_fee::audit_qualification(alice);
    assert!(pass, 1005);

  }

  #[test(root = @ol_framework)]
  fun audit_jail (root: signer) {
    let set = mock::genesis_n_vals(&root, 4);
    mock::ol_initialize_coin_and_fund_vals(&root, 10000, true);

    let alice = *vector::borrow(&set, 0);

    assert!(!jail::is_jailed(alice), 1001);

    mock_good_bid(&root, &alice);

    // EVERYTHING ABOVE HERE IS PASSING.
    // is now jailed.
    jail::jail(&root, alice);
    assert!(jail::is_jailed(alice), 1006);
    // won't pass audit
    let (_, pass) = proof_of_fee::audit_qualification(alice);
    assert!(!pass, 1007);

  }

  #[test(root = @ol_framework)]
  fun sorted_vals_happy(root: signer) {
    let set = mock::genesis_n_vals(&root, 4);
    mock::ol_initialize_coin_and_fund_vals(&root, 10000, true);

    let len = vector::length(&set);
    let i = 0;
    while (i < len) {
      let addr = vector::borrow(&set, i);
      mock_good_bid(&root, addr);
      i = i + 1;
    };
    // mock_good_bid(&root, alice);
    let (val_universe, _their_bids) = mock::pof_default(&root);
    let sorted = proof_of_fee::get_bidders(false);

    let len = vector::length(&sorted);
    assert!(len == vector::length(&val_universe), 1000);
    assert!(vector::length(&sorted) == vector::length(&val_universe), 1002);

    let sorted_two = proof_of_fee::get_bidders(true);
    assert!(vector::length(&sorted_two) == vector::length(&val_universe), 1003);
  }


  #[test(root= @ol_framework)]
  fun sorted_vals_none_qualify(root: signer) {
    let vals = mock::genesis_n_vals(&root, 4);
    let (val_universe, _their_bids) = mock::pof_default(&root);
    // calculate the auction
    proof_of_fee::fill_seats_and_get_price(&root, 4, &vals, &vals);

    let sorted = proof_of_fee::get_bidders(false);

    let len = vector::length(&sorted);
    assert!(len == vector::length(&val_universe), 1000);
    assert!(vector::length(&sorted) == vector::length(&val_universe), 1002);

    let sorted = proof_of_fee::get_bidders(true);
    assert!(vector::length(&sorted) != vector::length(&val_universe), 1003);
    assert!(vector::length(&sorted) == 0, 1004);
  }

  #[test(root = @ol_framework)]
  fun sorted_vals_jail(root: signer) {
    let set = mock::genesis_n_vals(&root, 4);
    mock::ol_initialize_coin_and_fund_vals(&root, 10000, true);

    let len = vector::length(&set);
    let i = 0;
    while (i < len) {
      let addr = vector::borrow(&set, i);
      mock_good_bid(&root, addr);
      i = i + 1;
    };

    // jail alice, the filtered sort should have one less.
    let alice = vector::borrow(&set, 0);
    jail::jail(&root, *alice);

    let (val_universe, _their_bids) = mock::pof_default(&root);


    // let (val_universe, _their_bids, _their_expiry) = mock::pof_default(&root);
    let sorted = proof_of_fee::get_bidders(false);
    let len = vector::length(&sorted);
    assert!(len == vector::length(&val_universe), 1000);
    assert!(vector::length(&sorted) == vector::length(&val_universe), 1002);


    let sorted_two = proof_of_fee::get_bidders(true);
    assert!(vector::length(&sorted_two) != vector::length(&val_universe), 1004);
    assert!(vector::length(&sorted_two) == vector::length(&val_universe) - 1, 1005);

  }


  // Scenario: we are checking that bids expire as the epochs progress.

  #[test(root = @ol_framework)]
  fun sorted_vals_expired_bid(root: signer) {
    let set = mock::genesis_n_vals(&root, 4);
    mock::ol_initialize_coin_and_fund_vals(&root, 10000, true);

    let alice_addr = *vector::borrow(&set, 0);
    let alice_sig = account::create_signer_for_test(alice_addr);
    secret_bid::mock_revealed_bid(&root, &alice_sig, 55, 10);
    assert!(secret_bid::has_valid_bid(alice_addr) == false, 7357001);

    // Get all bidders, but don't run audit
    let sorted = proof_of_fee::get_bidders(false);
    let bids_len = vector::length(&sorted);
    assert!(bids_len == vector::length(&set), 1000);

    // now filter for expired bids, should have one missing
    let sorted_audit = proof_of_fee::get_bidders(true);

    assert!(vector::length(&sorted_audit) != vector::length(&set), 1004);
    assert!(vector::length(&sorted_audit) == vector::length(&set) - 1, 1005);
  }

  // We can send the fill seats function a list of validators, and the list of performing validators, and it will return the winning bidders and the bid.
  #[test(root = @ol_framework)]
  fun fill_seats_happy(root: signer) {
    let set = mock::genesis_n_vals(&root, 5);
    let len = vector::length(&set);
    mock::ol_initialize_coin_and_fund_vals(&root, 500000, true);
    mock::pof_default(&root);

    slow_wallet::slow_wallet_epoch_drip(&root, 500000);

    let sorted = proof_of_fee::get_bidders(true);
    assert!(vector::length(&sorted) == vector::length(&set), 1003);

    let (seats, _, _, _, _) = proof_of_fee::fill_seats_and_get_price(&root, len, &sorted, &sorted);
    assert!(vector::contains(&seats, vector::borrow(&set, 0)), 1004);

    // filling the seat updated the computation of the consensu reward.
    let (reward, _, clear_percent, median_bid) = proof_of_fee::get_consensus_reward();
    assert!(reward == 1000000, 1005);
    assert!(clear_percent == 1, 1006);
    assert!(median_bid == 3, 1007);
  }

  // We fill all the seats, and run the thermostat
  // the thermostat is a noop since there is not enough historical data.
  #[test(root = @ol_framework)]
  fun fill_seats_happy_and_noop_thermostat(root: signer) {
    let set = mock::genesis_n_vals(&root, 5);
    mock::ol_initialize_coin_and_fund_vals(&root, 500000, true);
    mock::pof_default(&root);

    slow_wallet::slow_wallet_epoch_drip(&root, 500000);

    let sorted = proof_of_fee::get_bidders(true);
    assert!(vector::length(&sorted) == vector::length(&set), 1003);

    let len = vector::length(&set);
    let (seats, _, _, _, _) = proof_of_fee::fill_seats_and_get_price(&root, len, &sorted, &sorted);

    assert!(vector::contains(&seats, vector::borrow(&set, 0)), 1004);

    // filling the seat updated the computation of the consensu reward.
    let (reward, _, clear_percent, median_bid) = proof_of_fee::get_consensus_reward();
    assert!(reward == 1000000, 1005);
    assert!(clear_percent == 1, 1006);
    assert!(median_bid == 3, 1007);

    // we expect no change in the reward_thermostat because there haven't been 5 epochs or more of historical data.
    proof_of_fee::reward_thermostat(&root);

    let (reward, _, clearing_percent, median_bid) = proof_of_fee::get_consensus_reward();
    assert!(reward == 1000000, 1008);
    assert!(clearing_percent == 1, 1009);
    assert!(median_bid == 3, 1010);
  }


  // Scenario: Eve does not bid. So we have fewer bidders than seats
  // Otherwise Eve is a performing and valid validator
  // For all lists we are using the validators in the ValidatorUniverse
  // the desired validator set is the same size as the universe.
  // All validators in the universe are properly configured
  // All validators performed perfectly in the previous epoch.
  // They have all placed bids, per TestFixtures::pof_default().

  #[test(root = @ol_framework)]
  fun fill_seats_few_bidders(root: signer) {
    let set = mock::genesis_n_vals(&root, 5);
    mock::ol_initialize_coin_and_fund_vals(&root, 500000, true);
    mock::pof_default(&root);

    // Ok now EVE changes her mind. Will force the bid to expire.
    let a_sig = account::create_signer_for_test(*vector::borrow(&set, 4));
    secret_bid::mock_revealed_bid(&root, &a_sig, 0, 0);
    slow_wallet::slow_wallet_epoch_drip(&root, 500000);

    let sorted = proof_of_fee::get_bidders(true);
    assert!(vector::length(&sorted) != vector::length(&set), 1003);

    // let len = vector::length(&set);
    assert!(vector::length(&set) == 5, 1004);
    assert!(vector::length(&sorted) == 4, 1005);

    let (seats, _, _, _, _) = proof_of_fee::fill_seats_and_get_price(&root, vector::length(&set), &sorted, &sorted);

    // EVE is not in the seats
    assert!(!vector::contains(&seats, vector::borrow(&set, 4)), 1004);
    // Alice is
    assert!(vector::contains(&seats, vector::borrow(&set, 0)), 1005);

    // filling the seat updated the computation of the consensu reward.
    let (reward, _, clear_percent, median_bid) = proof_of_fee::get_consensus_reward();
    assert!(reward == 1000000, 1006);
    assert!(clear_percent == 1, 1007);
    assert!(median_bid == 2, 1008);

  }

// Scenario: We have 5 validators but only 3 seats in the set.
// They have all placed bids, per TestFixtures::pof_default().
// The lowest bidders Alice and Bob, will be excluded.

// For all lists we are using the validators in the ValidatorUniverse
// the desired validator set is the same size as the universe.
// All validators in the universe are properly configured
// All validators performed perfectly in the previous epoch.

  #[test(root = @ol_framework)]
  fun fill_seats_many_bidders(root: signer) {
    let set = mock::genesis_n_vals(&root, 5);
    mock::pof_default(&root);
    mock::ol_initialize_coin_and_fund_vals(&root, 500000, true);

    let sorted = proof_of_fee::get_bidders(true);
    let set_size = 3;
    let (seats, _, _, _, _) = proof_of_fee::fill_seats_and_get_price(&root, set_size, &sorted, &sorted);

    assert!(vector::length(&set) == 5, 1004);
    assert!(vector::length(&seats) == 3, 1005);

     // alice, bob, had low bids, and are out
     // see mock::pof_deault for fibonacci bids
    assert!(!vector::contains(&seats, vector::borrow(&set, 0)), 1001);
    assert!(!vector::contains(&seats, vector::borrow(&set, 1)), 1002);
    // carol, dave, and eve are in
    assert!(vector::contains(&seats, vector::borrow(&set, 2)), 1003);
    assert!(vector::contains(&seats, vector::borrow(&set, 3)), 1004);
    assert!(vector::contains(&seats, vector::borrow(&set, 4)), 1004);

    // filling the seat updated the computation of the consensu reward.
    // Median bids and clearing prices will be different than the happy path test.
    let (reward, _, clear_percent, median_bid) = proof_of_fee::get_consensus_reward();
    assert!(reward == 1000000, 1004);
    assert!(clear_percent == 3, 1005);
    assert!(median_bid == 5, 1006);
  }


  // Scenario: Here we have 6 validators and 6 seats, but only 4 come
  // from the previous epoch.
  // They have all placed bids, per TestFixtures::pof_default().

  // However Alice and Bob have not been in the last epoch's set.
  // So we consider them "unproven".
  // Alice and Bob happen to also be the lowest bidders. But we will
  // seat them, and their bids will count toward getting the clearing price.

  // In this scenario there will be sufficient seats.
  // We will open up 2 seats (1/3 of 6 seats).
  // As such both Eve and Frank should be seated.

  // The clearing price will not change. The lowest is still alice
  // who is also seated.


  // For all lists we are using the validators in the ValidatorUniverse
  // the desired validator set is the same size as the universe.
  // All validators in the universe are properly configured
  // All validators performed perfectly in the previous epoch.

  #[test(root = @ol_framework)]
  fun fill_seats_unproven_happy(root: signer) {
    // we need 6 seats so that we can have 4 proven, and 2 unproven slots
    let set = mock::genesis_n_vals(&root, 6);
    mock::ol_initialize_coin_and_fund_vals(&root, 500000, true);
    mock::pof_default(&root);


    let sorted = proof_of_fee::get_bidders(true);

    let set_size = 6;

    // Alice and Bob were not in the previous round. They are not "proven"
    let proven_vals = vector::singleton(*vector::borrow(&set, 2));
    vector::push_back(&mut proven_vals, *vector::borrow(&set, 3));
    vector::push_back(&mut proven_vals, *vector::borrow(&set, 4));
    vector::push_back(&mut proven_vals, *vector::borrow(&set, 5));

    let (seats, _, _, _, _) = proof_of_fee::fill_seats_and_get_price(&root, set_size, &sorted, &proven_vals);

    assert!(vector::length(&set) == 6, 1004);
    assert!(vector::length(&seats) == 6, 1005);

    // Alice and Bob must be in, even though they were not "proven".
    assert!(vector::contains(&seats, vector::borrow(&set, 0)), 1001);
    assert!(vector::contains(&seats, vector::borrow(&set, 1)), 1002);
    assert!(vector::contains(&seats, vector::borrow(&set, 2)), 1003);


    // filling the seat updated the computation of the consensu reward.
    // Median bids and clearing prices will be different than the happy path test.
    let (reward, _, clear_percent, median_bid) = proof_of_fee::get_consensus_reward();
    assert!(reward == 1000000, 1004);
    // The clearing price is 1, Alice's lowest bid. Even though she was not "proven"
    assert!(clear_percent == 1, 1005);
    assert!(median_bid == 3, 1006);
  }


  // Scenario: Here we have 6 validators and 4 seats, but only 3 come
  // from the previous epoch (proven).
  // This time Eve and Frank are "unproven nodes", they also happen
  // to have the highest bids.
  // They have all placed bids, per TestFixtures::pof_default().

  // At 4 seats, we only have space for 1 unproven node.
  // It should be Frank that gets seated.
  // Eve will not be seated at all, even though she has a higher bid
  // than the proven nodes.

  // The clearing price will not change. The lowest is still Alice
  // who is also seated.

  // For all lists we are using the validators in the ValidatorUniverse
  // the desired validator set is the same size as the universe.
  // All validators in the universe are properly configured
  // All validators performed perfectly in the previous epoch.

  #[test(root = @ol_framework)]
  fun fill_seats_unproven_sad(root: signer) {
    // we need 6 seats so that we can have 4 proven, and 2 unproven slots
    let set = mock::genesis_n_vals(&root, 6);
    mock::ol_initialize_coin_and_fund_vals(&root, 500000, true);
    mock::pof_default(&root);

    let sorted = proof_of_fee::get_bidders(true);

    let set_size = 4;

    // Exclude Eve and Frank were not in the previous round. They are not "proven", but they have the highest bids
    let proven_vals = vector::singleton(Alice);
    vector::push_back(&mut proven_vals, Bob);
    vector::push_back(&mut proven_vals, Carol);
    vector::push_back(&mut proven_vals, Dave);

    let alice_bid = secret_bid::get_bid_unchecked(Alice);
    assert!(alice_bid == 1, 1001);
    let frank_bid = secret_bid::get_bid_unchecked(Frank);
    assert!(alice_bid < frank_bid, 1002);

    let (seats, _, _, _, _) = proof_of_fee::fill_seats_and_get_price(&root, set_size, &sorted, &proven_vals);

    assert!(vector::length(&set) == 6, 1003);
    assert!(vector::length(&seats) == 4, 1004);

    // Alice dropped out, even though was "proven", was the lowest bidder for the three slots for proven, but ALSO lower than the highest bidder of unproven nodes FRANK.
    assert!(!vector::contains(&seats, vector::borrow(&set, 0)), 1006);
    assert!(vector::contains(&seats, vector::borrow(&set, 1)), 1007);
    assert!(vector::contains(&seats, vector::borrow(&set, 2)), 1008);
    assert!(vector::contains(&seats, vector::borrow(&set, 3)), 1009);
    // Eve does not get in. There was only one slot for unproven nodes,
    // and her bid is lower than frank.
    assert!(!vector::contains(&seats, vector::borrow(&set, 4)), 10010);
    assert!(vector::contains(&seats, vector::borrow(&set, 5)), 10011);


    // filling the seat updated the computation of the consensu reward.
    // Median bids and clearing prices will be different than the happy path test.
    let (reward, _, clear_percent, median_bid) = proof_of_fee::get_consensus_reward();
    assert!(reward == 1000000, 10012);
    assert!(clear_percent == 2, 10013);
    assert!(median_bid == 3, 10014);
  }

  // Tests for query_reward_adjustment

  #[test(root = @ol_framework)]
  public fun test_query_reward_adjustment_no_change(root: &signer) {
    use diem_framework::chain_id;
    proof_of_fee::init_genesis_baseline_reward(root);
    chain_id::initialize_for_test(root, 4);

    // 16 entries all with value 600
    let median_history = vector[600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600];
    let nominal_reward = 1000;

    proof_of_fee::test_mock_reward(root, nominal_reward, 500, 500, median_history);

    let (did_run, did_increment, amount) = proof_of_fee::query_reward_adjustment();
    assert!(did_run == true, 7357043);
    assert!(did_increment == false, 7357044);
    assert!(amount == 0, 7357045);
  }

  #[test(root = @ol_framework)]
  public fun test_query_reward_adjustment_increase(root: &signer) {
    use diem_framework::chain_id;
    proof_of_fee::init_genesis_baseline_reward(root);
    chain_id::initialize_for_test(root, 4);

    // 11 entries all with value 400
    let median_history = vector[400, 400, 400, 400, 400, 400, 400, 400, 400, 400, 400];
    let nominal_reward = 1000;

    proof_of_fee::test_mock_reward(root, nominal_reward, 500, 500, median_history);

    let (did_run, did_increment, amount) = proof_of_fee::query_reward_adjustment();
    assert!(did_run == true, 7357046);
    assert!(did_increment == true, 7357047);
    assert!(amount == nominal_reward / 10, 7357048);
  }

  #[test(root = @ol_framework)]
  public fun test_query_reward_adjustment_decrease(root: &signer) {
    use diem_framework::chain_id;
    proof_of_fee::init_genesis_baseline_reward(root);
    chain_id::initialize_for_test(root, 4);

    // 11 entries all with value 960
    let median_history = vector[960, 960, 960, 960, 960, 960, 960, 960, 960, 960, 960];
    let nominal_reward = 1000;

    proof_of_fee::test_mock_reward(root, nominal_reward, 500, 500, median_history);

    let (did_run, did_increment, amount) = proof_of_fee::query_reward_adjustment();
    assert!(did_run == true, 7357049);
    assert!(did_increment == false, 7357050);
    assert!(amount == nominal_reward / 10, 7357051);
  }
  // Tests for fun calculate_min_vouches_required

  #[test(root = @ol_framework)]
  fun test_calculate_min_vouches_required_equal_to_threshold(root: signer) {
    chain_id::initialize_for_test(&root, 1);
    let set_size = 21; // Equal to VAL_BOOT_UP_THRESHOLD
    let min_vouches = proof_of_fee::calculate_min_vouches_required(set_size);
    assert!(min_vouches == 2, 7357001); // Expecting the global threshold value
  }

  #[test(root = @ol_framework)]
  fun test_calculate_min_vouches_required_boundary_over_bootup(root: signer) {
    chain_id::initialize_for_test(&root, 1);

    let set_size = 22; // Boundary condition at 1 over boot-up
    let min_vouches = proof_of_fee::calculate_min_vouches_required(set_size);
    assert!(min_vouches == 3, 7357007); // Expecting dynamic calculation result
  }

  #[test(root = @ol_framework)]
  fun test_calculate_min_vouches_required_boundary_below_bootup(root: signer) {
    chain_id::initialize_for_test(&root, 1);

    let set_size = 20; // Boundary condition at 1 below boot-up
    let min_vouches = proof_of_fee::calculate_min_vouches_required(set_size);
    assert!(min_vouches == 2, 7357008); // Expecting the global threshold value
  }

  #[test(root = @ol_framework)]
  fun test_calculate_min_vouches_required_above_threshold(root: signer) {
    chain_id::initialize_for_test(&root, 1);

    let set_size = 29;
    let min_vouches = proof_of_fee::calculate_min_vouches_required(set_size);
    assert!(min_vouches == 3, 7357010); // Expecting dynamic calculation result

    let set_size = 30;
    let min_vouches = proof_of_fee::calculate_min_vouches_required(set_size);
    assert!(min_vouches == 4, 7357011); // Expecting dynamic calculation result

    let set_size = 31;
    let min_vouches = proof_of_fee::calculate_min_vouches_required(set_size);
    assert!(min_vouches == 4, 7357012); // Expecting dynamic calculation result
  }

  #[test(root = @ol_framework)]
  fun test_calculate_min_vouches_required_min_set_size(root: signer) {
    chain_id::initialize_for_test(&root, 1);

    let set_size = 0; // Smallest possible set size
    let min_vouches = proof_of_fee::calculate_min_vouches_required(set_size);
    assert!(min_vouches == 2, 7357003); // Expecting the global threshold value
  }

  #[test(root = @ol_framework)]
  fun test_calculate_min_vouches_required_max_set_size(root: signer) {
    chain_id::initialize_for_test(&root, 1);

    let set_size = 10_000; // Very large set size
    let min_vouches = proof_of_fee::calculate_min_vouches_required(set_size);
    assert!(min_vouches == 8, 7357004); // Expecting max vouches minus margin
  }

  #[test(root = @ol_framework)]
  fun test_calculate_min_vouches_required_exact_match(root: signer) {
    chain_id::initialize_for_test(&root, 1);

    let set_size = 78; // Exact calculation match case
    let min_vouches = proof_of_fee::calculate_min_vouches_required(set_size);
    assert!(min_vouches == 8, 7357005); // Expecting max vouches minus margin
  }

  #[test(root = @ol_framework)]
  fun test_calculate_min_vouches_required_edge_vouch_margin(root: signer) {
    chain_id::initialize_for_test(&root, 1);

    let set_size = 80; // Edge case at vouch margin
    let min_vouches = proof_of_fee::calculate_min_vouches_required(set_size);
    assert!(min_vouches == 8, 7357006); // Expecting max vouches minus margin
  }
}
