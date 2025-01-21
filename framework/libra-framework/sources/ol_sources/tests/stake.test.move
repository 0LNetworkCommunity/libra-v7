#[test_only]
/// tests for external apis, and where a dependency cycle with genesis is created.
module ol_framework::test_stake {
  use ol_framework::mock;
  use std::vector;
  use ol_framework::stake;
  use ol_framework::testnet;
  use ol_framework::grade;

  //use diem_std::debug::print;

  // Scenario: can take 6 already initialized validators, from a previous set
  // and reduce the set to 3 of those validators.
  #[test(root = @ol_framework)]
  fun bulk_update_validators(root: signer) {
    let set = mock::genesis_n_vals(&root, 6);
    let alice = vector::borrow(&set, 0);
    assert!(stake::is_valid(*alice), 1000);

    let vals = stake::get_current_validators();
    assert!(vector::length(&vals) == 6, 1001);

    let all_vals = mock::personas();

    let new_list = vector::empty<address>();
    let i = 0;
    while (i < 3) {
      vector::push_back(&mut new_list, *vector::borrow(&all_vals, i));
      i = i + 1;
    };

    let (cfg_list, _weight, _) = stake::test_make_val_cfg(&new_list);


    stake::test_set_next_vals(&root, cfg_list);

    let vals = stake::get_current_validators();
    assert!(vector::length(&vals) == 3, 1001);

  }

  // Scenario: in production mode, we can't have fewer than 4 validators,
  // and we also want to target a minimum of 9 validators
  // within these ranges we have different rules to recover.
  #[test(root = @ol_framework)]
  fun failover_scenarios(root: signer) {
    use diem_framework::randomness;
    randomness::initialize_for_testing(&root);

    let set = mock::genesis_n_vals(&root, 10);
    testnet::unset(&root); // set to production mode

    let alice = vector::borrow(&set, 0);
    assert!(stake::is_valid(*alice), 1000);

    let vals = stake::get_current_validators();
    assert!(vector::length(&vals) == 10, 1001);

    // A) Happy cases:
    // we are proposing more than the minimum (9) for failover rules
    // first case:
    // there are more seats (11) offered than qualified validators (10)
    // should return 10
    let proposed = vals;
    let cfg_list = stake::check_failover_rules(proposed, 11);
    assert!(vector::length(&cfg_list) == 10, 1002);
    // second case:
    // number of seats has no effect, as long as proposed in above mininum for
    // happy case(9).
    let cfg_list = stake::check_failover_rules(proposed, 2);
    assert!(vector::length(&cfg_list) == 10, 1003);

    // B) Sick Patient cases (less than 9 total proposed)
    vector::pop_back(&mut proposed);
    vector::pop_back(&mut proposed);
    vector::pop_back(&mut proposed);
    assert!(vector::length(&proposed) == 7, 1004);

    // First case: We qualified fewer vals (7) than our theshhold (10). The
    // number of seats (7) is same as qualifying (the typical case)
    let cfg_list = stake::check_failover_rules(proposed, 7);
    assert!(vector::length(&cfg_list) == 7, 1005);

    // Second case: we have more qualified vals (7) than we intended to seat (6)
    // but it's all below our minimum (9). Take everyone that qualified.
    // This case is likely a bug
    let cfg_list = stake::check_failover_rules(proposed, 6);
    assert!(vector::length(&cfg_list) == 7, 1006);

    // C) Defibrillator
    // First case: we are not qualifying enough validators to stay alive
    // let's check we can get at least up to the number of seats offered
    let cfg_list = stake::check_failover_rules(proposed, 8);
    assert!(vector::length(&cfg_list) == 8, 1007);

    // Second case : we are not qualifying enough validators to stay alive
    // but the seats proposed is unrealistic. Let's just get back to a healthy
    let cfg_list = stake::check_failover_rules(proposed, 50);
    assert!(vector::length(&cfg_list) == 9, 1008);

    // even an empty list, but with seats to fill will work
    let cfg_list = stake::check_failover_rules(vector::empty(), 8);
    assert!(vector::length(&cfg_list) == 8, 1004);

    // If we are below threshold, we will only grow the set the minimum to stay
    // health (9), even if musical chairs picked more (12). (Though this case should
    // never happen)
    let cfg_list = stake::check_failover_rules(vector::empty(), 12);
    assert!(vector::length(&cfg_list) == 9, 1009);

    // D) Hail Mary. If nothing we've done gets us above 4 proposed validators,
    // then don't change anything.
    let cfg_list = stake::check_failover_rules(vector::empty(), 0);
    assert!(vector::length(&cfg_list) == 4, 1010);

    // Other corner cases
    // musical chairs fails, but we have a list of qualifying validators
    // above threshold
    let cfg_list = stake::check_failover_rules(vals, 2);
    assert!(vector::length(&cfg_list) == 10, 1011);
  }

  // Scenario: in production mode, we can't have fewer than 4 validators.
  // when that happens, the first failover is to get the validators with the most successful proposals.
  #[test(root = @ol_framework)]
  fun sorted_vals_by_props(root: signer) {

    let set = mock::genesis_n_vals(&root, 8);
    testnet::unset(&root); // set to production mode

    let alice = vector::borrow(&set, 0);
    assert!(stake::is_valid(*alice), 1000);

    let vals = stake::get_current_validators();
    assert!(vector::length(&vals) == 8, 1001);

    let i = 0;
    while (i < vector::length(&set)) {
      let addr = vector::borrow(&set, i);
      stake::mock_performance(&root, *addr, i, 0); // increasing performance for each
      i = i + 1;
    };

    let cfg_list = stake::get_sorted_vals_by_net_props();

    // assert!(vector::length(&cfg_list) == 3, 1002);
    let (_, idx_best) = vector::index_of(&cfg_list, &@0x10011);
    let (_, idx_alice) = vector::index_of(&cfg_list, &@0x1000a);


    assert!(idx_best < idx_alice, 1002); // alice has lower performance, should
    // come later in the list
  }


  // Scenario: in production mode, we can't have fewer than 4 validators.
  // if we try to pass less, no change will happen (does not abort)
  #[test(root = @ol_framework)]
  fun jail_list(root: signer) {

    mock::genesis_n_vals(&root, 6);
    mock::mock_all_vals_good_performance(&root);
    // all validators bid
    mock::pof_default(&root);

    // now make Eve not compliant
    let eve = @0x1000e;
    mock::mock_case_4(&root, eve);
    let (compliant, _, _) = grade::get_validator_grade(eve);
    assert!(!compliant, 735701);

  }

  // Scenario: There's one validator that is a straggler
  // that validator should be dropped when we "grade"
  // the validators.
  // The validator has an acceptable success ratio
  #[test(root = @ol_framework)]
  fun drop_trailing(root: signer) {

    let set = mock::genesis_n_vals(&root, 8);
    testnet::unset(&root); // set to production mode

    let default_valid_props = 500;
    // populate some performance
    let i = 0;
    while (i < vector::length(&set)) {
      let addr = vector::borrow(&set, i);

      let valid_props =  default_valid_props; // make all validators have
      let invalid_props = 1;

      stake::mock_performance(&root, *addr, valid_props, invalid_props); //
      // increasing performance for each
      i = i + 1;
    };

    // set alice to be "trailing"
    // this will be less than 5% of the leading validator
    stake::mock_performance(&root, @0x1000a, 5, 1);
    stake::mock_performance(&root, @0x10011, 1000, 1);

    let (highest_score, _addr) = stake::get_highest_net_proposer();

    // LOWEST TRAILING VALIDATOR WILL BE OUT
    let lowest_score = stake::get_val_net_proposals(@0x1000a);

    assert!(highest_score > (lowest_score*20), 7357001);
    let (a, _, _) = grade::get_validator_grade(@0x1000a);
    assert!(a == false, 73570002);

    // Second lowest is fine
    let (b, _, _) = grade::get_validator_grade(@0x1000c);
    assert!(b == true, 73570003);

    // and top is also fine
    let (top, _, _) = grade::get_validator_grade(@0x10011);
    assert!(top == true, 73570004);

  }

  // Scenario: one validator has too many failing
  // proposals as a ratio to successful ones.
  #[test(root = @ol_framework)]
  fun drop_low_performance_ratio(root: signer) {

    let set = mock::genesis_n_vals(&root, 8);
    testnet::unset(&root); // set to production mode

    let default_valid_props = 500;
    // populate some performance
    let i = 0;
    while (i < vector::length(&set)) {
      let addr = vector::borrow(&set, i);

      let valid_props =  default_valid_props; // make all validators have
      let invalid_props = 1;

      stake::mock_performance(&root, *addr, valid_props, invalid_props); //
      // increasing performance for each
      i = i + 1;
    };

    // alice is NOT trailing in proposals
    // but the percent of failed proposals are too high
    // above 10%
    // in this example 40% failing proposals
    stake::mock_performance(&root, @0x1000a, 500, 200);

    // Lots of failing proposals will make you drop out
    let (a, _, _) = grade::get_validator_grade(@0x1000a);
    assert!(a == false, 73570002);

    // Other accounts are ok
    let (b, _, _) = grade::get_validator_grade(@0x1000c);
    assert!(b == true, 73570003);

  }


}
