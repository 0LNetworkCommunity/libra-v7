#[test_only]

module ol_framework::test_safe {
  use ol_framework::mock;
  use ol_framework::safe;
  use ol_framework::ol_account;
  use ol_framework::multi_action;
  use std::signer;
  use std::option;
  use std::vector;
  use diem_framework::resource_account;

  // use diem_std::debug::print;

  // NOTE: Most of the save.move features are tested in multi_action (e.g. governance). Here we are testing for specific APIs.

  #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, dave = @0x1000d )]
  fun propose_payment_happy(root: &signer, alice: &signer, bob: &signer, dave: &signer, ) {
    use ol_framework::ol_account;

    let vals = mock::genesis_n_vals(root, 2);
    mock::ol_initialize_coin_and_fund_vals(root, 10000000, true);
    // Dave creates the resource account. HE is not one of the validators, and is not an authority in the multisig.
    let (resource_sig, _cap) = ol_account::test_ol_create_resource_account(dave, b"0x1");
    let new_resource_address = signer::address_of(&resource_sig);
    assert!(resource_account::is_resource_account(new_resource_address), 0);

    // fund the account
    ol_account::transfer(alice, new_resource_address, 100);
    // make the vals the signers on the safe
    // SO ALICE and DAVE ARE AUTHORIZED

    safe::init_payment_multisig(&resource_sig, vals);

    // vals claim the offer
    multi_action::claim_offer(alice, new_resource_address);
    multi_action::claim_offer(bob, new_resource_address);

    //need to be caged to finalize multi action workflow and release control of the account
    multi_action::finalize_and_cage(&resource_sig, vector::length(&vals));

    // first make sure dave is initialized to receive LibraCoin
    ol_account::create_account(root, @0x1000d);
    // when alice proposes, she also votes in a single step
    let prop_id = safe::propose_payment(alice, new_resource_address, @0x1000d, 42, b"cheers", option::none());

    // vote should pass after bob also votes
    let passed = safe::vote_payment(bob, new_resource_address, &prop_id);
    assert!(passed, 1);
    let (_, total_dave) = ol_account::balance(@0x1000d);
    assert!(total_dave == 42, 2);
  }

  #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c, eve = @0x1000e)]
  fun propose_payment_should_fail(root: &signer, alice: &signer, bob: &signer, carol: &signer, eve: &signer) {
    use ol_framework::ol_account;

    let vals = mock::genesis_n_vals(root, 4);
    mock::ol_initialize_coin_and_fund_vals(root, 10000000, true);
    // Eve creates the resource account, is not one of the validators, and is not an authority in the multisig.
    let (resource_sig, _cap) = ol_account::test_ol_create_resource_account(eve, b"0x1");
    let new_resource_address = signer::address_of(&resource_sig);
    assert!(resource_account::is_resource_account(new_resource_address), 0);

    // fund the account
    ol_account::transfer(alice, new_resource_address, 100);
    // make the vals the signers on the safe
    // SO ALICE, BOB, CAROL, DAVE ARE AUTHORIZED
    // not enough voters
    safe::init_payment_multisig(&resource_sig, vals); // requires 3

    // vals claim the offer
    multi_action::claim_offer(alice, new_resource_address);
    multi_action::claim_offer(bob, new_resource_address);
    multi_action::claim_offer(carol, new_resource_address);

    //need to be caged to finalize multi action workflow and release control of the account
    multi_action::finalize_and_cage(&resource_sig, 3);

    // first make sure EVE is initialized to receive LibraCoin
    ol_account::create_account(root, @0x1000e);
    // when alice proposes, she also votes in a single step
    let prop_id = safe::propose_payment(alice, new_resource_address, @0x1000e, 42, b"cheers", option::none());

    // vote should pass after bob also votes
    let passed = safe::vote_payment(bob, new_resource_address, &prop_id);
    assert!(!passed, 1);
    let (_, total_dave) = ol_account::balance(@0x1000e);
    assert!(total_dave == 0, 2);
  }

  #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c, dave = @0x1000d )]
  fun safe_root_security_fee(root: &signer, alice: &signer, bob: &signer, carol: &signer, dave: &signer) {

    let vals = mock::genesis_n_vals(root, 3);
    let balance = 100_000_000;
    mock::ol_initialize_coin_and_fund_vals(root, balance, true);
    // Dave creates the resource account. HE is not one of the validators, and is not an authority in the multisig.
    let (resource_sig, _cap) = ol_account::test_ol_create_resource_account(dave, b"0x1");
    let new_resource_address = signer::address_of(&resource_sig);
    assert!(resource_account::is_resource_account(new_resource_address), 0);

    safe::init_payment_multisig(&resource_sig, vals); // requires 3

    // vals claim the offer
    multi_action::claim_offer(alice, new_resource_address);
    multi_action::claim_offer(bob, new_resource_address);
    multi_action::claim_offer(carol, new_resource_address);

    //need to be caged to finalize multi action workflow and release control of the account
    multi_action::finalize_and_cage(&resource_sig, 2);

    // fund the account
    ol_account::transfer(alice, new_resource_address, 100_000);
    let (_, bal) = ol_account::balance(new_resource_address);

    mock::trigger_epoch(root);

    // Use of Safe should debit the account at epoch boundary
    let (_, new_bal) = ol_account::balance(new_resource_address);
    assert!(new_bal < bal, 735701);
  }
}
