
#[test_only]
/// tests for external apis, and where a dependency cycle with genesis is created.
module ol_framework::test_reconfiguration {
  use std::vector;
  use diem_framework::stake;
  // use diem_framework::transaction_fee;
  use ol_framework::mock::{Self, default_tx_fee_account_at_genesis};
  use ol_framework::testnet;
  use ol_framework::libra_coin;
  use ol_framework::proof_of_fee;
  use diem_framework::reconfiguration;
  use ol_framework::epoch_helper;
  use ol_framework::ol_account;

  // use diem_std::debug::print;

  // Scenario: all genesis validators make it to next epoch
  #[test(root = @ol_framework)]
  fun reconfig_reward_happy_case(root: signer) {
    let _vals = mock::genesis_n_vals(&root, 5);

    let starting_balance = 500_000;
    mock::ol_initialize_coin_and_fund_vals(&root, starting_balance, false);
    mock::mock_tx_fees_in_account(&root, default_tx_fee_account_at_genesis());

    let (reward_one, genesis_entry_fee, _, _ ) = proof_of_fee::get_consensus_reward();
    // entry fee at genesis is zero
    assert!(genesis_entry_fee == 0, 7357004);

    // The epoch's reward BEFORE reconfiguration
    assert!(reward_one == 1_000_000, 7357004);

    // run ol reconfiguration
    mock::trigger_epoch(&root);

    // magic: in test mode and under block 100 all validators perform
    let vals = stake::get_current_validators();
    assert!(vector::length(&vals) == 5, 7357005);

    let (_unlocked, alice_bal) = ol_account::balance(@0x1000a);

    let (_, entry_fee, _,  _ ) = proof_of_fee::get_consensus_reward();

    // need to check that the user paid an PoF entry fee for next epoch.
    // which means the balance will be:
    //  the nominal reward minus, entry fee (clearing price), plus any existing balance.
    assert!(alice_bal == (reward_one - entry_fee + starting_balance), 7357006);

  }

  #[test(root = @ol_framework)]
  fun drop_non_performing(root: signer) {
    let vals = mock::genesis_n_vals(&root, 5);
    let alice = *vector::borrow(&vals, 0);

    assert!(libra_coin::balance(alice) == 0, 7357000);

    // NOTE: epoch 0 and 1 are a special case, we don't run performance grades on that one. Need to move two epochs ahead
    reconfiguration::test_helper_increment_epoch_dont_reconfigure(1);
    reconfiguration::test_helper_increment_epoch_dont_reconfigure(1);

    // epoch changed, need new valid bids
    mock::pof_default(&root);

    assert!(epoch_helper::get_current_epoch() == 2, 7357001);

    let vals = stake::get_current_validators();
    assert!(vector::length(&vals) == 5, 7357002);

    // all vals compliant
    mock::mock_all_vals_good_performance(&root);
    // make alice non performant
    mock::mock_case_4(&root, alice);

    // run ol reconfiguration
    mock::trigger_epoch(&root);


    // one validator missing.
    let vals = stake::get_current_validators();
    assert!(vector::length(&vals) == 4, 7357003);
    assert!(!vector::contains(&vals, &alice), 7357004);

  }


  // Scenario: no vals qualify, but we failover with same validtors
  // need to unset testnet id, since the failover only applies to non-testnet
  #[test(root = @ol_framework)]
  fun reconfig_failover(root: signer) {
      let vals = mock::genesis_n_vals(&root, 5);
      mock::pof_default(&root);

      // validators did not perform.
      let i = 0;
      while (i < vector::length(&vals)) {
        mock::mock_case_4(&root, *vector::borrow(&vals, i));
        i = i + 1;
      };

      testnet::unset(&root); // note: needs to happen after genesis.

      // run ol reconfiguration
      mock::trigger_epoch(&root);

      let vals = stake::get_current_validators();

      assert!(vector::length(&vals) == 5, 7357003);
  }
}
