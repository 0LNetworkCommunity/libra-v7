/// # Lockbox Module
///
/// The `Lockbox` module is designed to manage time-locked Libra.
/// This is the implementation of Slow Wallet v2.0
/// The fundamental change is that the unlocking is done on a percentage basis
/// rather than a fixed amount per day.
/// It allows users to lock their assets for a specified period, ensuring that the assets
/// cannot be accessed or transferred until the daily unlocks have drained the lockbox (the lock duration has expired).
///
/// ## Key Concepts
///
/// - **Time-Locked Assets**: Assets that are locked for a specific duration and cannot be accessed
///   until the lock period ends.
/// - **Lock Periods**: Predefined durations for which assets can be locked. These periods are
///   represented as a vector of time intervals (in months).
/// - **Daily Drip**: A mechanism that gradually unlocks assets from the lockbox on a daily basis,
///   allowing partial access to the locked assets over time.
///
/// ## Constants
///
/// - `DEFAULT_LOCKS`: A vector of predefined lock periods (in months) that users can choose from.
///   These periods are: 6 months, 12 months, 24 months, 36 months, 48 months, 96 months,
///   192 months, 240 months, 288 months, 336 months, and 384 months.
///
/// ## Functions
///
/// The `Lockbox` module provides functions to:
/// - Lock assets for a specified period.
/// - Check the status of locked assets.
/// - Unlock assets once the lock period has expired.
/// - Gradually unlock assets on a daily basis through the daily drip mechanism.
///
///
/// This module ensures that assets are securely locked and cannot be accessed until the specified
/// lock period has expired, providing a mechanism for time-based asset management with gradual
/// unlocking through the daily drip mechanism.


module ol_framework::lockbox {
  use std::error;
  use std::fixed_point32::{Self, FixedPoint32};
  use std::option::{Self, Option};
  use std::signer;
  use std::vector;
  use diem_framework::coin::Coin;
  use diem_std::math64;
  use ol_framework::libra_coin::{Self, LibraCoin};
  use ol_framework::date;

  // use diem_framework::debug::print;

  friend ol_framework::ol_account;

  /// SlowWalletV2 not initialized
  const ENOT_INITIALIZED: u64 = 1;

  /// No lockbox of this duration found
  const ENO_DURATION_FOUND: u64 = 2;

  /// List of durations incomplete
  const ELIST_INCOMPLETE: u64 = 3;

  /// Tried to drip twice in one day, silly rabbit
  const ENO_DOUBLE_DIPPING: u64 = 4;

  /// Destination does not have SlowWalletv2 initialized
  const EDESTINATION_NOT_INIT: u64 = 5;

  /// Can only shift to a later duration to drip slower
  const EMUST_SHIFT_LATER: u64 = 6;

  /// Total balances should never change when shifting coins to later duration.
  const EBALANCES_CHANGED_ON_DELAY: u64 = 7;

  /// The locked units for this box duration should have changed.
  const EDURATION_UNITS_SHOULD_CHANGE: u64 = 8;

  /// Duration not in allowed list
  const EINVALID_DURATION: u64 = 9;

  const DEFAULT_LOCKS: vector<u64> = vector[6, 1*12, 2*12, 3*12, 4*12, 8*12, 16*12, 20*12, 24*12, 28*12, 32*12];

  struct Lockbox has key, store {
    locked_coins: Coin<LibraCoin>,
    duration_type: u64,
    lifetime_deposits: u64,
    lifetime_unlocked: u64,
    last_unlock_timestamp: u64,
  }

  struct SlowWalletV2 has key {
    list: vector<Lockbox>
  }

  // convenience function to get default locks
  #[view]
  public fun get_default_locks(): vector<u64> {
    DEFAULT_LOCKS
  }

  // user init lockbox
  fun maybe_initialize(user: &signer) {
    if (!exists<SlowWalletV2>(signer::address_of(user))) {
      move_to(user, SlowWalletV2 {
        list: vector::empty()
      })
    }
  }

  /// Checks if a duration is in the DEFAULT_LOCKS list
  fun is_valid_duration(duration: u64): bool {
    let i = 0;
    let len = vector::length(&DEFAULT_LOCKS);
    while (i < len) {
      if (*vector::borrow(&DEFAULT_LOCKS, i) == duration) {
        return true
      };
      i = i + 1;
    };
    false
  }

  /// Creates a lockbox. The lockbox cannot be dropped, and so must be
  /// stored in the same call.
  public(friend) fun new(locked_coins: Coin<LibraCoin>, duration_type: u64): Lockbox {
      // Validate that the duration is in the allowed list
      assert!(is_valid_duration(duration_type), error::invalid_argument(EINVALID_DURATION));

      Lockbox {
        locked_coins,
        duration_type,
        lifetime_deposits: 0,
        lifetime_unlocked: 0,
        last_unlock_timestamp: 0,
      }
  }

  /// helper to deposit coin: with a mutable borrow of a lockbox, add an owned coin
  fun deposit(box: &mut Lockbox, more_coins: Coin<LibraCoin>) {
    libra_coin::merge(&mut box.locked_coins, more_coins);
  }

  // Entrypoint for adding or creating a user box, when signed by holder of coins.
  public(friend) fun add_to_or_create_box(user: &signer, locked_coins: Coin<LibraCoin>, duration_type: u64) acquires SlowWalletV2 {
    maybe_initialize(user);

    let user_addr = signer::address_of(user);
    deposit_impl(user_addr, locked_coins, duration_type);
  }

  // private implementation for adding coins to a users lockbox, or creating it
  fun deposit_impl(user_addr: address, locked_coins: Coin<LibraCoin>, duration_type: u64) acquires SlowWalletV2 {
    let (found, idx) = idx_by_duration(user_addr, duration_type);

    let list = &mut borrow_global_mut<SlowWalletV2>(user_addr).list;

    if (found) {
      let box = vector::borrow_mut(list, idx);
      deposit(box, locked_coins);
    } else {
      vector::push_back(list, new(locked_coins, duration_type));
    }
    // TODO: always sort the list by duration_type
  }

  // drip one duration
  fun withdraw_drip_impl(user: &signer, idx: u64): Option<Coin<LibraCoin>> acquires SlowWalletV2 {
    let user_addr = signer::address_of(user);

    let list = &mut borrow_global_mut<SlowWalletV2>(user_addr).list;
    let box = vector::borrow_mut(list, idx);
    let (start_today, _) = date::start_of_day_seconds();
    // abort if tried to drip on same unix day
    assert!(start_today > box.last_unlock_timestamp, error::invalid_state(ENO_DOUBLE_DIPPING));

    let drip_value = calc_daily_drip(box);

    if (drip_value == 0) return option::none();

    box.last_unlock_timestamp = start_today;

    let dripped_coins = libra_coin::extract(&mut box.locked_coins, drip_value);

    option::some(dripped_coins)
  }

  /// drips all lockboxes, callable by ol_account
  public(friend) fun withdraw_drip_all(user: &signer): Option<Coin<LibraCoin>> acquires SlowWalletV2 {
    let list = &mut borrow_global_mut<SlowWalletV2>(signer::address_of(user)).list;
    assert!(!vector::is_empty(list), ENO_DURATION_FOUND);

    let coin_opt = option::none<Coin<LibraCoin>>();

    let len = vector::length(list);
    let i = 0;
    while (i < len) {
        let box_coins_opt = withdraw_drip_impl(user, i);
        if (option::is_none(&box_coins_opt)) {
          option::destroy_none(box_coins_opt);
          continue
        };

        let c = option::extract(&mut box_coins_opt);
        option::destroy_none(box_coins_opt);

        if (option::is_none(&coin_opt) ){
          option::fill(&mut coin_opt, c);
        } else {
          let all_coins = option::borrow_mut(&mut coin_opt);
          libra_coin::merge(all_coins, c);
        };

        i = i + 1;
    };
    coin_opt
  }


  // Shifts a lockbox's amount to a longer duration lockbox.
  // the inverse is not possible (moving a longer lockbox to a shorter).
  // a.k.a shift-back
  fun delay_impl(user: &signer, duration_from: u64, duration_to: u64, units: u64) acquires SlowWalletV2 {
    assert!(duration_to > duration_from, error::invalid_argument(EMUST_SHIFT_LATER));


    let user_addr = signer::address_of(user);
    assert!(exists<SlowWalletV2>(user_addr), error::invalid_state(ENOT_INITIALIZED));

    let (found, idx) = idx_by_duration(user_addr, duration_from);
    assert!(found, error::invalid_state(ENO_DURATION_FOUND));

    let duration_from_balance_pre = balance_duration(user_addr, duration_from);
    let duration_to_balance_pre = balance_duration(user_addr, duration_to);
    let all_balances_pre = balance_all(user_addr);

    // withdraw from one duration_from and send to duration_to
    let list = &mut borrow_global_mut<SlowWalletV2>(user_addr).list;
    let sender_box = vector::borrow_mut(list, idx);
    let coins = libra_coin::extract(&mut sender_box.locked_coins, units);
    deposit_impl(user_addr, coins, duration_to);

    let all_balances_post = balance_all(user_addr);

    // balances should never change
    assert!(all_balances_pre == all_balances_post, error::invalid_state(EBALANCES_CHANGED_ON_DELAY));

    // origin units should be LOWER
    let duration_from_balance_post = balance_duration(user_addr, duration_from);
    assert!(duration_from_balance_pre > duration_from_balance_post, error::invalid_state(EDURATION_UNITS_SHOULD_CHANGE));

    // destination units should be GREATER
    let duration_to_balance_post = balance_duration(user_addr, duration_to);
    assert!( duration_to_balance_pre < duration_to_balance_post, error::invalid_state(EDURATION_UNITS_SHOULD_CHANGE));
  }

  // Sends a portion of a lockbox to a different account which has a slowwalletv2 enabled
  // In this transfer we check that two users have accounts.
  // We check that there's no possibility of transferring coins to boxes of
  // different durations
  fun checked_transfer_impl(from: &signer, to: address, duration_type: u64, units: u64) acquires SlowWalletV2 {
    let from_addr = signer::address_of(from);
    assert!(exists<SlowWalletV2>(from_addr), error::invalid_state(ENOT_INITIALIZED));
    assert!(exists<SlowWalletV2>(to), error::invalid_state(EDESTINATION_NOT_INIT));

    let (found, idx) = idx_by_duration(from_addr, duration_type);
    assert!(found, error::invalid_state(ENO_DURATION_FOUND));

    // borrow a box from the sender, and extract the coins
    // then deposit in the box of the destination account account.
    let list = &mut borrow_global_mut<SlowWalletV2>(from_addr).list;
    let sender_box = vector::borrow_mut(list, idx);
    let coins = libra_coin::extract(&mut sender_box.locked_coins, units);
    deposit_impl(to, coins, duration_type);
  }

  ///////// GETTERS ////////

  fun get_daily_pct(box: &Lockbox): FixedPoint32 {
    let days = math64::mul_div(box.duration_type, 365, 12);
    fixed_point32::create_from_rational(1, days)
  }

  fun calc_daily_drip(box: &Lockbox): u64  {
    let daily_pct = get_daily_pct(box);
    let value = libra_coin::value(&box.locked_coins);
    fixed_point32::multiply_u64(value, daily_pct)
  }

  #[view]
  public fun idx_by_duration(user_addr: address, duration_type: u64): (bool, u64) acquires SlowWalletV2 {
    assert!(exists<SlowWalletV2>(user_addr), error::invalid_state(ENOT_INITIALIZED));
    let list = &borrow_global<SlowWalletV2>(user_addr).list;
    // NOTE: there should only be one box per duration_type. TBD if there's a different use case to have duplicate lockbox durations.

    let len = vector::length(list);
    let i = 0;
    while (i < len) {
        let el = vector::borrow(list, i);
        if (el.duration_type == duration_type) {
            return (true, i)
        };
        i = i + 1;
    };

    (false, 0)
  }

  #[view]
  public fun get_list_durations_holding(user_addr: address): vector<u64> acquires SlowWalletV2 {
    assert!(exists<SlowWalletV2>(user_addr), error::invalid_state(ENOT_INITIALIZED));
    let list = &borrow_global<SlowWalletV2>(user_addr).list;
    let all_durations = vector[];
    let len = vector::length(list);
    let i = 0;
    while (i < len) {
        let el = vector::borrow(list, i);
        vector::push_back(&mut all_durations, el.duration_type);
        i = i + 1;
    };
    assert!(vector::length(&all_durations) == len, error::invalid_state(ELIST_INCOMPLETE));

    all_durations
  }

  #[view]
  /// balance for one duration_type's box
  public fun balance_duration(user_addr: address, duration_type: u64): u64 acquires SlowWalletV2 {
    if (!exists<SlowWalletV2>(user_addr)) return 0;
    let (found, idx) = idx_by_duration(user_addr, duration_type);
    if (!found) {
      return 0
    };

    let list = &borrow_global<SlowWalletV2>(user_addr).list;
    let box = vector::borrow(list, idx);
    libra_coin::value(&box.locked_coins)
  }

  /// balance of all lockboxes
  fun balance_list(list: &vector<Lockbox>): u64 {
    let sum = 0;
    let len = vector::length(list);
    let i = 0;
    while (i < len) {
        let el = vector::borrow(list, i);
        sum = sum + libra_coin::value(&el.locked_coins);
        i = i + 1;
    };

    sum
  }

  #[view]
  /// balance of all lockboxes
  public fun balance_all(user_addr: address): u64 acquires SlowWalletV2 {
    let sum = 0;
    if (!exists<SlowWalletV2>(user_addr)) return sum;
    let list = &borrow_global<SlowWalletV2>(user_addr).list;
    balance_list(list)
  }


  //////// UNIT TESTS ////////
  #[test_only]
  use diem_framework::coin;

  #[test_only]
  fun test_setup(framework: &signer, amount: u64): Coin<LibraCoin> {
    let (burn_cap, mint_cap) = libra_coin::initialize_for_test(framework);
    let c = coin::test_mint(amount, &mint_cap);
    coin::destroy_mint_cap(mint_cap);
    coin::destroy_burn_cap(burn_cap);
    c
  }


  #[test(bob_sig = @0x10002)]
  #[expected_failure(abort_code = 196609, location = ol_framework::lockbox)]
  fun lockbox_idx_aborts_when_not_init(bob_sig: &signer) acquires SlowWalletV2 {
    let bob_addr = signer::address_of(bob_sig);
    let (_,_) = idx_by_duration(bob_addr, 1*12);
  }

  #[test(framework = @0x1, bob_sig = @0x10002)]
  fun creates_lockbox(framework: &signer, bob_sig: &signer) acquires SlowWalletV2 {
    let bob_addr = signer::address_of(bob_sig);

    let coin = test_setup(framework, 23);

    add_to_or_create_box(bob_sig, coin, 1*12);

    // see if it exists
    let (found, idx) = idx_by_duration(bob_addr, 1*12);
    assert!(found, 7357002);
    assert!(idx == 0, 7357003);

    let balance_one = balance_duration(bob_addr, 1*12);
    assert!(balance_one == 23, 7357004);
    let balanace_all = balance_all(bob_addr);
    assert!(balanace_all == 23, 7357005);
  }

  #[test(framework = @0x1, bob_sig = @0x10002)]
  fun adds_to_lockbox(framework: &signer, bob_sig: &signer) acquires SlowWalletV2 {
    let bob_addr = signer::address_of(bob_sig);
    let coin = test_setup(framework, 123);
    let split_coin = libra_coin::extract(&mut coin, 23);

    add_to_or_create_box(bob_sig, split_coin, 1*12);

    // see if it exists
    let (found, idx) = idx_by_duration(bob_addr, 1*12);
    assert!(found, 7357002);
    assert!(idx == 0, 7357003);

    let bal = balance_all(bob_addr);
    assert!(bal == 23, 7357004);

    // remainder of coin should be 100
    add_to_or_create_box(bob_sig, coin, 1*12);

    // see if it exists
    let (found, idx) = idx_by_duration(bob_addr, 1*12);
    assert!(found, 7357005);
    assert!(idx == 0, 7357006);

    let bal2 = balance_all(bob_addr);
    assert!(bal2 == 123, 7357007);
  }

  #[test(framework = @0x1, bob_sig = @0x10002)]
  #[expected_failure(abort_code = 65545, location = ol_framework::lockbox)]
  fun test_non_standard_duration(framework: &signer, bob_sig: &signer) acquires SlowWalletV2 {
    let bob_addr = signer::address_of(bob_sig);
    let coin = test_setup(framework, 100);

    // Try to create a lockbox with a non-standard duration (5*12 months)
    // This should fail because 5*12 is not in DEFAULT_LOCKS
    add_to_or_create_box(bob_sig, coin, 5*12);

    // These assertions should never be reached because the above call should fail
    let (found, _) = idx_by_duration(bob_addr, 5*12);
    assert!(!found, 7357001);
  }

  #[test(framework = @0x1, bob_sig = @0x10002)]
  fun test_standard_duration(framework: &signer, bob_sig: &signer) acquires SlowWalletV2 {
    let bob_addr = signer::address_of(bob_sig);
    let coin = test_setup(framework, 100);

    // Try to create a lockbox with a standard duration (4*12 months)
    // This should succeed because 4*12 is in DEFAULT_LOCKS
    add_to_or_create_box(bob_sig, coin, 4*12);

    // Verify the lockbox was created with the standard duration
    let (found, idx) = idx_by_duration(bob_addr, 4*12);
    assert!(found, 7357001);
    assert!(idx == 0, 7357002);

    // Verify the balance
    let balance = balance_duration(bob_addr, 4*12);
    assert!(balance == 100, 7357003);
  }
}
