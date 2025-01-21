// LAST GOODBYE
// When you are doing a hard fork, sometimes you want to start your new
// chain with a subset of users. This tool in unopinionated about that.
// There are implementation details specific to MoveVm which complicate this process.

//// First time hard-forkers, read this first ////
// By using the code below, I'm assuming you know what you are doing.
// That is, you know that in a hard fork you are starting a new chain.
// This is not a governance action on an existing chain.
// You are leaving a chain behind and starting a new one.
// Keep this close to your heart:
// The dominant strategy for others is to not join you.
//////////////////////////////////////////////////

// Removing Accounts in Hard Forks in Diem
// Forking a chain and removing accounts is not as simple as for example on a
// UTXO chain like bitcoin, where dropping the accounts would also remove
// the coins.
// On modern blockchains the coins are connected through different modules and
// there is state that needs to be gracefully removed in a cascade.
// With MoveVm however there is no way of eliminating accounts from within the
// VM, the account is a primitive of the database.
// So forking accounts would be a three step procedure: execute some MoveVm
// transactions to gracefully sunset accounts. Then subsequently run some
// database operation (in Rust-land), to remove the address tree.
// This module deals with sunsetting accounts. These operatiosn happen in a
// MoveVM except not in a production chain, on a database at rest.
// This step  has three sub-tasks:
// a) brick the account with an unrecoverable authkey. No operations would be
// possible from here
// b) updating any system-wide state affected by dropping accounts, effectively
// sanitizing the telephone handle (e.g. adjust total supply counter).
// c) finally, removing the accounts::Account struct so that this address is no
// longer discoverable.
// Important note: after these steps this address is still able to receive state
// changes from offline db processing. The address` did not disappear from the
// DB's merkle tree. And so for the address to be fully
// removed from the db it needs specialized processing offline and outside of a
// move-vm session


/// We just have to face it, this time
/// (This time, this time) we're through (we're through)
/// This time we're through, we're really through
/// Breaking up is never easy, I know, but I have (I have to go) to go
/// (This time I have to go, this time I know) knowing me, knowing you
/// It's the best I can do
module ol_framework::last_goodbye {
  use std::signer;
  use std::option;
  use std::vector;
  use std::error;
  use std::debug::print;
  use diem_framework::coin;
  use diem_framework::system_addresses;
  use ol_framework::burn;
  use ol_framework::libra_coin::LibraCoin;
  use ol_framework::pledge_accounts;
  use ol_framework::receipts;
  use ol_framework::jail;
  use ol_framework::vouch;
  use ol_framework::slow_wallet;

  use diem_framework::account;

  #[test_only]
  use ol_framework::ol_account;
  #[test_only]
  use ol_framework::match_index;
  #[test_only]
  use ol_framework::validator_universe;


  #[test_only]
  friend ol_framework::test_boundary;
  #[test_only]
  friend ol_framework::test_last_goodbye;




  /// the key should have rotated
  const EAUTH_KEY_SHOULD_ROTATE: u64 = 0;

  // Private function so that this can only be called from a MoveVM session
  // (i.e. offline or at genesis).
  // belt and suspenders: requires the Vm signer as well as the user account.
  // the VM signer (and being private) means it cannot be conducted by a simple
  // governance tx in diem_governance.move. That is: it must be in the extreme
  // situation of an offline HARD FORK.
  fun dont_think_twice_its_alright(vm: &signer, user: &signer) {
    system_addresses::assert_vm(vm);
    let user_addr = signer::address_of(user);
    if (!account::exists_at(user_addr)) {
      return
    };

    // dangling state in receipts could allow user to participate in community
    // wallets
    receipts::hard_fork_sanitize(vm, user);
    jail::garbage_collection(user);
    vouch::hard_fork_sanitize(vm, user);


    let _locked = slow_wallet::hard_fork_sanitize(vm, user);


    // remove a pledge account if there is one, so that coins there are
    // not dangling
    let _coin_val = pledge_accounts::hard_fork_sanitize(vm, user);

        // do all the necessary coin accounting prior to removing the account.
    let total_bal = coin::balance<LibraCoin>(user_addr);

    let all_coins_opt = coin::vm_withdraw<LibraCoin>(vm, user_addr,
    total_bal);

    // It ain't no use to sit and wonder why, babe
    // If'n you don't know by now
    // And it ain't no use to sit and wonder why, babe
    // It'll never do somehow
    // When your rooster crows at the break of dawn
    // Look out your window and I'll be gone
    // You're the reason I'm a-traveling on
    // But don't think twice, it's all right
    if (option::is_some(&all_coins_opt)) {
      let good_capital = option::extract(&mut all_coins_opt);
      burn::burn_and_track(good_capital);
    };

    option::destroy_none(all_coins_opt);

    let auth_key = b"Oh, is it too late now to say sorry?";
    vector::trim(&mut auth_key, 32);

    // Oh, is it too late now to say sorry?
    // Yeah, I know that I let you down
    // Is it too late to say I'm sorry now?

    // this will brick the account permanently
    // another function can be called to drop the account::Account completely
    // and then the offline db tools can safely remove the key from db.
    account::rotate_authentication_key_internal(user, auth_key);

  }

  fun last_goodbye(vm: &signer, user: &signer) {
    let addr = signer::address_of(user);
    if (!account::exists_at(addr)) {
      return
    };

    let auth_orig = account::get_authentication_key(addr);
    dont_think_twice_its_alright(vm, user);

    let new_auth = account::get_authentication_key(addr);
    // if the account is a validator they stay on ark a

      assert!(auth_orig != new_auth, error::invalid_state(EAUTH_KEY_SHOULD_ROTATE));

      // This is our last goodbye
      // I hate to feel the love between us die
      // But it's over
      // Just hear this and then I'll go
      // You gave me more to live for
      // More than you'll ever know

      account::hard_fork_drop(vm, user);
  }

  #[test_only]
  public(friend) fun danger_framework_gc(vm: &signer) {
    system_addresses::assert_vm(vm);
    match_index::garbage_collection();
    slow_wallet::garbage_collection();
    validator_universe::garbage_collection();
  }

  #[test_only]
  public(friend) fun danger_user_gc(vm: &signer, user: &signer) {
    system_addresses::assert_vm(vm);

    jail::garbage_collection(user);
  }


  #[test_only]
  // belt and suspenders
  public(friend) fun danger_test_last_goodby(vm: &signer, alice: &signer) {
    system_addresses::assert_vm(vm);

    last_goodbye(vm, alice);
  }


  // #[test(vm = @0x0, framework = @0x1, alice = @0x1000a, bob = @0x1111b)]
  //   fun bang_bang(vm: &signer, framework: &signer, alice: address, bob: &signer) {
  //     use diem_framework::account;
  //     use ol_framework::mock;

  //     account::maybe_initialize_duplicate_originating(framework);
  //     mock::genesis_n_vals(framework, 1);

  //     let b_addr = signer::address_of(bob);
  //     account::create_account_for_test(b_addr);
  //     assert!(account::exists_at(b_addr), 735701); // Confirm Bob's account exists

  //     last_goodbye(vm, bob);
  //     // Ensure the account DOES NOT exist at all
  //     assert!(!account::exists_at(b_addr), 735702);
  //     // is a tombstone
  //     assert!(account::is_tombstone(b_addr), 735703);
  //     assert!(!account::is_tombstone(alice), 735704);
  //     assert!(!slow_wallet::is_slow(b_addr), 735704);

  //   }

  #[test(vm = @0x0, framework = @0x1, alice = @0x1111a)]
    fun k_bai(vm: &signer, framework: &signer, alice: &signer) {
      use diem_framework::account;
      use ol_framework::mock;

      mock::ol_test_genesis(framework);
      let a_addr = signer::address_of(alice);
      account::create_account_for_test(a_addr);
      assert!(account::exists_at(a_addr), 7357); // Confirm Alice's account exists

      let auth_orig = account::get_authentication_key(a_addr);

      dont_think_twice_its_alright(vm, alice);
      assert!(account::exists_at(a_addr), 7357); // Ensure the account still exists after operation

      // Verify if the authentication key changed as expected
      let auth_changed = account::get_authentication_key(a_addr);
      assert!(auth_changed != auth_orig, 7358); // Confirm the authentication key was altered
    }

    #[test(vm = @0x0, framework = @0x1, alice = @0x1111a)]
    fun k_bai_balance(vm: &signer, framework: &signer, alice: &signer) {
      use diem_framework::account;
      use ol_framework::mock;

      mock::ol_test_genesis(framework);

      let a_addr = signer::address_of(alice);
      ol_account::create_account(vm, a_addr);
      assert!(account::exists_at(a_addr), 735701); // Verify Bob's account was successfully created

      let auth_orig = account::get_authentication_key(a_addr);

      mock::ol_mint_to(framework, a_addr, 303030);

      let (_, total_bal_pre) = ol_account::balance(a_addr);
      assert!(total_bal_pre == 303030, 735702); // Ensure the balance matches expected before operation

      dont_think_twice_its_alright(vm, alice);
      assert!(account::exists_at(a_addr), 735703); // Confirm the account exists post-operation

      let (_, total_bal_post) = ol_account::balance(a_addr);
      assert!(total_bal_post == 0, 735704); // Verify the balance is zero after operation

      // New Assert: Check if the authentication key changed post-operation
      let auth_changed = account::get_authentication_key(a_addr);
      assert!(auth_changed != auth_orig, 735705); // Confirm the authentication key was altered
    }

  #[test(vm = @0x0, framework = @0x1, alice = @0x1000a, bob = @0x1000b)]
  fun k_bai_global_balance(vm: &signer, framework: &signer, alice: &signer, bob: &signer) {
    use diem_framework::account;
    use ol_framework::mock;
    use ol_framework::libra_coin;

    // Initialize the framework and set initial conditions
    mock::genesis_n_vals(framework, 1);
    mock::ol_initialize_coin_and_fund_vals(framework, 10000000, true);


    // Check the initial global supply
    let existing_supply_pre = libra_coin::supply();
    assert!(existing_supply_pre > 0, 735701); // Ensure there's an initial supply

    let b_addr = signer::address_of(bob);
    ol_account::transfer(alice, b_addr, 350000);
    assert!(account::exists_at(b_addr), 735702); // Verify Bob's account exists

    // Retrieve and assert Bob's initial balance
    let (_, total_bal_pre) = ol_account::balance(b_addr);
    assert!(total_bal_pre == 350000, 735703); // Expected balance before operation

    // Perform the account modification operation
    dont_think_twice_its_alright(vm, bob);
    assert!(account::exists_at(b_addr), 735704); // Account should still exist

    // Assert the authentication key was changed
    let auth_orig_post = account::get_authentication_key(b_addr);
    assert!(auth_orig_post != b"Oh, is it too late now to say sorry?", 735705);

    // Assert Bob's balance is now 0 after the operation
    let (_, total_bal_post) = ol_account::balance(b_addr);
    assert!(total_bal_post == 0, 735706); // Balance should be zero

    // Check the global supply after the operation
    let existing_supply_post = libra_coin::supply();
    assert!(existing_supply_post < existing_supply_pre, 735707); // Global supply should decrease
  }

  #[test(vm = @0x0,framework = @0x1, alice = @0x1000a, bob = @0x1000b)]
  fun k_bai_effect_on_global_burns(vm: &signer, framework: &signer, alice: &signer, bob: &signer) {
    use ol_framework::mock;
    use ol_framework::burn;
    use ol_framework::libra_coin;
    use std::signer;

    // Initialize the testing environment and mint coins to Bob's account.
    mock::genesis_n_vals(framework, 1);

    mock::ol_initialize_coin_and_fund_vals(framework, 1000000, true);


    let b_addr = signer::address_of(bob);

    ol_account::transfer(alice, b_addr, 350000);

    let bob_addr = signer::address_of(bob);

    // Capture the global supply and burn counters before operation.
    let global_supply_pre = libra_coin::supply();
    let (burned_pre, recycled_pre) = burn::get_lifetime_tracker();

    dont_think_twice_its_alright(vm, bob);

    // Capture the global supply and burn counters after operation.
    let global_supply_post = libra_coin::supply();
    let (burned_post, recycled_post) = burn::get_lifetime_tracker();


    // Verify burn
    assert!(burned_post > burned_pre, 7357001);

    // Assert that recycled coins count remains the same, indicating no recycling occurred.
    assert!(recycled_pre == recycled_post, 7357005);

    // Assert the global supply of coins has decreased if the coins were burned,
    assert!(global_supply_post < global_supply_pre, 7357004);

    // Verify Bob's account balance is zero after the operation.
    let (_, bob_balance_post) = ol_account::balance(bob_addr);
    assert!(bob_balance_post == 0, 7357003);
  }
}
