///////////////////////////////////////////////////////////////////////////
// 0L Module
// Jail
///////////////////////////////////////////////////////////////////////////
// Controllers for keeping non-performing validators out of the set.
// File Prefix for errors: 1001
///////////////////////////////////////////////////////////////////////////

  //////// V7 Notes //////
  // With this upgrade explicit hurdle that the validator
  // needs to overcome now that we have deprecated Towers.
  // Additionally there's not another practical and objective way
  // to gate validator admission besides the very loose requirement
  // of having a Vouch.
  // So absent some other check that is objective, we could
  // lean on the Vouch network for checking that a validator that fell out of these (jailed), is ready to continue (unjail).
  ////////////////////////

// The objective of the jail module is to allow a validator to do necessary
// maintenanance on the node before attempting to rejoin the validator set
// before they are ready.
// The jail module also incorporates some non-monetary reputation staking
// features of Vouch, which cannot be included in that module due to code
// cyclical dependencies.
// Summary:
// If Alice fails to validate at the threshold necessary (is either a Case 1,
// or Case 2), then her Jail state gets updated, with is_jailed=true. This means
// she cannot re-enter the validator set, until someone that vouched for Alice
// (Bob) sends an un_jail transaction. Bob has interest in seeing Alice rejoin
// and be performing since Bob's Jail state also gets updated based on Alice's performance.
// On Bob's Jail card there is a lifetime_vouchees_jailed, every time Alice
// (because Bob has vouched for her) gets marked for jail, this number gets
// incremented on Bob's state too.
// It is recursive. If Alice is vouching for Carol, and Carol gets a Jail term.
// Then both Alice, and Bob will have lifetime_vouchees_jailed incremented.
// Even if Carol and Bob never met.
// Not included in this code, but included in Vouch, is the logic for the deposit
// the Vouchers put on the Vouchee accounts. So besides the permanent mark on
// the account, Bob will lose the deposit.


module ol_framework::jail {
  use diem_framework::system_addresses;
  use std::signer;
  use std::vector;
  use std::error;
  use ol_framework::vouch;
  use ol_framework::stake;
  use ol_framework::address_utils;

  friend ol_framework::validator_universe;
  friend ol_framework::musical_chairs;

  #[test_only]
  friend ol_framework::test_pof;
  #[test_only]
  friend ol_framework::test_jail;
  #[test_only]
  friend ol_framework::test_boundary;

  /// Validator is misconfigured cannot unjail.
  const EVALIDATOR_CONFIG: u64 = 1;
  /// You are not a validator in the current set, you can't unjail anyone.
  const EVOUCHER_NOT_IN_SET: u64 = 2;
  /// You not actually a valid voucher for this user. Did it expire?
  const EU_NO_VOUCHER: u64 = 3;

  struct Jail has key {
      is_jailed: bool,
      // number of times the validator was dropped from set. Does not reset.
      lifetime_jailed: u64,
      // number of times a downstream validator this user has vouched for has
      // been jailed.
      // this is recursive. So if a validator I vouched for, vouched for
      // a third validator that failed, this number gets incremented.
      lifetime_vouchees_jailed: u64,
      // validator that was jailed and qualified to enter the set, but fails
      // to complete epoch.
      // this resets as soon as they rejoin successfully.
      // this counter is used for ordering prospective validators entering a set.
      consecutive_failure_to_rejoin: u64,

  }

  public(friend) fun init(val_sig: &signer) {
    let addr = signer::address_of(val_sig);
    if (!exists<Jail>(addr)) {
      move_to<Jail>(val_sig, Jail {
        is_jailed: false,
        lifetime_jailed: 0,
        lifetime_vouchees_jailed: 0,
        consecutive_failure_to_rejoin: 0,

      });
    }
  }


  #[view]
  public fun is_jailed(validator: address): bool acquires Jail {
    if (!exists<Jail>(validator)) {
      return false
    };
    borrow_global<Jail>(validator).is_jailed
  }

  public(friend) fun jail(vm: &signer, validator: address) acquires Jail{
    system_addresses::assert_ol(vm);
    if (exists<Jail>(validator)) {
      let j = borrow_global_mut<Jail>(validator);
      j.is_jailed = true;
      j.lifetime_jailed = j.lifetime_jailed + 1;
      j.consecutive_failure_to_rejoin = j.consecutive_failure_to_rejoin + 1;
    };

    inc_voucher_jail(validator);
  }

  /// If the validator performs again after having been jailed,
  /// then we can remove the consecutive fails.
  /// Otherwise the lifetime counters on their account, and on buddy Voucher accounts does not get cleared.
  fun reset_consecutive_fail(root: &signer, validator: address) acquires Jail {
    system_addresses::assert_ol(root);
    if (exists<Jail>(validator)) {
      let j = borrow_global_mut<Jail>(validator);
      j.consecutive_failure_to_rejoin = 0;
    }
  }

  #[test_only]
  public(friend) fun test_reset_consecutive_fail(root: &signer, validator: address) acquires Jail {
    reset_consecutive_fail(root, validator)
  }

  /// Only a Voucher of the validator can flip the unjail bit.
  /// This is a way to make sure the validator is ready to rejoin.
  public entry fun unjail_by_voucher(sender: &signer, addr: address) acquires Jail {
    assert!(
      stake::is_valid(addr),
      error::invalid_state(EVALIDATOR_CONFIG),
    );
    let voucher = signer::address_of(sender);
    assert!(vouch::is_valid_voucher_for(voucher, addr), EU_NO_VOUCHER);

    let current_set = stake::get_current_validators();
    let (vouchers_in_set, _) = vouch::true_friends_in_list(addr, &current_set);

    let (is_found, _idx) = vector::index_of(&vouchers_in_set, &voucher);
    assert!(is_found, EVOUCHER_NOT_IN_SET);

    unjail(addr);
  }

  fun unjail(addr: address) acquires Jail {
    if (exists<Jail>(addr)) {
      borrow_global_mut<Jail>(addr).is_jailed = false;
    };
  }

  /// Sort validators based on their jail reputation
  /// this is used in the bidding process for Proof-of-Fee where
  /// we seat the validators with the least amount of consecutive failures
  /// to rejoin.
  public(friend) fun sort_by_jail(vec_address: vector<address>): vector<address> acquires Jail {
    // get the reputation of the validators
    let reputation = vector::map(vec_address, |addr| {
      let (_, value) = get_jail_reputation(addr);
      value
    });

    // sort the validators based on their reputation
    address_utils::sort_by_values(&mut vec_address, &mut reputation);
    // shuffle duplicates scores to ensure fairness
    address_utils::shuffle_duplicates(&mut vec_address, &reputation);

    vec_address
  }

  /// the Vouchers who vouched for a jailed validator
  /// will get a reputation mark. This is informational currently not used
  /// for any consensus admission or weight etc.
  fun inc_voucher_jail(addr: address) acquires Jail {
    let buddies = vouch::true_friends(addr);
    let i = 0;
    while (i < vector::length(&buddies)) {
      let voucher = *vector::borrow(&buddies, i);
      if (exists<Jail>(voucher)) {
        let v = borrow_global_mut<Jail>(voucher);
        v.lifetime_vouchees_jailed = v.lifetime_vouchees_jailed + 1;
      };
      i = i + 1;
    }
  }

  ///////// GETTERS //////////

  #[view]
  /// Returns how many times has the validator failed to join the network after consecutive attempts.
  /// Should not abort, since its used in validator admission.
  /// Returns (lifetime_jailed, consecutive_failure_to_rejoin)
  public fun get_jail_reputation(addr: address): (u64, u64) acquires Jail {
    if (exists<Jail>(addr)) {
      let s = borrow_global<Jail>(addr);
      return (s.lifetime_jailed, s.consecutive_failure_to_rejoin)
    };
    (0, 0)
  }

  #[view]
  /// Returns the cumulative number of times someone a validator vouched for (vouchee) was jailed. I.e. are they picking performant validators.
  public fun get_count_buddies_jailed(addr: address): u64 acquires Jail {
    if (exists<Jail>(addr)) {
      return borrow_global<Jail>(addr).lifetime_vouchees_jailed
    };
    0
  }

  #[view]
  public fun exists_jail(addr: address): bool {
    exists<Jail>(addr)
  }

}
