
#[test_only]
module ol_framework::test_burn {
  use ol_framework::mock::{Self, default_epoch_reward, default_final_supply_at_genesis, default_entry_fee, default_tx_fee_account_at_genesis};
  use ol_framework::libra_coin;
  use ol_framework::ol_account;
  use ol_framework::match_index;
  use ol_framework::burn;
  use ol_framework::receipts;
  use ol_framework::community_wallet_init;
  use ol_framework::transaction_fee;
  use ol_framework::fee_maker;
  use diem_framework::coin;
  use std::signer;
  use std::vector;
  use std::option;
  use std::fixed_point32;

  // use diem_std::debug::print;

  #[test(root = @ol_framework, alice = @0x1000a)]
  fun burn_reduces_supply(root: &signer, alice: &signer) {
    mock::genesis_n_vals(root, 1);
    mock::ol_initialize_coin_and_fund_vals(root, 10000, true);
    let supply_pre = libra_coin::supply();

    let alice_burn = 5;
    let c = ol_account::withdraw(alice, alice_burn);
    burn::burn_and_track(c);
    let supply = libra_coin::supply();
    assert!(supply == (supply_pre - alice_burn), 7357001);
  }

  // burn changes indexed real_balance
  #[test(root = @ol_framework, alice = @0x1000a)]
  fun burn_changes_real_balance(root: &signer, alice: &signer) {
    mock::genesis_n_vals(root, 1);
    // the mint to alice will double the supply
    mock::ol_initialize_coin_and_fund_vals(root, 100000000, true);

    let supply_pre = libra_coin::supply();
    // need to adjust this since the validator init increased the supply above
    // the final
    libra_coin::test_set_final_supply(root, supply_pre);
    let final = libra_coin::get_final_supply();
    assert!(supply_pre == final, 7357000);
    // no change should happen before any burns
    let (unlocked, total) = ol_account::balance(@0x1000a);
    let (real_unlocked, real_total) = ol_account::real_balance(@0x1000a);
    assert!(real_unlocked == unlocked, 7357001);
    assert!(real_total == total, 7357002);

    // burn half of alices coins, which is 25% of the supply
    let alice_burn = 50000000;


    let c = ol_account::withdraw(alice, alice_burn);
    burn::burn_and_track(c);
    let supply = libra_coin::supply();
    assert!(supply == (supply_pre - alice_burn), 7357003);

    let (unlocked, total) = ol_account::balance(@0x1000a);
    let (real_unlocked, real_total) = ol_account::real_balance(@0x1000a);
    assert!(real_unlocked > unlocked, 7357004);
    assert!(real_total > total, 7357005);
  }


  #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000d, eve = @0x1000e)]
  fun burn_to_match_index(root: &signer, alice: &signer, bob: &signer, eve: &signer) {
    // Scenario:
    // There are two community wallets. Alice and Bob's
    // EVE donates to both. But mostly to Alice.
    // The Match Index, should reflect that.

    let vals = mock::genesis_n_vals(root, 5); // need to include eve to init funds)

    mock::ol_initialize_coin_and_fund_vals(root, default_epoch_reward(), true);
    // start at epoch 1, since turnout tally needs epoch info, and 0 may cause issues
    mock::trigger_epoch(root);

    let (communityA, _cap) = ol_account::test_ol_create_resource_account(alice, b"0x1");
    let addr_A = signer::address_of(&communityA);
    community_wallet_init::init_community(&communityA, vals, 2); // make all the vals signers

    let (communityB, _cap) = ol_account::test_ol_create_resource_account(bob, b"0xdeadbeef");
    let addr_B = signer::address_of(&communityB);
    community_wallet_init::init_community(&communityB, vals, 2); // make all the vals signers

    let eve_donation_to_A = 75;
    ol_account::transfer(eve, addr_A, eve_donation_to_A);
    let (_, _, total_funds_sent_by_eve) = receipts::read_receipt(signer::address_of(eve), addr_A);
    assert!(total_funds_sent_by_eve == eve_donation_to_A, 7357001);

    let eve_donation_to_B = 25;
    ol_account::transfer(eve, addr_B, eve_donation_to_B);
    let (_, _, total_funds_sent_by_eve) = receipts::read_receipt(signer::address_of(eve), addr_B);
    assert!(total_funds_sent_by_eve == eve_donation_to_B, 7357002);

    let qualifying = vector::singleton(addr_A);
    vector::push_back(&mut qualifying, addr_B);

    // simulate index recalculation at epoch boundary
    match_index::test_reset_ratio(root, qualifying);
    let (_addrs_vec, _index_vec, ratio_vec) = match_index::get_ratios();

    // so far addr_A should have 75 coins from Eve's transfer
    let(_, balance_pre) = ol_account::balance(addr_A);
    assert!(balance_pre == eve_donation_to_A, 7357003);

    // let's burn some of bob's coins
    // first he sets his burn preference
    burn::set_send_community(bob, true);
    let bob_burn = 100000;
    let c = ol_account::withdraw(bob, bob_burn);
    // then the system burns based on his preference.
    burn::test_vm_burn_with_user_preference(root, signer::address_of(bob), c);
    // check that a recycle to match index happened instead of a straight burn
    let (_lifetime_burn, lifetime_match) = burn::get_lifetime_tracker();
    assert!(lifetime_match > 0, 7357003);


    // the balance of address A should be increase by the ratio above 75% *  bob's burn of 100_000
    let ratio_A = vector::borrow(&ratio_vec, 0);
    let bob_burn_share_A = fixed_point32::multiply_u64(bob_burn, *ratio_A);

    let(_, balance) = ol_account::balance(addr_A);
    assert!(balance > balance_pre, 7357004);
    assert!(balance == (bob_burn_share_A + eve_donation_to_A), 7357005);
  }


  #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000d, eve = @0x1000e)]
  fun simple_burn(root: &signer, alice: &signer, bob: &signer, eve: &signer) {
    // Scenario:
    // There are two community wallets. Alice and Bob's
    // EVE donates to both. But mostly to Alice.
    // The Match Index, should reflect that.

    let vals = mock::genesis_n_vals(root, 5); // need to include eve to init funds
    mock::ol_initialize_coin_and_fund_vals(root, default_epoch_reward(), true);
    // start at epoch 1, since turnout tally needs epoch info, and 0 may cause issues
    mock::trigger_epoch(root);

    let (communityA, _cap) = ol_account::test_ol_create_resource_account(alice, b"0x1");
    let addr_A = signer::address_of(&communityA);
    community_wallet_init::init_community(&communityA, vals, 2); // make all the vals signers

    let (communityB, _cap) = ol_account::test_ol_create_resource_account(bob, b"0xdeadbeef");
    let addr_B = signer::address_of(&communityB);
    community_wallet_init::init_community(&communityB, vals, 2); // make all the vals signers

    let eve_donation_to_A = 75;
    ol_account::transfer(eve, addr_A, eve_donation_to_A);
    let (_, _, total_funds_sent_by_eve) = receipts::read_receipt(signer::address_of(eve), addr_A);
    assert!(total_funds_sent_by_eve == eve_donation_to_A, 7357001);

    let eve_donation_to_B = 25;
    ol_account::transfer(eve, addr_B, eve_donation_to_B);
    let (_, _, total_funds_sent_by_eve) = receipts::read_receipt(signer::address_of(eve), addr_B);
    assert!(total_funds_sent_by_eve == eve_donation_to_B, 7357002);

    let qualifying = vector::singleton(addr_A);
    vector::push_back(&mut qualifying, addr_B);

    // simulate index recalculation at epoch boundary
    match_index::test_reset_ratio(root, qualifying);
    // let (_addrs_vec, _index_vec, ratio_vec) = match_index::get_ratios();

    // so far addr_A should have 75 coins from Eve's transfer
    let(_, balance_pre) = ol_account::balance(addr_A);
    assert!(balance_pre == eve_donation_to_A, 7357003);

    // let's burn some of bob's coins
    // first he sets his burn preference
    // IMPORTANT: BOB IS SETTING PREFERENCE TO SIMPLE BURN
    burn::set_send_community(bob, false);
    let bob_burn = 100000;
    let c = ol_account::withdraw(bob, bob_burn);
    // then the system burns based on his preference.
    burn::test_vm_burn_with_user_preference(root, signer::address_of(bob), c);

    // no match recycling happened
    let (lifetime_burn, lifetime_match) = burn::get_lifetime_tracker();
    assert!(lifetime_match == 0, 7357003);
    assert!(lifetime_burn > 0, 7357004);


    // NONE OF THE MATCH INDEX ACCOUNTS HAVE ANY CHANGE
    let(_, balance) = ol_account::balance(addr_A);
    assert!(balance == balance_pre, 7357005);
    assert!(balance == eve_donation_to_A, 7357006);
  }


  #[test(root = @ol_framework)]
  fun epoch_fees_burn(root: &signer) {
    // Scenario:
    // the network starts
    // we mock some tx fees going into the fee account
    // validators have ZERO balance, so they cannot pay into tx fee account
    // the validators perform correctly, and the epoch changes (they
    // are allowed to continue because of failover rules)
    // Expected Outcome:
    // The fees from the previous epoch were used to pay validators.
    // however there was an excess amount in Tx account, and this amount
    // would be burned.

    // and the supply should be lower

    let n_vals = 5;
    let genesis_balance_per_val = 0; // simplify calcs, no validators funded at start

    let exact_amount_for_reward = n_vals * default_epoch_reward();
    let excess_in_tx_fee_account = 30_000_000;

    let starting_tx_fees = excess_in_tx_fee_account + exact_amount_for_reward;

    let _vals = mock::genesis_n_vals(root, n_vals);
    mock::ol_initialize_coin_and_fund_vals(root, genesis_balance_per_val, true);
    let supply_pre = libra_coin::supply();
    mock::mock_tx_fees_in_account(root, starting_tx_fees);

    // supply at genesis always be equal to final supply
    assert!(supply_pre == default_final_supply_at_genesis(), 73570001);

    // The only fees in the tX fee account at genesis should be what was mocked by default
    assert!(transaction_fee::system_fees_collected() == starting_tx_fees, 73570002);

    // no change in supply, since these coins came from infra pledge
    assert!(libra_coin::supply() == default_final_supply_at_genesis(), 73570003);

    // start at epoch 1. NOTE Validators WILL GET PAID FOR EPOCH 1
    // but they have no balance to contribute to next epochs funds (for simplicity of calcs)
    let (lifetime_burn_pre, _lifetime_match) = burn::get_lifetime_tracker();
    mock::trigger_epoch(root);
    // NOTE: under 1000 rounds we don't evaluate performance of validators
    let (lifetime_burn_post, _lifetime_match) = burn::get_lifetime_tracker();
    assert!(lifetime_burn_post > lifetime_burn_pre, 73570004);
    // supply should be lower
    let supply_post = libra_coin::supply();

    let fees_account_balance = transaction_fee::system_fees_collected();
    let infra_pledge_subsidy = n_vals * default_epoch_reward();
    let entry_fees_total = n_vals * default_entry_fee();

    assert!(supply_post < default_final_supply_at_genesis(), 73570005);


    // Now for the follwing epoch the tx fee account should have:
    // a) the entry fees of validators (they can afford it now)
    // b) the infra pledge subsidy * vals

    assert!(fees_account_balance == (infra_pledge_subsidy +  entry_fees_total), 73570006);

    // In this scenario
    // we expect to burn everything which was in the txs after paying validator rewards.
    // we funded the tx fee account with an excess, beyond what was needed for the validator reward.

    assert!(supply_post == supply_pre - excess_in_tx_fee_account, 73570007);
  }


  #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000d, eve = @0x1000e)]
  fun epoch_fees_match(root: &signer, alice: &signer, bob: &signer, eve: &signer) {
    // Scenario:
    // There are two community wallets. Alice and Bob's
    // EVE donates to both. But mostly to Alice.
    // The Match Index, should reflect that.

    let vals = mock::genesis_n_vals(root, 5); // need to include eve to init funds
    mock::ol_initialize_coin_and_fund_vals(root, 1000000, true);
    // start at epoch 1, since turnout tally needs epoch info, and 0 may cause issues
    mock::trigger_epoch(root);

    let (communityA, _cap) = ol_account::test_ol_create_resource_account(alice, b"0x1");
    let addr_A = signer::address_of(&communityA);
    community_wallet_init::init_community(&communityA, vals, 2); // make all the vals signers

    let (communityB, _cap) = ol_account::test_ol_create_resource_account(bob, b"0xdeadbeef");
    let addr_B = signer::address_of(&communityB);
    community_wallet_init::init_community(&communityB, vals, 2); // make all the vals signers

    let eve_donation_to_A = 75;
    ol_account::transfer(eve, addr_A, eve_donation_to_A);
    let (_, _, total_funds_sent_by_eve) = receipts::read_receipt(signer::address_of(eve), addr_A);
    assert!(total_funds_sent_by_eve == eve_donation_to_A, 7357001);

    let eve_donation_to_B = 25;
    ol_account::transfer(eve, addr_B, eve_donation_to_B);
    let (_, _, total_funds_sent_by_eve) = receipts::read_receipt(signer::address_of(eve), addr_B);
    assert!(total_funds_sent_by_eve == eve_donation_to_B, 7357002);

    let qualifying = vector::singleton(addr_A);
    vector::push_back(&mut qualifying, addr_B);

    // simulate index recalculation at epoch boundary
    match_index::test_reset_ratio(root, qualifying);
    let (_addrs_vec, _index_vec, ratio_vec) = match_index::get_ratios();

    // so far addr_A should have 75 coins from Eve's transfer
    let(_, balance_pre) = ol_account::balance(addr_A);
    assert!(balance_pre == eve_donation_to_A, 7357003);

    // let's burn some of bob's coins
    // first he sets his burn preference
    burn::set_send_community(bob, true);
    let bob_burn = 100000;
    let c = ol_account::withdraw(bob, bob_burn);
    // then the system burns based on his preference.
    burn::test_vm_burn_with_user_preference(root, signer::address_of(bob), c);
    // check that a recycle to match index happened instead of a straight burn
    let (_lifetime_burn, lifetime_match) = burn::get_lifetime_tracker();
    assert!(lifetime_match > 0, 7357003);


    // the balance of address A should be increase by the ratio above 75% *  bob's burn of 100_000
    let ratio_A = vector::borrow(&ratio_vec, 0);
    let bob_burn_share_A = fixed_point32::multiply_u64(bob_burn, *ratio_A);

    let(_, balance) = ol_account::balance(addr_A);
    assert!(balance > balance_pre, 7357004);
    assert!(balance == (bob_burn_share_A + eve_donation_to_A), 7357005);
  }


  // TODO:

  // #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000d, eve = @0x1000e)]
  // fun fee_makers_calc(root: &signer, alice: &signer, bob: &signer, eve: &signer) {
  //   // Scenario:
  //   assert!(TransactionFee::get_fees_collected()==0, 735701);
  //   let coin = Diem::mint<GAS>(&vm, 1);
  //   TransactionFee::pay_fee_and_track(@Alice, coin);

  //   let fee_makers = TransactionFee::get_fee_makers();
  //   assert!(Vector::length(&fee_makers)==1, 735702);
  //   assert!(TransactionFee::get_fees_collected()==1, 735703);
  // }

  #[test(root=@ol_framework, alice=@0x1000a)]
  fun track_fees(root: &signer, alice: address) {

    let _vals = mock::genesis_n_vals(root, 1);
    mock::ol_initialize_coin_and_fund_vals(root, default_epoch_reward(), true);
    mock::mock_tx_fees_in_account(root, default_tx_fee_account_at_genesis());

    let fees = transaction_fee::system_fees_collected();
    assert!(fees == default_tx_fee_account_at_genesis(), 7357001);

    let marlon_rando = @0x12345;
    ol_account::create_account(root, marlon_rando);

    let rando_money = 5;
    let coin_option = ol_account::test_vm_withdraw(root, alice, rando_money);

    if (option::is_some(&coin_option)) {
      let c = option::extract(&mut coin_option);
      // shortcut: we have the VM use alices money to pay a fee for marlon.
      transaction_fee::vm_pay_fee(root, marlon_rando, c);
    };
    option::destroy_none(coin_option);

    let fees = transaction_fee::system_fees_collected();
    assert!(fees == (default_tx_fee_account_at_genesis() + rando_money), 7357001);

    // marlon is the only fee maker (since genesis)
    let fee_makers = fee_maker::get_fee_makers();
    assert!(vector::length(&fee_makers)==1, 7357002);
    let (_found, idx) = vector::index_of(&fee_makers, &marlon_rando);
    assert!( idx == 0, 7357003);

    let marlon_fees_made = fee_maker::get_user_fees_made(marlon_rando);
    assert!(marlon_fees_made == 5, 7357004);

    let (lifetime_burn_pre, _lifetime_match) = burn::get_lifetime_tracker();
    mock::trigger_epoch(root);
    // NOTE: under 1000 rounds we don't evaluate performance of validators
    let (lifetime_burn_post, _lifetime_match) = burn::get_lifetime_tracker();
    assert!(lifetime_burn_post > lifetime_burn_pre, 0);

    let marlon_fees_made = fee_maker::get_user_fees_made(marlon_rando);
    assert!(marlon_fees_made == 0, 7357005);

    // However, Alice (the only validator) did pay an entry fee during Proof of Fee,
    // and that fee should be tracked
    let fee_makers = fee_maker::get_fee_makers();

    assert!(vector::length(&fee_makers) == 1, 7357006);
    let (_found, idx) = vector::index_of(&fee_makers, &alice);
    assert!( idx == 0, 7357007);


    let fees = transaction_fee::system_fees_collected();
    assert!(fees == default_entry_fee() + default_epoch_reward(), 7357008); // val set entry fee
  }

  #[test(root = @ol_framework, alice_val = @0x1000a)]
  fun test_init_burn_tracker(root: &signer, alice_val: &signer) {
    mock::genesis_n_vals(root, 1);
    let genesis_mint_to_vals = 12345;
    mock::ol_initialize_coin_and_fund_vals(root, genesis_mint_to_vals, true);
    let supply = libra_coin::supply();

    let marlon_rando = @0x12345;
    let marlon_salary = 100;
    ol_account::transfer(alice_val, marlon_rando, marlon_salary);

    let (prev_supply, prev_balance, burn_at_last_calc, cumu_burn) =
    ol_account::get_burn_tracker(marlon_rando);

    // everything initialized correctly
    assert!(prev_supply == supply, 7357001);
    assert!(prev_balance == marlon_salary, 7357002);
    assert!(burn_at_last_calc == 0, 7357003);
    assert!(cumu_burn == 0, 7357004);
  }

  #[test(root = @ol_framework, alice_val=@0x1000a)]
  fun burn_tracker_increment(root: &signer, alice_val: &signer) {
    mock::genesis_n_vals(root, 1);
    let genesis_mint_to_vals = 12345;
    mock::ol_initialize_coin_and_fund_vals(root, genesis_mint_to_vals, true);
    let supply = libra_coin::supply();

    let marlon_rando = @0x12345;
    let marlon_salary = 100;
    ol_account::transfer(alice_val, marlon_rando, marlon_salary);

    let (prev_supply, prev_balance, burn_at_last_calc, cumu_burn) =
    ol_account::get_burn_tracker(marlon_rando);

    // everything initialized correctly
    assert!(prev_supply == supply, 7357001);
    assert!(prev_balance == marlon_salary, 7357002);
    assert!(burn_at_last_calc == 0, 7357003);
    assert!(cumu_burn == 0, 7357004);

    // simulate epoch boundary burn
    mock::mock_tx_fees_in_account(root, 60_000_000);
    let all_fees = transaction_fee::test_root_withdraw_all(root);
    burn::epoch_burn_fees(root, &mut all_fees);
    coin::destroy_zero(all_fees); // destroy the hot potato

    // there should be no change at this point
    let (prev_supply_1, prev_balance_1, burn_at_last_calc, cumu_burn) =
    ol_account::get_burn_tracker(marlon_rando);
    assert!(prev_supply == prev_supply_1, 7357005);
    assert!(prev_balance == prev_balance_1, 7357006);
    // there was no previous calculation, just initialization
    assert!(burn_at_last_calc == 0, 7357007);
    assert!(cumu_burn == 0, 7357008);

    ol_account::transfer(alice_val, marlon_rando, 100);

    // burn tracker will change on each transaction
    let (prev_supply_2, prev_balance_2, burn_at_last_calc_2, cumu_burn_2) =
    ol_account::get_burn_tracker(marlon_rando);

    // marlon balance went up
    assert!(prev_balance_2 > prev_balance, 73570010);
    // supply must go down
    assert!(prev_supply_2 < prev_supply, 7357009);
    // the last burn should be higher than 0 at init
    assert!(burn_at_last_calc_2 > burn_at_last_calc, 73570011);
    // the cumu burn should be higher
    assert!(cumu_burn_2 > cumu_burn, 73570012);

  }
}
