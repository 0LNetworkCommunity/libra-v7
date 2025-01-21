/////////////////////////////////////////////////////////////////////////
// 0L Module
// Secret Bid
// Implements a commit-reveal scheme for more private bidding in PoF auction
///////////////////////////////////////////////////////////////////////////

module ol_framework::secret_bid {
  use std::bcs;
  use std::error;
  use std::hash;
  use std::signer;
  use std::vector;

  use diem_std::ed25519;
  use diem_std::comparator;
  use diem_framework::epoch_helper;
  use diem_framework::reconfiguration;
  use diem_framework::system_addresses;

  use ol_framework::testnet;
  use ol_framework::address_utils;

  friend ol_framework::genesis;
  friend ol_framework::proof_of_fee;

  #[test_only]
  use diem_framework::account;

  #[test_only]
  friend ol_framework::test_boundary;
  #[test_only]
  friend ol_framework::mock;
  #[test_only]
  friend ol_framework::test_pof;

  /// User bidding not initialized
  const ECOMMIT_BID_NOT_INITIALIZED: u64 = 1;
  /// Invalid signature on bid message
  const EINVALID_SIGNATURE: u64 = 2;
  /// Must reveal bid in same epoch as committed
  const EMISMATCH_EPOCH: u64 = 3;
  /// Must submit bid before reveal window opens, and reveal bid only after.
  const ENOT_IN_REVEAL_WINDOW: u64 = 4;
  /// Bad Alice, the reveal does not match the commit
  const ECOMMIT_DIGEST_NOT_EQUAL: u64 = 5;
  /// Bid is for different epoch, expired
  const EBID_EXPIRED: u64 = 6;

  struct CommittedBid has key {
    reveal_entry_fee: u64,
    entry_fee_history: vector<u64>, // keep previous 7 days bids
    commit_digest: vector<u8>,
    commit_epoch: u64,
  }

  struct Bid has drop, copy {
    entry_fee: u64,
    epoch: u64,
  }

  public(friend) fun genesis_helper(framework: &signer, validator: &signer, entry_fee: u64) acquires CommittedBid {
    system_addresses::assert_diem_framework(framework);
    commit_entry_fee_impl(validator, b"genesis");

    let state = borrow_global_mut<CommittedBid>(signer::address_of(validator));
    state.reveal_entry_fee = entry_fee;
  }

  /// Transaction entry function for committing bid
  public entry fun commit(user: &signer, digest: vector<u8>) acquires CommittedBid {
    // don't allow commiting within reveal window
    assert!(!in_reveal_window(), error::invalid_state(ENOT_IN_REVEAL_WINDOW));
    commit_entry_fee_impl(user, digest);
  }

  /// Transaction entry function for revealing bid
  public entry fun reveal(user: &signer, pk: vector<u8>, entry_fee: u64, signed_msg: vector<u8>) acquires CommittedBid {
    // don't allow commiting within reveal window
    assert!(in_reveal_window(), error::invalid_state(ENOT_IN_REVEAL_WINDOW));
    reveal_entry_fee_impl(user, pk, entry_fee, signed_msg);
  }

  /// user transaction for setting a signed message with the bid
  fun commit_entry_fee_impl(user: &signer, digest: vector<u8>) acquires CommittedBid {

    if (!is_init(signer::address_of(user))) {
      move_to<CommittedBid>(user, CommittedBid {
        reveal_entry_fee: 0,
        entry_fee_history: vector::empty(),
        commit_digest: vector::empty(),
        commit_epoch: 0,
      });
    };

    let state = borrow_global_mut<CommittedBid>(signer::address_of(user));
    // if first commit in an epoch reset the counters
    maybe_reset_bids(state);

    state.commit_digest = digest;
  }

  /// if this is the first commit in the epoch then we can reset bids
  fun maybe_reset_bids(state: &mut CommittedBid) {
    if (epoch_helper::get_current_epoch() > state.commit_epoch) {
      // restart bidding
      state.commit_epoch = epoch_helper::get_current_epoch();

      vector::push_back(&mut state.entry_fee_history, state.reveal_entry_fee);

      if (vector::length(&state.entry_fee_history) > 7) {
        vector::trim(&mut state.entry_fee_history, 7);
      };

      state.reveal_entry_fee = 0;
    }
  }

  /// The hashing protocol which the client will be submitting commitments
  /// instead of a sequence number, we are using the signed message for hashing nonce, which would be private to the validator before the reveal.
  // TODO: should we also use a salt or overkill for these purposes?
  fun make_hash(entry_fee: u64, epoch: u64, signed_message: vector<u8>): vector<u8>{
    let bid = Bid {
      entry_fee,
      epoch,
    };

    let bid_bytes = bcs::to_bytes(&bid);
    vector::append(&mut bid_bytes, copy signed_message);
    let commitment = hash::sha3_256(bid_bytes);
    commitment
  }

  /// user sends transaction  which takes the committed signed message
  /// submits the public key used to sign message, which we compare to the authentication key.
  /// we use the epoch as the sequence number, so that messages are different on each submission.
  public fun reveal_entry_fee_impl(user: &signer, pk: vector<u8>, entry_fee: u64, signed_msg: vector<u8>) acquires CommittedBid {
    assert!(is_init(signer::address_of(user)), error::invalid_state(ECOMMIT_BID_NOT_INITIALIZED));

    let state = borrow_global_mut<CommittedBid>(signer::address_of(user));
    // must reveal within the current epoch of the bid
    let epoch = epoch_helper::get_current_epoch();
    assert!(epoch == state.commit_epoch, error::invalid_state(EMISMATCH_EPOCH));

    let commitment = make_hash(entry_fee, epoch, signed_msg);

    let bid = Bid {
      entry_fee,
      epoch,
    };

    check_signature(pk, signed_msg, bid);

    assert!(comparator::is_equal(&comparator::compare(&commitment, &state.commit_digest)), error::invalid_argument(ECOMMIT_DIGEST_NOT_EQUAL));

    state.reveal_entry_fee = entry_fee;
  }

  fun check_signature(account_public_key_bytes: vector<u8>, signed_message_bytes: vector<u8>, bid_message: Bid) {
    let pubkey = ed25519::new_unvalidated_public_key_from_bytes(account_public_key_bytes);

    // confirm that the signature bytes belong to the message (the Bid struct)
    let sig = ed25519::new_signature_from_bytes(signed_message_bytes);
    assert!(ed25519::signature_verify_strict_t(&sig, &pubkey, bid_message), error::invalid_argument(EINVALID_SIGNATURE));

    /////////
    // NOTE: previously we would check if the public key for the signed message
    // belonged to this account. However that is not necessary for prevention of the replay attack. Any ed25519 key pair would be acceptable for producing the nonce, and the user may prefer to use one that is different than their main account's key.
    // let expected_auth_key = ed25519::unvalidated_public_key_to_authentication_key(&pubkey);
    // assert!(account::get_authentication_key(signer::address_of(user)) == expected_auth_key, error::invalid_argument(EWRONG_CURRENT_PUBLIC_KEY));
    ////////
  }

  /// populate the list of bids, but don't sort
  fun get_bids_for_account_list(list: vector<address>): (vector<address>, vector<u64>) acquires CommittedBid {
    let bids_vec = vector<u64>[];
    vector::for_each_ref(&list, |el| {
      let b = get_bid_unchecked(*el);
      vector::push_back(&mut bids_vec, b);
    });

    (list, bids_vec)
  }

  /// get a sorted list of the addresses and their entry fee
  public(friend) fun get_bids_by_account_sort_low_high(list: vector<address>): (vector<address>, vector<u64>) acquires CommittedBid {
    let (addr, bids) = get_bids_for_account_list(list);
    address_utils::sort_by_values(&mut addr, &mut bids);
    (addr, bids)
  }

  ///////// GETTERS ////////

  public(friend) fun get_bid_unchecked(user: address): u64 acquires CommittedBid {
    let state = borrow_global<CommittedBid>(user);

    state.reveal_entry_fee
  }

  #[view]
  /// check if we are within the reveal window
  /// do not allow bids within the reveal window
  /// allow reveal transaction to be submitted
  public fun in_reveal_window(): bool {
    // get the timestamp
    let remaining_secs = reconfiguration::get_remaining_epoch_secs();
    let window = if (testnet::is_testnet()) {
      // ten secs
      10
    } else {
      // five mins
      60*5
    };

    if (remaining_secs > window) {
      return false
    };
    true
  }

  #[view]
  public fun is_init(account: address): bool {
    exists<CommittedBid>(account)
  }

  #[view]
  /// get the current bid, and exclude bids that are stale
  public fun current_revealed_bid(user: address): u64 acquires CommittedBid {
    // // if we are not in reveal window this information will be confusing.
    // assert!(in_reveal_window(), error::invalid_state(ENOT_IN_REVEAL_WINDOW));

    // let state = borrow_global<CommittedBid>(user);
    // assert!(state.commit_epoch == epoch_helper::get_current_epoch(), error::invalid_state(EBID_EXPIRED));

    // state.reveal_entry_fee
    get_bid_unchecked(user)
  }

   /// Find the most recent epoch the validator has placed a bid on.
  public(friend) fun latest_epoch_bid(user: address): u64 acquires CommittedBid {
    let state = borrow_global<CommittedBid>(user);
    state.commit_epoch
  }

  /// does the user have a current bid
  public(friend) fun has_valid_bid(user: address): bool acquires CommittedBid {
    let state = borrow_global<CommittedBid>(user);
    state.commit_epoch == epoch_helper::get_current_epoch()
  }

  /// will abort if bid is not valid
  fun assert_valid_bid(user: address) acquires CommittedBid {
    // if we are not in reveal window this information will be confusing.
    assert!(in_reveal_window(), error::invalid_state(ENOT_IN_REVEAL_WINDOW));

    assert!(has_valid_bid(user), error::invalid_state(EBID_EXPIRED));
  }

  #[view]
  /// get the current bid, and exclude bids that are stale
  public fun historical_bids(user: address): vector<u64> acquires CommittedBid {
    let state = borrow_global<CommittedBid>(user);
    state.entry_fee_history
  }

  //////// TESTS ////////

  #[test_only]
  public(friend) fun mock_revealed_bid(framework: &signer, user: &signer, reveal_entry_fee: u64, commit_epoch: u64) acquires CommittedBid {
    system_addresses::assert_diem_framework(framework);
    testnet::assert_testnet(framework);
    let user_addr = signer::address_of(user);
    if (!exists<CommittedBid>(user_addr)) {
      move_to(user, CommittedBid {
        reveal_entry_fee,
        entry_fee_history: vector[0],
        commit_digest: vector[0],
        commit_epoch,
      });
    } else {
      let state = borrow_global_mut<CommittedBid>(user_addr);
      state.reveal_entry_fee = reveal_entry_fee;
      state.commit_epoch = commit_epoch;
    }

  }

  #[test]
  fun test_sign_message() {
      use diem_std::from_bcs;

      let (new_sk, new_pk) = ed25519::generate_keys();
      let new_pk_unvalidated = ed25519::public_key_to_unvalidated(&new_pk);
      let new_auth_key = ed25519::unvalidated_public_key_to_authentication_key(&new_pk_unvalidated);
      let new_addr = from_bcs::to_address(new_auth_key);
      let _alice = account::create_account_for_test(new_addr);

      let message = Bid {
        entry_fee: 0,
        epoch: 0,
      };

      let to_sig = ed25519::sign_struct(&new_sk, copy message);
      let sig_bytes = ed25519::signature_to_bytes(&to_sig);
      // end set-up

      // yes repetitive, but following the same workflow
      let sig_again = ed25519::new_signature_from_bytes(sig_bytes);

      assert!(ed25519::signature_verify_strict_t<Bid>(&sig_again, &new_pk_unvalidated, message), error::invalid_argument(EINVALID_SIGNATURE));


  }

  #[test]
  fun test_check_signature() {
      use diem_std::from_bcs;

      let (new_sk, new_pk) = ed25519::generate_keys();
      let new_pk_unvalidated = ed25519::public_key_to_unvalidated(&new_pk);
      let new_auth_key = ed25519::unvalidated_public_key_to_authentication_key(&new_pk_unvalidated);
      let new_addr = from_bcs::to_address(new_auth_key);
      let _alice = account::create_account_for_test(new_addr);

      let message = Bid {
        entry_fee: 0,
        epoch: 0,
      };

      let to_sig = ed25519::sign_struct(&new_sk, copy message);
      let sig_bytes = ed25519::signature_to_bytes(&to_sig);
      // end set-up

      // yes repetitive, but following the same workflow
      let sig_again = ed25519::new_signature_from_bytes(sig_bytes);

      assert!(ed25519::signature_verify_strict_t<Bid>(&sig_again, &new_pk_unvalidated, copy message), error::invalid_argument(EINVALID_SIGNATURE));

      let pk_bytes = ed25519::unvalidated_public_key_to_bytes(&new_pk_unvalidated);

      check_signature(pk_bytes, sig_bytes, message);

  }

  #[test]
  #[expected_failure(abort_code = 65538, location = Self)]
  fun test_check_signature_sad() {
      use diem_std::from_bcs;

      let (new_sk, new_pk) = ed25519::generate_keys();
      let new_pk_unvalidated = ed25519::public_key_to_unvalidated(&new_pk);
      let new_auth_key = ed25519::unvalidated_public_key_to_authentication_key(&new_pk_unvalidated);
      let new_addr = from_bcs::to_address(new_auth_key);
      let _alice = account::create_account_for_test(new_addr);

      let message = Bid {
        entry_fee: 0,
        epoch: 0,
      };

      let to_sig = ed25519::sign_struct(&new_sk, copy message);
      let sig_bytes = ed25519::signature_to_bytes(&to_sig);
      // end set-up

      // yes repetitive, but following the same workflow
      let sig_again = ed25519::new_signature_from_bytes(sig_bytes);

      assert!(ed25519::signature_verify_strict_t<Bid>(&sig_again, &new_pk_unvalidated, copy message), error::invalid_argument(EINVALID_SIGNATURE));

      let pk_bytes = ed25519::unvalidated_public_key_to_bytes(&new_pk_unvalidated);

      let message = Bid {
        entry_fee: 2, // incorrect
        epoch: 0,
      };

      check_signature(pk_bytes, sig_bytes, message);

  }


  #[test(framework = @0x1)]
  fun test_commit_message(framework: &signer) acquires CommittedBid {
      use diem_std::from_bcs;

      let this_epoch = 1;
      epoch_helper::test_set_epoch(framework, this_epoch);

      let (new_sk, new_pk) = ed25519::generate_keys();
      let new_pk_unvalidated = ed25519::public_key_to_unvalidated(&new_pk);
      let new_auth_key = ed25519::unvalidated_public_key_to_authentication_key(&new_pk_unvalidated);
      let new_addr = from_bcs::to_address(new_auth_key);
      let alice = account::create_account_for_test(new_addr);
      let entry_fee = 5;
      let epoch = 0;

      let message = Bid {
        entry_fee,
        epoch,
      };

      let to_sig = ed25519::sign_struct(&new_sk, copy message);
      let sig_bytes = ed25519::signature_to_bytes(&to_sig);
      let digest = make_hash(entry_fee, epoch, sig_bytes);
      // end set-up

      commit_entry_fee_impl(&alice, digest);
  }

  #[test(framework = @0x1)]
  fun test_reveal(framework: &signer) acquires CommittedBid {
      use diem_std::from_bcs;

      let epoch = 1;
      epoch_helper::test_set_epoch(framework, epoch);

      let (new_sk, new_pk) = ed25519::generate_keys();
      let new_pk_unvalidated = ed25519::public_key_to_unvalidated(&new_pk);
      let new_auth_key = ed25519::unvalidated_public_key_to_authentication_key(&new_pk_unvalidated);
      let new_addr = from_bcs::to_address(new_auth_key);
      let alice = account::create_account_for_test(new_addr);
      let entry_fee = 5;
      let message = Bid {
        entry_fee,
        epoch,
      };

      let to_sig = ed25519::sign_struct(&new_sk, copy message);
      let sig_bytes = ed25519::signature_to_bytes(&to_sig);
      let digest = make_hash(entry_fee, epoch, sig_bytes);
      // end set-up

      commit_entry_fee_impl(&alice, digest);

      let pk_bytes = ed25519::unvalidated_public_key_to_bytes(&new_pk_unvalidated);

      check_signature(pk_bytes, sig_bytes, message);

      reveal_entry_fee_impl(&alice, pk_bytes, 5, sig_bytes);
  }

  #[test(framework = @0x1)]
  #[expected_failure(abort_code = 65538, location = Self)]
  fun test_reveal_sad_wrong_epoch(framework: &signer) acquires CommittedBid {
      use diem_std::from_bcs;
      let epoch = 1;
      epoch_helper::test_set_epoch(framework, epoch);

      let (new_sk, new_pk) = ed25519::generate_keys();
      let new_pk_unvalidated = ed25519::public_key_to_unvalidated(&new_pk);
      let new_auth_key = ed25519::unvalidated_public_key_to_authentication_key(&new_pk_unvalidated);
      let new_addr = from_bcs::to_address(new_auth_key);
      let alice = account::create_account_for_test(new_addr);
      let entry_fee = 5;
      let wrong_epoch = 100;

      let message = Bid {
        entry_fee,
        epoch: wrong_epoch, // wrong epoch, we are at 1
      };

      let to_sig = ed25519::sign_struct(&new_sk, copy message);
      let sig_bytes = ed25519::signature_to_bytes(&to_sig);
      let digest = make_hash(entry_fee, epoch, sig_bytes);
      // end set-up

      commit_entry_fee_impl(&alice, digest);

      let pk_bytes = ed25519::unvalidated_public_key_to_bytes(&new_pk_unvalidated);

      check_signature(pk_bytes, sig_bytes, message);

      reveal_entry_fee_impl(&alice, pk_bytes, 5, sig_bytes);
  }

  #[test(framework = @0x1, alice = @0x10001, bob = @0x10002, carol = @0x10003)]
  fun test_sorting_secret_bids(framework: &signer, alice: &signer, bob: &signer, carol: &signer) acquires CommittedBid {
    testnet::initialize(framework);

    let this_epoch = 1;
    epoch_helper::test_set_epoch(framework, this_epoch);

    mock_revealed_bid(framework, alice, 234, this_epoch);
    mock_revealed_bid(framework, bob, 1, this_epoch);
    mock_revealed_bid(framework, carol, 30, this_epoch);

    let (accounts, bids) = get_bids_for_account_list(vector[@0x10001, @0x10002, @0x10003]);

    assert!(*vector::borrow(&accounts, 0) == @0x10001, 713570001);
    assert!(*vector::borrow(&bids, 0) == 234, 713570002);

    let (sorted_accounts, sorted_bids) = get_bids_by_account_sort_low_high(vector[@0x10001, @0x10002, @0x10003]);
    assert!(*vector::borrow(&sorted_accounts, 0) == @0x10002, 713570003);
    assert!(*vector::borrow(&sorted_bids, 0) == 1, 713570004);
  }
}
