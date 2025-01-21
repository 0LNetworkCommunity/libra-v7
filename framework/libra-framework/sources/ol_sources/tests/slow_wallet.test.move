
#[test_only]
/// tests for external apis, and where a dependency cycle with genesis is created.
module ol_framework::test_slow_wallet {
  use diem_framework::stake;
  use diem_framework::account;
  use ol_framework::slow_wallet;
  use ol_framework::mock::{Self, default_tx_fee_account_at_genesis};
  use ol_framework::ol_account;
  use ol_framework::libra_coin;
  use ol_framework::epoch_boundary;
  use diem_framework::reconfiguration;
  use diem_framework::coin;
  use diem_framework::block;
  use ol_framework::transaction_fee;
  use ol_framework::rewards;
  use ol_framework::burn;
  use std::vector;
  use std::signer;

  //  use diem_std::debug::print;

  #[test(root = @ol_framework)]
  // we are testing that genesis creates the needed struct
  // and a validator creation sets the users account to slow.
  fun slow_wallet_init(root: signer) {
      let _set = mock::genesis_n_vals(&root, 4);
      let list = slow_wallet::get_slow_list();

      // alice, the validator, is already a slow wallet.
      assert!(vector::length<address>(&list) == 4, 735701);

      // frank was not created above
      let sig = account::create_signer_for_test(@0x1000f);
      let (_sk, pk, pop) = stake::generate_identity();
      stake::initialize_test_validator(&root, &pk, &pop, &sig, 100, true, true);

      let list = slow_wallet::get_slow_list();
      assert!(vector::length<address>(&list) == 5, 735701);
  }

  #[test(root = @ol_framework, alice_sig = @0x1000a, bob_sig = @0x1000b)]
  fun test_locked_supply(root: signer, alice_sig: &signer, bob_sig: &signer) {
    let a_addr = signer::address_of(alice_sig);
    let b_addr = signer::address_of(bob_sig);
    mock::ol_test_genesis(&root);
    let mint_cap = libra_coin::extract_mint_cap(&root);
    slow_wallet::initialize(&root);
    // create alice account
    ol_account::create_account(&root, a_addr);
    ol_account::create_account(&root, b_addr);
    slow_wallet::user_set_slow(alice_sig);
    slow_wallet::user_set_slow(bob_sig);

    let (u, t) = ol_account::balance(a_addr);
    assert!(u == 0, 735701);
    assert!(t == 0, 735702);

    assert!(slow_wallet::is_slow(a_addr), 7357003);
    assert!(slow_wallet::unlocked_amount(a_addr) == 0, 735704);

    let a_coin = coin::test_mint(1000, &mint_cap);
    let b_coin = coin::test_mint(2000, &mint_cap);

    ol_account::vm_deposit_coins_locked(&root, a_addr, a_coin);

    coin::destroy_mint_cap(mint_cap);
    let (u, t) = ol_account::balance(a_addr);
    assert!(u == 0, 735705);
    assert!(t == 1000, 735706);

    let locked_supply = slow_wallet::get_locked_supply();
    assert!(locked_supply == 1000, 735707);

    // let's check it works with more than one account.
    // now bob gets his coins, and the locked supply goes up
    ol_account::vm_deposit_coins_locked(&root, b_addr, b_coin);
    let locked_supply = slow_wallet::get_locked_supply();
    assert!(locked_supply == 3000, 735708);

    // everyone gets a 500 coin drip at end of epoch
    slow_wallet::slow_wallet_epoch_drip(&root, 500);
    let locked_supply_post_drip = slow_wallet::get_locked_supply();
    assert!(locked_supply_post_drip == 2000, 735709);

    // transfer of unlocked funds should not change the locked supply or
    // trackers
    let (u, t) = ol_account::balance(a_addr);
    let alice_locked_post_drip = (t-u);
    ol_account::transfer(bob_sig, a_addr, 100);

    // check alice balance
    let (u, t) = ol_account::balance(a_addr);
    // alice total balance has gone up
    assert!(t == 1100, 7357010);
    // not change in locked balance since drip
    let alice_locked_end = (t-u);
    assert!(alice_locked_end == alice_locked_post_drip, 7357011);

    let locked_supply_end = slow_wallet::get_locked_supply();
    assert!(locked_supply_post_drip == locked_supply_end, 7357012);

    let burnthis = ol_account::withdraw(alice_sig, 100);
    burn::burn_and_track(burnthis);
    let locked_supply_burn = slow_wallet::get_locked_supply();
    // no change to locked on withdraw unlocked and burn
    assert!(locked_supply_burn == locked_supply_end, 7357012);

  }

  #[test(root = @ol_framework)]
  fun test_epoch_drip(root: signer) {
    let set = mock::genesis_n_vals(&root, 4);
    let should_drip = false;
    mock::ol_initialize_coin_and_fund_vals(&root, 100, should_drip);
    mock::mock_tx_fees_in_account(&root, default_tx_fee_account_at_genesis());

    let a = *vector::borrow(&set, 0);
    assert!(slow_wallet::is_slow(a), 7357000);
    // mock:: does not drip by default
    assert!(slow_wallet::unlocked_amount(a) == 0, 735701);

    let coin = transaction_fee::test_root_withdraw_all(&root);
    rewards::test_helper_pay_reward(&root, a, coin, 0);

    let (unlocked, total_balance) = ol_account::balance(a);

    assert!(total_balance == (default_tx_fee_account_at_genesis() + 100), 735702);
    assert!(unlocked == 0, 735703);

    slow_wallet::slow_wallet_epoch_drip(&root, 233);
    let (unlocked, total_balance) = ol_account::balance(a);
    // no change total balances
    assert!(total_balance==(default_tx_fee_account_at_genesis() + 100), 735704);
    assert!(unlocked==233, 735705);
  }

  #[test(root = @ol_framework, alice = @0x123, bob = @0x456)]
  fun test_deposit_unlocked_happy(root: signer, alice: signer) {
    mock::ol_test_genesis(&root);
    let mint_cap = libra_coin::extract_mint_cap(&root);

    slow_wallet::initialize(&root);

    // create alice account
    ol_account::create_account(&root, @0x123);
    slow_wallet::user_set_slow(&alice);

    assert!(slow_wallet::is_slow(@0x123), 7357000);
    assert!(slow_wallet::unlocked_amount(@0x123) == 0, 735701);

    // add some coins to alice
    let alice_init_balance = 10000;
    ol_account::deposit_coins(@0x123, coin::test_mint(alice_init_balance, &mint_cap));
    coin::destroy_mint_cap(mint_cap);
    // the transfer was of already unlocked coins, so they will post as unlocked on alice
    assert!(slow_wallet::unlocked_amount(@0x123) == alice_init_balance, 735703);
    assert!(slow_wallet::transferred_amount(@0x123) == 0, 735704);
  }


  #[test(root = @ol_framework, alice = @0x123, bob = @0x456)]
  fun test_transfer_unlocked_happy(root: signer, alice: signer) {
    mock::ol_test_genesis(&root);
    let mint_cap = libra_coin::extract_mint_cap(&root);

    slow_wallet::initialize(&root);


    // create alice account
    ol_account::create_account(&root, @0x123);

    slow_wallet::user_set_slow(&alice);

    assert!(slow_wallet::is_slow(@0x123), 7357000);
    assert!(slow_wallet::unlocked_amount(@0x123) == 0, 735701);

    // add some coins to alice
    let alice_init_balance = 10000;
    ol_account::deposit_coins(@0x123, coin::test_mint(alice_init_balance, &mint_cap));
    coin::destroy_mint_cap(mint_cap);
    // the transfer was of already unlocked coins, so they will post as unlocked on alice
    assert!(slow_wallet::unlocked_amount(@0x123) == alice_init_balance, 735703);
    assert!(slow_wallet::transferred_amount(@0x123) == 0, 735704);


    // transferring funds will create Bob's account
    // the coins are also unlocked
    let transfer_amount = 10;
    ol_account::transfer(&alice, @0x456, transfer_amount);
    // slow transfer
    let b_balance = libra_coin::balance(@0x456);
    assert!(b_balance == transfer_amount, 735704);

    assert!(slow_wallet::unlocked_amount(@0x123) == (alice_init_balance - transfer_amount), 735705);
    assert!(slow_wallet::unlocked_amount(@0x456) == transfer_amount, 735706);

    // alice should show a slow wallet transfer amount equal to sent;
    assert!(slow_wallet::transferred_amount(@0x123) == transfer_amount, 735707);
    // bob should show no change
    assert!(slow_wallet::transferred_amount(@0x456) == 0, 735708);

  }

  // scenario: testing trying send more funds than are unlocked
  #[test(root = @ol_framework, alice = @0x123, bob = @0x456)]
  #[expected_failure(abort_code = 196614, location = 0x1::ol_account)]
  fun test_transfer_sad(root: signer, alice: signer) {
    mock::ol_test_genesis(&root);
    let mint_cap = libra_coin::extract_mint_cap(&root);
    slow_wallet::initialize(&root);
    ol_account::create_account(&root, @0x123);
    slow_wallet::user_set_slow(&alice);
    assert!(slow_wallet::is_slow(@0x123), 7357000);
    assert!(slow_wallet::unlocked_amount(@0x123) == 0, 735701);

    // fund alice
    // let (burn_cap, mint_cap) = libra_coin::initialize_for_test(&root);
    ol_account::deposit_coins(@0x123, coin::test_mint(100, &mint_cap));
    // coin::destroy_burn_cap(burn_cap);
    coin::destroy_mint_cap(mint_cap);

    // alice will transfer and create bob's account
    ol_account::transfer(&alice, @0x456, 99);

    let b_balance = libra_coin::balance(@0x456);
    assert!(b_balance == 99, 735702);
    assert!(slow_wallet::unlocked_amount(@0x123) == 01, 735703);

    ol_account::transfer(&alice, @0x456, 200); // TOO MUCH, should fail
  }


  #[test(root = @ol_framework)]
  // we are testing that genesis creates the needed struct
  // and a validator creation sets the users account to slow.
  fun slow_wallet_reconfigure (root: signer) {
    let set = mock::genesis_n_vals(&root, 4);
    // mock::ol_initialize_coin(&root);
    let a = vector::borrow(&set, 0);
    assert!(slow_wallet::unlocked_amount(*a) == 0, 735701);
    epoch_boundary::ol_reconfigure_for_test(&root, reconfiguration::current_epoch(), block::get_current_block_height())

  }


  #[test(root = @0x1)]
  public entry fun test_human_read(
        root: signer,
    ) {
        let _set = mock::genesis_n_vals(&root, 4);
    mock::ol_initialize_coin_and_fund_vals(&root, 1234567890, false);


        let (integer, decimal) = ol_account::balance_human(@0x1000a);

        assert!(integer == 12, 7357001);
        assert!(decimal == 34567890, 7357002);

    }

}
