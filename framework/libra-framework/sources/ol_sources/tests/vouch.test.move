#[test_only]
module ol_framework::test_vouch {
  use std::vector;
  use ol_framework::vouch;
  use ol_framework::mock;
  use ol_framework::proof_of_fee;

  // use diem_std::debug::print;

  // Happy Day scenarios

  #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c)]
  fun vouch_for_unrelated(root: &signer, alice: &signer, carol: &signer) {
    // create vals without vouches
    mock::create_vals(root, 3, false);
    vouch::set_vouch_price(root, 0);

    // check that no vouches exist
    vector::for_each(vector[@0x1000a, @0x1000b, @0x1000c], |addr| {
      let (given_vouches, given_epochs) = vouch::get_given_vouches(addr);
      assert!(given_vouches == vector::empty(), 73570001);
      assert!(given_epochs == vector::empty(), 73570002);
      let (received_vouches, received_epochs) = vouch::get_received_vouches(addr);
      assert!(received_vouches == vector::empty(), 73570003);
      assert!(received_epochs == vector::empty(), 73570004);
    });

    // alice vouches for bob
    vouch::vouch_for(alice, @0x1000b);

    // check alice
    let (given_vouches, given_epochs) = vouch::get_given_vouches(@0x1000a);
    assert!(given_vouches == vector[@0x1000b], 73570005);
    assert!(given_epochs == vector[0], 73570006);

    // check bob
    let (received_vouches, received_epochs) = vouch::get_received_vouches(@0x1000b);
    assert!(received_vouches == vector[@0x1000a], 73570007);
    assert!(received_epochs == vector[0], 73570008);

    // fast forward to epoch 1
    mock::trigger_epoch(root);

    vouch::set_vouch_price(root, 0);

    // carol vouches for bob
    vouch::vouch_for(carol, @0x1000b);

    // check alice
    let (given_vouches, given_epochs) = vouch::get_given_vouches(@0x1000a);
    assert!(given_vouches == vector[@0x1000b], 73570005);
    assert!(given_epochs == vector[0], 73570006);

    // check carol
    let (given_vouches, given_epochs) = vouch::get_given_vouches(@0x1000c);
    assert!(given_vouches == vector[@0x1000b], 73570009);
    assert!(given_epochs == vector[1], 73570010);

    // check bob
    let (received_vouches, received_epochs) = vouch::get_received_vouches(@0x1000b);
    assert!(received_vouches == vector[@0x1000a, @0x1000c], 73570011);
    assert!(received_epochs == vector[0, 1], 73570012);
  }

  #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c)]
  fun revoke_vouch(root: &signer, alice: &signer, carol: &signer) {
    // create vals without vouches
    mock::create_vals(root, 3, false);
    vouch::set_vouch_price(root, 0);

    // alice and carol vouches for bob
    vouch::vouch_for(alice, @0x1000b);
    vouch::vouch_for(carol, @0x1000b);

    // alice revokes vouch for bob
    vouch::revoke(alice, @0x1000b);

    // check alice
    let (given_vouches, given_epochs) = vouch::get_given_vouches(@0x1000a);
    assert!(given_vouches == vector::empty(), 73570013);
    assert!(given_epochs == vector::empty(), 73570014);

    // check bob
    let (received_vouches, received_epochs) = vouch::get_received_vouches(@0x1000b);
    assert!(received_vouches == vector[@0x1000c], 73570015);
    assert!(received_epochs == vector[0], 73570016);
  }

  #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c)]
  fun epoch_boundary_update_vouch_price(root: &signer) {
    // check default vouch micro-price
    assert!(vouch::get_vouch_price() == 1_000, 73570025);

    // initialize vals and vouch price
    mock::genesis_n_vals(root, 3);
    vouch::set_vouch_price(root, 0);
    assert!(vouch::get_vouch_price() == 0, 73570025);

    // mock to increase reward on the next epoch
    proof_of_fee::test_mock_reward(root, 5_000, 1_000, 10, vector[10, 10, 10, 10, 10, 10]);
    let (reward, _, _, _ ) = proof_of_fee::get_consensus_reward();
    assert!(reward == 5_000, 73570026);

    mock::trigger_epoch(root);

    // check new vouch price
    let (reward, _, _, _ ) = proof_of_fee::get_consensus_reward();
    assert!(reward == 5_250, 73570027);
    assert!(vouch::get_vouch_price() == 5_250, 73570026);

    mock::trigger_epoch(root);

    // check new vouch price
    let (reward, _, _, _ ) = proof_of_fee::get_consensus_reward();
    assert!(reward == 5_512, 73570027);
    assert!(vouch::get_vouch_price() == 5_512, 73570026);

    // mock to descrease reward on the next epoch
    proof_of_fee::test_mock_reward(root, 10_000, 9_600, 960, vector[960, 960, 960, 960, 960, 960]);

    mock::trigger_epoch(root);

    // check new vouch price
    let (reward, _, _, _ ) = proof_of_fee::get_consensus_reward();
    assert!(reward == 9_500, 73570026);
    assert!(vouch::get_vouch_price() == 9_500, 73570027);
  }

  #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b)]
  fun update_vouch(root: &signer, alice: &signer) {
    // create vals without vouches
    mock::create_vals(root, 2, false);
    vouch::set_vouch_price(root, 0);

    // alice vouches for bob
    vouch::vouch_for(alice, @0x1000b);

    // check alice
    let (given_vouches, given_epochs) = vouch::get_given_vouches(@0x1000a);
    assert!(given_vouches == vector[@0x1000b], 73570005);
    assert!(given_epochs == vector[0], 73570006);

    // check bob
    let (received_vouches, received_epochs) = vouch::get_received_vouches(@0x1000b);
    assert!(received_vouches == vector[@0x1000a], 73570007);
    assert!(received_epochs == vector[0], 73570008);

    // fast forward to epoch 1
    mock::trigger_epoch(root);

    vouch::set_vouch_price(root, 0);

    // alice vouches for bob again
    vouch::vouch_for(alice, @0x1000b);

    // check alice
    let (given_vouches, given_epochs) = vouch::get_given_vouches(@0x1000a);
    assert!(given_vouches == vector[@0x1000b], 73570005);
    assert!(given_epochs == vector[1], 73570006);

    // check bob
    let (received_vouches, received_epochs) = vouch::get_received_vouches(@0x1000b);
    assert!(received_vouches == vector[@0x1000a], 73570007);
    assert!(received_epochs == vector[1], 73570008);
  }

  // Sad Day scenarios

  #[test(root = @ol_framework, alice = @0x1000a)]
  #[expected_failure(abort_code = 0x10001, location = ol_framework::vouch)]
  fun vouch_for_self(root: &signer, alice: &signer) {
    // create vals without vouches
    mock::create_vals(root, 1, false);
    vouch::set_vouch_price(root, 0);

    // alice vouches for herself
    vouch::vouch_for(alice, @0x1000a);
  }

  #[test(root = @ol_framework, alice = @0x1000a)]
  #[expected_failure(abort_code = 0x10001, location = ol_framework::vouch)]
  fun revoke_self_vouch(root: &signer, alice: &signer) {
    // create vals without vouches
    mock::create_vals(root, 1, false);

    // alice try to revoke herself
    vouch::revoke(alice, @0x1000a);
  }

  #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b)]
  #[expected_failure(abort_code = 0x10005, location = ol_framework::vouch)]
  fun revoke_not_vouched(root: &signer, alice: &signer) {
    // create vals without vouches
    mock::create_vals(root, 2, false);

    // alice vouches for bob
    vouch::revoke(alice, @0x1000b);
  }

  #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, v1 = @0x10001, v2 = @0x10002, v3 = @0x10003, v4 = @0x10004, v5 = @0x10005, v6 = @0x10006, v7 = @0x10007, v8 = @0x10008, v9 = @0x10009, v10 = @0x10010)]
  #[expected_failure(abort_code = 0x30004, location = ol_framework::vouch)]
  fun vouch_over_max(root: &signer, alice: &signer, v1: &signer, v2: &signer, v3: &signer, v4: &signer, v5: &signer, v6: &signer, v7: &signer, v8: &signer, v9: &signer, v10: &signer) {
    // create vals without vouches
    mock::create_vals(root, 2, false);
    vouch::set_vouch_price(root, 0);

    // init vouch for 10 validators
    vouch::init(v1);
    vouch::init(v2);
    vouch::init(v3);
    vouch::init(v4);
    vouch::init(v5);
    vouch::init(v6);
    vouch::init(v7);
    vouch::init(v8);
    vouch::init(v9);
    vouch::init(v10);

    // alice vouches for 10 validators
    vouch::insist_vouch_for(alice, @0x10001);
    vouch::insist_vouch_for(alice, @0x10002);
    vouch::insist_vouch_for(alice, @0x10003);
    vouch::insist_vouch_for(alice, @0x10004);
    vouch::insist_vouch_for(alice, @0x10005);
    vouch::insist_vouch_for(alice, @0x10006);
    vouch::insist_vouch_for(alice, @0x10007);
    vouch::insist_vouch_for(alice, @0x10008);
    vouch::insist_vouch_for(alice, @0x10009);
    vouch::insist_vouch_for(alice, @0x10010);

    // alice try to vouch for one more
    vouch::insist_vouch_for(alice, @0x1000b);

    // check alice
    let (given_vouches, given_epochs) = vouch::get_given_vouches(@0x1000a);
    assert!(given_vouches == vector[@0x10001, @0x10002, @0x10003, @0x10004, @0x10005, @0x10006, @0x10007, @0x10008, @0x10009, @0x10010], 73570017);
    assert!(given_epochs == vector[0, 0, 0, 0, 0, 0, 0, 0, 0, 0], 73570018);

    // check bob
    let (received_vouches, received_epochs) = vouch::get_received_vouches(@0x1000b);
    assert!(received_vouches == vector::empty(), 73570019);
    assert!(received_epochs == vector::empty(), 73570020);
  }

  #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b)]
  #[expected_failure(abort_code = 0x30006, location = ol_framework::ol_account)]
  fun vouch_without_coins(root: &signer, alice: &signer) {
    // create vals without vouches
    mock::create_vals(root, 2, false);
    vouch::set_vouch_price(root, 9_999);

    // alice vouches for bob without coins
    vouch::vouch_for(alice, @0x1000b);

    // check alice
    let (given_vouches, given_epochs) = vouch::get_given_vouches(@0x1000a);
    assert!(given_vouches == vector::empty(), 73570021);
    assert!(given_epochs == vector::empty(), 73570022);

    // check bob
    let (received_vouches, received_epochs) = vouch::get_received_vouches(@0x1000b);
    assert!(received_vouches == vector::empty(), 73570023);
    assert!(received_epochs == vector::empty(), 73570024);
  }

  #[test(root = @ol_framework, alice = @0x1000a)]
  #[expected_failure(abort_code = 0x30006, location = ol_framework::vouch)]
  fun vouch_without_init(alice: &signer) {
    // alice vouches for bob without init
    vouch::vouch_for(alice, @0x1000b);
  }

  #[test(root = @ol_framework, alice = @0x1000a)]
  #[expected_failure(abort_code = 0x30002, location = ol_framework::vouch)]
  fun vouch_for_account_not_init(root: &signer, alice: &signer) {
    mock::create_vals(root, 1, false);

    // alice vouches for bob without init
    vouch::vouch_for(alice, @0x1000b);
  }

  #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b)]
  #[expected_failure(abort_code = 0x30006, location = ol_framework::vouch)]
  fun revoke_without_init(alice: &signer) {
    // alice try to revoke bob without vouch
    vouch::revoke(alice, @0x1000b);
  }

  #[test(root = @ol_framework, alice = @0x1000a)]
  #[expected_failure(abort_code = 0x10005, location = ol_framework::vouch)]
  fun revoke_account_not_vouched(root: &signer, alice: &signer) {
    mock::create_vals(root, 2, false);

    // alice try to revoke bob without vouch
    vouch::revoke(alice, @0x1000b);
  }


  #[test(root = @ol_framework, alice = @0x1000a)]
  fun true_friends_not_init() {
    // alice try to get true friends in list without init
    let result = vouch::true_friends(@0x1000a);

    assert!(result == vector::empty(), 73570028);
  }

  #[test(root = @ol_framework, alice = @0x1000a)]
  fun true_friends_in_list_not_init() {
    // alice try to get true friends in list without init
    let (list, size) = vouch::true_friends_in_list(@0x1000a, &vector::singleton(@0x1000b));

    assert!(list == vector::empty(), 73570028);
    assert!(size == 0, 73570029);
  }

  #[test(root = @ol_framework, alice = @0x1000a)]
  fun get_received_vouches_not_init() {
    // alice try to get received vouches without init
    let (received_vouches, received_epochs) = vouch::get_received_vouches(@0x1000a);

    assert!(received_vouches == vector::empty(), 73570030);
    assert!(received_epochs == vector::empty(), 73570031);
  }

  #[test(root = @ol_framework, alice = @0x1000a)]
  #[expected_failure(abort_code = 0x30003, location = ol_framework::vouch)]
  fun get_given_vouches_not_init() {
    // alice try to get given vouches without init
    vouch::get_given_vouches(@0x1000a);
  }

  #[test(root = @ol_framework, alice = @0x1000a)]
  fun get_all_vouchers_not_init() {
    // alice try to get all vouchers without init
    let all_vouchers = vouch::all_vouchers(@0x1000a);

    assert!(all_vouchers == vector::empty(), 73570034);
  }

}
