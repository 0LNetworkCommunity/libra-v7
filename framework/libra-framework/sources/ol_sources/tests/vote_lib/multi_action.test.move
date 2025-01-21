#[test_only]
module ol_framework::test_multi_action {
    use ol_framework::mock;
    use ol_framework::multi_action;
    use ol_framework::multisig_account;
    use ol_framework::safe;
    use std::signer;
    use std::option;
    use std::vector;
    use std::guid;
    use ol_framework::ol_account;
    use diem_framework::resource_account;
    use diem_framework::reconfiguration;
    use diem_framework::account;

    // print
    //use std::debug::print;

    struct DummyType has drop, store {}

    #[test(root = @ol_framework, carol = @0x1000c)]
    fun init_multi_action(root: &signer, carol: &signer) {
        mock::genesis_n_vals(root, 2);

        let (resource_sig, _cap) = ol_account::test_ol_create_resource_account(carol, b"0x1");
        let new_resource_address = signer::address_of(&resource_sig);
        assert!(resource_account::is_resource_account(new_resource_address), 7357001);

        // make the vals the signers on the safe
        multi_action::init_gov(&resource_sig);
        multi_action::init_type<DummyType>(&resource_sig, true);
    }

    // Happy Day: propose offer to authorities
    #[test(root = @ol_framework, carol = @0x1000c, alice = @0x1000a, bob = @0x1000b)]
    fun propose_offer(root: &signer, carol: &signer) {
        mock::genesis_n_vals(root, 4);
        let carol_address = @0x1000c;

        // check the offer does not exist
        assert!(!multi_action::exists_offer(carol_address), 7357001);
        assert!(!multi_action::is_multi_action(carol_address), 7357002);
        assert!(!multi_action::exists_offer(carol_address), 7357003);

        // initialize the multi_action account
        multi_action::init_gov(carol);
        assert!(multi_action::exists_offer(carol_address), 7357004);

        // offer authorities
        multi_action::propose_offer(carol, vector[@0x1000a, @0x1000b], option::none());

        // check the offer is proposed and account is not muti_action yet
        assert!(multi_action::exists_offer(carol_address), 7357005);
        assert!(multi_action::get_offer_proposed(carol_address) == vector[@0x1000a, @0x1000b], 7357006);
        assert!(multi_action::get_offer_claimed(carol_address) == vector::empty(), 7357007);
        assert!(vector::is_empty(&multi_action::get_offer_claimed(carol_address)), 7357008);
        assert!(multi_action::get_offer_expiration_epoch(carol_address) == vector[7, 7], 7357009);
        assert!(!multi_action::is_multi_action(carol_address), 7357010);
    }

    // Propose new offer after expired
    #[test(root = @ol_framework, carol = @0x1000c, alice = @0x1000a, bob = @0x1000b)]
    fun propose_offer_after_expired(root: &signer, carol: &signer) {
        mock::genesis_n_vals(root, 3);
        let carol_address = @0x1000c;

        // initialize the multi_action account
        multi_action::init_gov(carol);

        // offer to alice
        multi_action::propose_offer(carol, vector[@0x1000a], option::some(2));

        // check the offer is valid
        assert!(multi_action::get_offer_expiration_epoch(carol_address) == vector[2], 7357004);

        // wait for the offer to expire
        mock::trigger_epoch(root); // epoch 1 valid
        mock::trigger_epoch(root); // epoch 2 expired
        assert!(multi_action::is_offer_expired(carol_address, @0x1000a), 7357005);

        // propose a new offer to bob
        multi_action::propose_offer(carol, vector[@0x1000b], option::some(3));

        // check the new offer is proposed
        assert!(multi_action::get_offer_proposed(carol_address) == vector[@0x1000b], 7357007);
        assert!(multi_action::get_offer_claimed(carol_address) == vector::empty(), 7357008);
        assert!(multi_action::get_offer_expiration_epoch(carol_address) == vector[5], 7357009);
    }

    // Happy Day: claim offer by authorities
    #[test(root = @ol_framework, carol = @0x1000c, alice = @0x1000a, bob = @0x1000b)]
    fun claim_offer(root: &signer, carol: &signer, alice: &signer, bob: &signer) {
        mock::genesis_n_vals(root, 2);
        let carol_address = @0x1000c;

        // initialize the multi_action account
        multi_action::init_gov(carol);

        // invite the vals to the resource account
        multi_action::propose_offer(carol, vector[@0x1000a, @0x1000b], option::none());

        // bob claim the offer
        multi_action::claim_offer(bob, carol_address);

        // check the claimed offer
        assert!(multi_action::exists_offer(carol_address), 7357001);
        let claimed = vector[signer::address_of(bob)];
        let proposed = vector[signer::address_of(alice)];
        assert!(multi_action::get_offer_claimed(carol_address) == claimed, 7357002);
        assert!(multi_action::get_offer_proposed(carol_address) == proposed, 7357003);

        // alice claim the offer
        multi_action::claim_offer(alice, carol_address);

        // check alice and bob claimed the offer
        let claimed = multi_action::get_offer_claimed(carol_address);
        assert!(claimed == vector[@0x1000b, @0x1000a], 7357004);
        assert!(multi_action::get_offer_proposed(carol_address) == vector::empty(), 7357005);
    }

    // Happy Day: finalize multisign account
    #[test(root = @ol_framework, carol = @0x1000c, alice = @0x1000a, bob = @0x1000b)]
    fun finalize_multi_action(root: &signer, carol: &signer, alice: &signer, bob: &signer) {
        mock::genesis_n_vals(root, 3);
        let carol_address = @0x1000c;

        // initialize the multi_action account
        multi_action::init_gov(carol);

        // invite the vals to the resource account
        multi_action::propose_offer(carol, vector[@0x1000a, @0x1000b], option::none());

        // authorities claim the offer
        multi_action::claim_offer(alice, carol_address);
        multi_action::claim_offer(bob, carol_address);

        // finalize the multi_action account
        assert!(account::exists_at(carol_address), 7357001);
        multi_action::finalize_and_cage(carol, 2);

        // check the account is multi_action
        assert!(multi_action::is_multi_action(carol_address), 7357002);

        // check authorities
        let authorities = multi_action::get_authorities(carol_address);
        assert!(authorities == vector[@0x1000a, @0x1000b], 7357003);

        // check offer was cleaned
        assert!(multi_action::get_offer_proposed(carol_address) == vector::empty(), 7357004);
        assert!(multi_action::get_offer_claimed(carol_address) == vector::empty(), 7357005);
        assert!(multi_action::get_offer_expiration_epoch(carol_address) == vector::empty(), 7357006);
    }

    // Finalize multisign account having a pending claim
    #[test(root = @ol_framework, carol = @0x1000c, alice = @0x1000a, bob = @0x1000b, dave = @0x1000d)]
    fun finalize_with_pending_claim(root: &signer, carol: &signer, alice: &signer, bob: &signer) {
        mock::genesis_n_vals(root, 4);
        let carol_address = @0x1000c;

        // initialize the multi_action account
        multi_action::init_gov(carol);

        // invite the vals to the resource account
        multi_action::propose_offer(carol, vector[@0x1000a, @0x1000b, @0x1000d], option::none());

        // authorities claim the offer
        multi_action::claim_offer(alice, carol_address);
        multi_action::claim_offer(bob, carol_address);

        // finalize the multi_action account
        assert!(account::exists_at(carol_address), 7357001);
        multi_action::finalize_and_cage(carol, 2);

        // check the account is multi_action
        assert!(multi_action::is_multi_action(carol_address), 7357002);

        // check authorities
        let authorities = multi_action::get_authorities(carol_address);
        assert!(authorities == vector[@0x1000a, @0x1000b], 7357003);

        // check offer was cleared
        assert!(multi_action::get_offer_proposed(carol_address) == vector::empty(), 7357004);
        assert!(multi_action::get_offer_claimed(carol_address) == vector::empty(), 7357005);
        assert!(multi_action::get_offer_expiration_epoch(carol_address) == vector::empty(), 7357006);
    }

    // Propose another offer with different authorities
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c, dave = @0x1000d)]
    fun propose_another_offer_different_authorities(root: &signer, alice: &signer) {
        mock::genesis_n_vals(root, 4);
        multi_action::init_gov(alice);

        // invite bob
        multi_action::propose_offer(alice, vector[@0x1000b], option::some(1));

        // invite carol and dave
        multi_action::propose_offer(alice, vector[@0x1000c, @0x1000d], option::some(2));

        // check new authorities
        assert!(multi_action::get_offer_expiration_epoch(@0x1000a) == vector[2, 2], 7357001);
        assert!(multi_action::get_offer_proposed(@0x1000a) == vector[@0x1000c, @0x1000d], 7357002);
        assert!(multi_action::get_offer_claimed(@0x1000a) == vector::empty(), 7357003);
    }

    // Propose new offer with more authorities
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c, dave = @0x1000d)]
    fun propose_offer_more_authorities(root: &signer, alice: &signer, carol: &signer) {
        mock::genesis_n_vals(root, 4);
        multi_action::init_gov(alice);

        // invite bob
        multi_action::propose_offer(alice, vector[@0x1000b], option::some(1));

        // new invite bob and carol
        multi_action::propose_offer(alice, vector[@0x1000b, @0x1000c], option::some(2));

        // check offer
        assert!(multi_action::get_offer_proposed(@0x1000a) == vector[@0x1000b, @0x1000c], 7357001);
        assert!(multi_action::get_offer_claimed(@0x1000a) == vector::empty(), 7357002);
        assert!(multi_action::get_offer_expiration_epoch(@0x1000a) == vector[2, 2], 7357003);

        // carol claim the offer
        multi_action::claim_offer(carol, @0x1000a);

        // new invite bob, carol and dave
        multi_action::propose_offer(alice, vector[@0x1000b, @0x1000c, @0x1000d], option::some(3));

        // check new authorities
        assert!(multi_action::get_offer_proposed(@0x1000a) == vector[@0x1000b, @0x1000d], 7357004);
        assert!(multi_action::get_offer_expiration_epoch(@0x1000a) == vector[3, 3], 7357003);
        assert!(multi_action::get_offer_claimed(@0x1000a) == vector[@0x1000c], 7357005);
    }

    // Propose new offer with less authorities
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c, dave = @0x1000d)]
    fun propose_offer_less_authorities(root: &signer, alice: &signer, carol: &signer) {
        mock::genesis_n_vals(root, 4);
        multi_action::init_gov(alice);

        // invite bob, carol e dave
        multi_action::propose_offer(alice, vector[@0x1000b, @0x1000c, @0x1000d], option::some(2));

        // new invite bob e carol
        let new_authorities = vector[@0x1000b, @0x1000c];
        multi_action::propose_offer(alice, new_authorities, option::some(3));

        // check new authorities minus dave
        assert!(multi_action::get_offer_proposed(@0x1000a) == new_authorities, 7357001);
        assert!(multi_action::get_offer_claimed(@0x1000a) == vector::empty(), 7357002);
        assert!(multi_action::get_offer_expiration_epoch(@0x1000a) == vector[3, 3], 7357003);

        // carol claim the offer
        multi_action::claim_offer(carol, @0x1000a);

        // new invite bob only
        multi_action::propose_offer(alice, vector[@0x1000b], option::some(4));

        // check new authorities minus carol
        assert!(multi_action::get_offer_proposed(@0x1000a) == vector[@0x1000b], 7357003);
        assert!(multi_action::get_offer_claimed(@0x1000a) == vector::empty(), 7357004);
    }

    // Propose new offer with same authorities
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c)]
    fun propose_offer_same_authorities(root: &signer, alice: &signer, bob: &signer) {
        mock::genesis_n_vals(root, 3);
        multi_action::init_gov(alice);

        // invite bob e carol
        let authorities = vector[@0x1000b, @0x1000c];
        multi_action::propose_offer(alice, authorities, option::some(2));

        // check offer
        assert!(multi_action::get_offer_proposed(@0x1000a) == authorities, 7357001);
        assert!(multi_action::get_offer_claimed(@0x1000a) == vector::empty(), 7357002);
        assert!(multi_action::get_offer_expiration_epoch(@0x1000a) == vector[2, 2], 7357003);

        // new invite bob e carol
        multi_action::propose_offer(alice, authorities, option::some(3));

        // check offer
        assert!(multi_action::get_offer_proposed(@0x1000a) == authorities, 7357001);
        assert!(multi_action::get_offer_claimed(@0x1000a) == vector::empty(), 7357002);
        assert!(multi_action::get_offer_expiration_epoch(@0x1000a) == vector[3, 3], 7357003);

        // bob claim the offer
        multi_action::claim_offer(bob, @0x1000a);

        // new invite bob e carol
        multi_action::propose_offer(alice, authorities, option::some(4));

        // check authorities
        assert!(multi_action::get_offer_expiration_epoch(@0x1000a) == vector[4], 7357002);
        assert!(multi_action::get_offer_proposed(@0x1000a) == vector[@0x1000c], 7357003);
        assert!(multi_action::get_offer_claimed(@0x1000a) == vector[@0x1000b], 7357004);
    }

    // Try to propose offer without governance
    #[test(root = @ol_framework, carol = @0x1000c, alice = @0x1000a, bob = @0x1000b)]
    #[expected_failure(abort_code = 0x30001, location = ol_framework::multi_action)]
    fun propose_offer_without_gov(root: &signer, carol: &signer) {
        mock::genesis_n_vals(root, 3);

        // invite the vals to the resource account
        multi_action::propose_offer(carol, vector[@0x1000a, @0x1000b], option::none());
    }

    // Try to propose offer to an multisig account
    #[test(root = @ol_framework, dave = @0x1000d, carol = @0x1000c, alice = @0x1000a, bob = @0x1000b)]
    #[expected_failure(abort_code = 0x30013, location = ol_framework::multi_action)]
    fun propose_offer_to_multisign(root: &signer, carol: &signer, alice: &signer, bob: &signer) {
        mock::genesis_n_vals(root, 4);
        let carol_address = @0x1000c;
        let dave_address = @0x1000d;
        multi_action::init_gov(carol);
        multi_action::propose_offer(carol, vector[@0x1000a, @0x1000b], option::none());
        multi_action::claim_offer(alice, carol_address);
        multi_action::claim_offer(bob, carol_address);
        multi_action::finalize_and_cage(carol, 2);

        // propose offer to multisig account
        multi_action::propose_offer(carol, vector[dave_address], option::none());
    }

    // Try to propose an empty offer
    #[test(root = @ol_framework, alice = @0x1000a)]
    #[expected_failure(abort_code = 0x10010, location = ol_framework::multi_action)]
    fun propose_empty_offer(root: &signer, alice: &signer) {
        mock::genesis_n_vals(root, 4);
        multi_action::init_gov(alice);
        multi_action::propose_offer(alice, vector::empty<address>(), option::none());
    }

    // Try to propose too many authorities
    #[test(root = @ol_framework, alice = @0x1000a)]
    #[expected_failure(abort_code = 0x10018, location = ol_framework::multi_action)]
    fun propose_too_many_authorities(root: &signer, alice: &signer) {
        mock::genesis_n_vals(root, 1);
        multi_action::init_gov(alice);
        let authorities = vector[@0x10001, @0x10002, @0x10003, @0x10004, @0x10005, @0x10006, @0x10007, @0x10008, @0x10009, @0x10010, @0x10011];
        multi_action::propose_offer(alice, authorities, option::none());
    }

    // Try to propose offer to the signer address
    #[test(root = @ol_framework, alice = @0x1000a)]
    #[expected_failure(abort_code = 0x1000D, location = ol_framework::multisig_account)]
    fun propose_offer_to_signer(root: &signer, alice: &signer) {
        mock::genesis_n_vals(root, 1);
        let alice_address = signer::address_of(alice);
        multi_action::init_gov(alice);
        multi_action::propose_offer(alice, vector::singleton<address>(alice_address), option::none());
    }

    // Try to propose offer with duplicated addresses
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c)]
    #[expected_failure(abort_code = 0x10001, location = ol_framework::multisig_account)]
    fun propose_offer_duplicated_authorities(root: &signer, alice: &signer) {
        mock::genesis_n_vals(root, 3);
        multi_action::init_gov(alice);
        multi_action::propose_offer(alice, vector[@0x1000b, @0x1000c, @0x1000b], option::none());
    }

    // Try to propose offer to an invalid signer
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b)]
    #[expected_failure(abort_code = 0x60012, location = ol_framework::multisig_account)]
    fun offer_to_invalid_authority(root: &signer, alice: &signer, bob: &signer) {
        mock::genesis_n_vals(root, 3);
        multi_action::init_gov(alice);

        // propose to invalid address
        let authorities = vector[signer::address_of(bob), @0xCAFE];
        multi_action::propose_offer(alice, authorities, option::some(2));
    }

    // Try to propose offer with zero duration epochs
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b)]
    #[expected_failure(abort_code = 0x10016, location = ol_framework::multi_action)]
    fun offer_with_zero_duration(root: &signer, alice: &signer) {
        mock::genesis_n_vals(root, 3);
        multi_action::init_gov(alice);
        multi_action::propose_offer(alice, vector[@0x1000b], option::some(0));
    }

    // Try to claim offer not offered to signer
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c)]
    #[expected_failure(abort_code = 0x60014, location = ol_framework::multi_action)]
    fun claim_offer_not_offered(root: &signer, alice: &signer, carol: &signer) {
        mock::genesis_n_vals(root, 3);
        let carol_address = @0x1000c;
        multi_action::init_gov(carol);

        // invite bob
        multi_action::propose_offer(carol, vector[@0x1000b], option::none());

        // alice try to claim the offer
        multi_action::claim_offer(alice, carol_address);
    }

    // Try to claim expired offer
    #[test(root = @ol_framework, carol = @0x1000c, alice = @0x1000a, bob = @0x1000b)]
    #[expected_failure(abort_code = 0x2000F, location = ol_framework::multi_action)]
    fun claim_expired_offer(root: &signer, carol: &signer, alice: &signer, bob: &signer) {
        mock::genesis_n_vals(root, 3);
        multi_action::init_gov(carol);

        // offer to alice and bob
        multi_action::propose_offer(carol, vector[@0x1000a, @0x1000b], option::some(2));

        // alice claim the offer
        multi_action::claim_offer(alice, @0x1000c);

        mock::trigger_epoch(root); // epoch 1 valid
        mock::trigger_epoch(root); // epoch 2 valid
        mock::trigger_epoch(root); // epoch 3 expired

        // bob claim expired offer
        multi_action::claim_offer(bob, @0x1000c);
    }

    // Try to claim offer of an account without proposal
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b)]
    #[expected_failure(abort_code = 0x60011, location = ol_framework::multi_action)]
    fun claim_offer_without_proposal(root: &signer, alice: &signer) {
        mock::genesis_n_vals(root, 2);
        multi_action::claim_offer(alice, @0x1000c);
    }

    // Try to claim offer twice
    #[test(root = @ol_framework, carol = @0x1000c, alice = @0x1000a, bob = @0x1000b)]
    #[expected_failure(abort_code = 0x80017, location = ol_framework::multi_action)]
    fun claim_offer_twice(root: &signer, carol: &signer, alice: &signer) {
        mock::genesis_n_vals(root, 3);
        let carol_address = @0x1000c;
        multi_action::init_gov(carol);
        multi_action::propose_offer(carol, vector[@0x1000a, @0x1000b], option::some(2));

        // Alice claim the offer twice
        multi_action::claim_offer(alice, carol_address);
        multi_action::claim_offer(alice, carol_address);
    }

    // Try to finalize account without governance
    #[test(root = @ol_framework, alice = @0x1000a)]
    #[expected_failure(abort_code = 0x30001, location = ol_framework::multi_action)]
    fun finalize_without_gov(root: &signer, alice: &signer) {
        mock::genesis_n_vals(root, 1);
        multi_action::finalize_and_cage(alice, 2);
    }

    // Try to finalize account without offer
    #[test(root = @ol_framework, alice = @0x1000a)]
    #[expected_failure(abort_code = 0x30012, location = ol_framework::multi_action)]
    fun finalize_without_offer(root: &signer, alice: &signer) {
        mock::genesis_n_vals(root, 1);
        multi_action::init_gov(alice);
        multi_action::finalize_and_cage(alice, 2);
    }

    // Try to finalize account without enough offer claimed
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c)]
    #[expected_failure(abort_code = 0x30012, location = ol_framework::multi_action)]
    fun finalize_without_enough_claimed(root: &signer, alice: &signer, bob: &signer) {
        mock::genesis_n_vals(root, 3);
        multi_action::init_gov(alice);

        // offer to bob and carol authority on the alice account
        multi_action::propose_offer(alice, vector[@0x1000b, @0x1000c], option::none());

        // bob claim the offer
        multi_action::claim_offer(bob, @0x1000a);

        // finalize the multi_action account
        multi_action::finalize_and_cage(alice, 2);
    }

    // Try to finalize account already finalized
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c)]
    #[expected_failure(abort_code = 0x80013, location = ol_framework::multi_action)]
    fun finalize_already_finalized(root: &signer, alice: &signer, bob: &signer, carol: &signer) {
        mock::genesis_n_vals(root, 3);
        let alice_address = @0x1000a;
        multi_action::init_gov(alice);

        // offer bob and carol authority on the alice account
        multi_action::propose_offer(alice, vector[@0x1000b, @0x1000c], option::none());

        // bob claim the offer
        multi_action::claim_offer(bob, alice_address);
        multi_action::claim_offer(carol, alice_address);

        // finalize the multi_action account
        multi_action::finalize_and_cage(alice, 2);
        multi_action::finalize_and_cage(alice, 2);
    }

    // Governance Tests

    // Happy Day: propose a new action and check zero votes
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c)]
    fun propose_action(root: &signer, alice: &signer, bob: &signer, carol: &signer) {
        mock::genesis_n_vals(root, 3);
        let alice_address = @0x1000a;

        // offer to bob and carol authority on the alice safe
        multi_action::init_gov(alice);
        multi_action::init_type<DummyType>(alice, true);
        multi_action::propose_offer(alice, vector[@0x1000b, @0x1000c], option::none());

        // bob and alice claim the offer
        multi_action::claim_offer(bob, alice_address);
        multi_action::claim_offer(carol, alice_address);

        // alice finalize multi action workflow to release control of the account
        multi_action::finalize_and_cage(alice, 2);

        // bob create a proposal
        let proposal = multi_action::proposal_constructor(DummyType{}, option::none());
        let id = multi_action::propose_new(bob, alice_address, proposal);

        // SHOULD NOT HAVE COUNTED ANY VOTES
        let v = multi_action::get_votes<DummyType>(alice_address, guid::id_creation_num(&id));
        assert!(vector::length(&v) == 0, 7357001);
    }

    // Try to propose an action to a non multisig account
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b)]
    #[expected_failure(abort_code = 0x30006, location = ol_framework::multi_action)]
    fun propose_action_to_non_multisig(root: &signer, alice: &signer) {
        mock::genesis_n_vals(root, 1);

        // alice try to create a proposal to bob account
        let proposal = multi_action::proposal_constructor(DummyType{}, option::none());
        let _id = multi_action::propose_new(alice, @0x1000b, proposal);
    }

    // Multisign authorities bob and carol try to send the same proposal
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c)]
    fun propose_action_prevent_duplicated(root: &signer, carol: &signer, alice: &signer, bob: &signer) {
        mock::genesis_n_vals(root, 3);
        let alice_address = @0x1000a;

        // offer to bob and carol authority on the alice safe
        multi_action::init_gov(alice);
        multi_action::init_type<DummyType>(alice, true);
        multi_action::propose_offer(alice, vector[@0x1000b, @0x1000c], option::none());

        // bob and alice claim the offer
        multi_action::claim_offer(bob, alice_address);
        multi_action::claim_offer(carol, alice_address);

        // alice finalize multi action workflow to release control of the account
        multi_action::finalize_and_cage(alice, 2);

        let count = multi_action::get_count_of_pending<DummyType>(alice_address);
        assert!(count == 0, 7357001);

        let proposal = multi_action::proposal_constructor(DummyType{}, option::none());
        let id = multi_action::propose_new(bob, alice_address, proposal);
        let count = multi_action::get_count_of_pending<DummyType>(alice_address);
        assert!(count == 1, 7357002);

        let epoch_ending = multi_action::get_expiration<DummyType>(alice_address, guid::id_creation_num(&id));
        assert!(epoch_ending == 14, 7357003);

        let proposal = multi_action::proposal_constructor(DummyType{}, option::none());
        multi_action::propose_new(carol, alice_address, proposal);
        let count = multi_action::get_count_of_pending<DummyType>(alice_address);
        assert!(count == 1, 7357004); // no change

        // confirm there are no votes
        let v = multi_action::get_votes<DummyType>(alice_address, guid::id_creation_num(&id));
        assert!(vector::length(&v) == 0, 7357005);

        // proposing a different ending epoch will have no effect on the proposal once it is started. Here we try to set to epoch 4, but nothing should change, at it will still be 14.
        let proposal = multi_action::proposal_constructor(DummyType{}, option::some(4));
        multi_action::propose_new(carol, alice_address, proposal);
        let count = multi_action::get_count_of_pending<DummyType>(alice_address);
        assert!(count == 1, 7357006);
        let epoch = multi_action::get_expiration<DummyType>(alice_address, guid::id_creation_num(&id));
        assert!(epoch == 14, 7357007);
    }

    // Happy day: complete vote action
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c)]
    fun vote_action_happy_simple(root: &signer, alice: &signer, bob: &signer, carol: &signer) {
        // Scenario: a simple MultiAction where we don't need any capabilities. Only need to know if the result was successful on the vote that crossed the threshold.

        // transform alice account in multisign with bob and carol as authorities
        mock::genesis_n_vals(root, 3);
        let alice_address = @0x1000a;
        multi_action::init_gov(alice);
        // Ths is a simple multi_action: there is no capability being stored
        multi_action::init_type<DummyType>(alice, false);
        multi_action::propose_offer(alice, vector[@0x1000b, @0x1000c], option::none());
        multi_action::claim_offer(bob, alice_address);
        multi_action::claim_offer(carol, alice_address);
        multi_action::finalize_and_cage(alice, 2);

        // bob create a proposal
        let proposal = multi_action::proposal_constructor(DummyType{}, option::none());
        let id = multi_action::propose_new<DummyType>(bob, alice_address, proposal);
        let (passed, cap_opt) = multi_action::vote_with_id<DummyType>(bob, &id, alice_address);
        assert!(passed == false, 7357001);
        option::destroy_none(cap_opt);

        let (passed, cap_opt) = multi_action::vote_with_id<DummyType>(carol, &id, alice_address);
        assert!(passed == true, 7357002);
        // THE WITHDRAW CAPABILITY IS MISSING AS EXPECTED
        assert!(option::is_none(&cap_opt), 7357003);

        option::destroy_none(cap_opt);
    }

    // Happy day: complete vote action with withdraw capability
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c, dave = @0x1000d)]
    fun vote_action_happy_withdraw_cap(root: &signer, alice: &signer, bob: &signer, carol: &signer) {
        // Scenario: testing that a payment type multisig could be created with this module: that the WithdrawCapability can be used here.

        mock::genesis_n_vals(root, 4);
        mock::ol_initialize_coin_and_fund_vals(root, 10000000, true);
        let alice_address = @0x1000a;

        // fund the alice multi_action's account
        ol_account::transfer(alice, alice_address, 100);

        // make the bob and carol the signers on the alice safe, and 2-of-2 need to sign
        multi_action::init_gov(alice);
        multi_action::init_type<DummyType>(alice, true);
        multi_action::propose_offer(alice, vector[@0x1000b, @0x1000c], option::none());
        multi_action::claim_offer(bob, alice_address);
        multi_action::claim_offer(carol, alice_address);
        multi_action::finalize_and_cage(alice, 2);

        // bob create a proposal and vote
        let proposal = multi_action::proposal_constructor(DummyType{}, option::none());
        let id = multi_action::propose_new<DummyType>(bob, alice_address, proposal);
        let (passed, cap_opt) = multi_action::vote_with_id<DummyType>(bob, &id, alice_address);
        assert!(passed == false, 7357001);
        option::destroy_none(cap_opt);

        // query proposal id
        let creation_number = multi_action::get_pending_by_creation_number<DummyType>(alice_address);
        assert!(creation_number == vector[guid::id_creation_num(&id)], 7357002);

        // carol vote on bob proposal
        let (passed, cap_opt) = multi_action::vote_with_id<DummyType>(carol, &id, alice_address);
        assert!(passed == true, 7357002);

        // THE WITHDRAW CAPABILITY IS WHERE WE EXPECT
        assert!(option::is_some(&cap_opt), 7357003);
        let cap = option::extract(&mut cap_opt);
        let c = ol_account::withdraw_with_capability(&cap, 42,);
        // deposit to erik account
        ol_account::create_account(root, @0x1000e);
        ol_account::deposit_coins(@0x1000e, c);
        option::fill(&mut cap_opt, cap);
        // check erik account balance
        let (_, balance) = ol_account::balance(@0x1000e);
        assert!(balance == 42, 7357004);

        multi_action::maybe_restore_withdraw_cap(cap_opt);
    }

    // Try to vote on an expired ballot
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c, dave = @0x1000d)]
    #[expected_failure(abort_code = 0x3000C, location = ol_framework::multi_action)]
    fun vote_action_expiration(root: &signer, alice: &signer, bob: &signer, dave: &signer) {
        // Scenario: Testing that if an action expires voting cannot be done.

        mock::genesis_n_vals(root, 3);
        mock::ol_initialize_coin_and_fund_vals(root, 10000000, true);

        // we are at epoch 0
        let epoch = reconfiguration::current_epoch();
        assert!(epoch == 0, 7357001);

        // dave creates erik resource account. He is not one of the validators, and is not an authority in the multisig.
        let (erik, _cap) = ol_account::test_ol_create_resource_account(dave, b"0x1000e");
        let erik_address = signer::address_of(&erik);
        assert!(resource_account::is_resource_account(erik_address), 7357002);

        // fund the account
        ol_account::transfer(alice, erik_address, 100);

        // offer alice and bob authority on the safe
        safe::init_payment_multisig(&erik, vector[@0x1000a, @0x1000b]); // both need to sign
        multi_action::claim_offer(alice, erik_address);
        multi_action::claim_offer(bob, erik_address);
        multi_action::finalize_and_cage(&erik, 2);

        // make a proposal for governance, expires in 2 epoch from now
        let id = multi_action::propose_governance(alice, erik_address, vector::empty(), true,
            option::some(1), option::some(2));

        mock::trigger_epoch(root); // epoch 1
        mock::trigger_epoch(root); // epoch 2
        mock::trigger_epoch(root); // epoch 3 -- voting ended here
        mock::trigger_epoch(root); // epoch 4 -- now expired

        let epoch = reconfiguration::current_epoch();
        assert!(epoch == 4, 7357003);

        // trying to vote on a closed ballot will error
        let _passed = multi_action::vote_governance(bob, erik_address, &id);
    }

    // Happy day: change the authorities of a multisig
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c, dave = @0x1000d)]
    fun governance_change_auths(root: &signer, alice: &signer, bob: &signer, carol: &signer, dave: &signer) {
        // Scenario: The multisig gets initiated with the 2 validators as the only authorities. IT takes 2-of-2 to sign.
        // later they add a third (Dave) so it becomes a 2-of-3.
        // Dave and Bob, then remove alice so it becomes 2-of-2 again

        mock::genesis_n_vals(root, 4);
        mock::ol_initialize_coin_and_fund_vals(root, 10000000, true);
        let carol_address = @0x1000c;
        let dave_address = @0x1000d;

        // fund the account
        ol_account::transfer(alice, carol_address, 100);
        // offer alice and bob authority on the safe
        multi_action::init_gov(carol);// both need to sign
        multi_action::init_type<DummyType>(carol, true);
        let authorities = vector[@0x1000a, @0x1000b];
        multi_action::propose_offer(carol, authorities, option::none());
        multi_action::claim_offer(alice, carol_address);
        multi_action::claim_offer(bob, carol_address);
        multi_action::finalize_and_cage(carol, 2);

        // alice is going to propose to change the authorities to add dave and increase the threshold to 3
        let id = multi_action::propose_governance(alice, carol_address,
            vector[dave_address], true, option::none(), option::none());

        // check authorities did not change
        let ret = multi_action::get_authorities(carol_address);
        assert!(ret == authorities, 7357001);

        // bob votes. bob could either use vote_governance()
        let passed = multi_action::vote_governance(bob, carol_address, &id);
        assert!(passed, 7357002);

        // check authorities did not change
        let ret = multi_action::get_authorities(carol_address);
        assert!(ret == authorities, 7357003);

        // check the Offer
        assert!(multi_action::get_offer_proposed(carol_address) == vector[dave_address], 7357004);
        assert!(multi_action::get_offer_proposed_n_of_m(carol_address) == option::none(), 7357005);

        // dave claims the offer and it becomes final.
        multi_action::claim_offer(dave, carol_address);

        // Chek new set of authorities
        let ret = multi_action::get_authorities(carol_address);
        vector::push_back(&mut authorities, dave_address);
        assert!(ret == authorities, 7357005);

        // Check new signitures threshold
        assert!(multisig_account::num_signatures_required(carol_address) == 2, 7357006);
        assert!(multi_action::get_offer_proposed_n_of_m(carol_address) == option::none(), 7357005);

        // Check if offer was cleaned
        assert!(multi_action::get_offer_proposed(carol_address) == vector::empty(), 7357006);
        assert!(multi_action::get_offer_claimed(carol_address) == vector::empty(), 7357007);
        assert!(multi_action::get_offer_expiration_epoch(carol_address) == vector::empty(), 7357008);

        // Now dave and bob, will conspire to remove alice.
        // NOTE: `false` means `remove account` here
        let id = multi_action::propose_governance(dave, carol_address, vector[signer::address_of(alice)], false, option::none(), option::none());
        let authorities = multi_action::get_authorities(carol_address);
        assert!(vector::length(&authorities) == 3, 7357009); // no change yet

        // bob votes and it becomes final. Bob could either use vote_governance()
        let passed = multi_action::vote_governance(bob, carol_address, &id);
        assert!(passed, 7357008);
        let authorities = multi_action::get_authorities(carol_address);
        assert!(vector::length(&authorities) == 2, 73570010);
        assert!(!multi_action::is_authority(carol_address, signer::address_of(alice)), 7357011);

        // Check if offer was cleaned
        assert!(multi_action::get_offer_proposed(carol_address) == vector::empty(), 73570012);
        assert!(multi_action::get_offer_claimed(carol_address) == vector::empty(), 73570013);
        assert!(multi_action::get_offer_expiration_epoch(carol_address) == vector::empty(), 73570014);
    }

    // Happy day: change the threshold of a multisig
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c, dave = @0x1000d)]
    fun governance_change_threshold(root: &signer, alice: &signer, bob: &signer, carol: &signer, dave: &signer) {
        // Scenario: The multisig gets initiated with the 2 bob and carol as the only authorities.
        // It takes 2-of-2 to sign.
        // They decide next only 1-of-2 will be needed.
        // Then they decide to invite dave and make it 3-of-3.

        mock::genesis_n_vals(root, 4);
        mock::ol_initialize_coin_and_fund_vals(root, 10000000, true);

        // Dave creates the resource account. He is not one of the validators, and is not an authority in the multisig.
        let (resource_sig, _cap) = ol_account::test_ol_create_resource_account(dave, b"0x1");
        let new_resource_address = signer::address_of(&resource_sig);
        assert!(resource_account::is_resource_account(new_resource_address), 7357001);

        // fund the account
        ol_account::transfer(alice, new_resource_address, 100);

        // offer bob and carol authority on the safe
        multi_action::init_gov(&resource_sig);// both need to sign
        multi_action::init_type<DummyType>(&resource_sig, false);
        multi_action::propose_offer(&resource_sig, vector[@0x1000b, @0x1000c], option::none());
        multi_action::claim_offer(carol, new_resource_address);
        multi_action::claim_offer(bob, new_resource_address);
        multi_action::finalize_and_cage(&resource_sig, 2);

        // carol is going to propose to change the threshold to 1
        let id = multi_action::propose_governance(carol, new_resource_address, vector::empty(), true, option::some(1), option::none());

        // check authorities and threshold
        let authorities = multi_action::get_authorities(new_resource_address);
        assert!(authorities == vector[@0x1000c, @0x1000b], 7357002); // no change
        let (n, m) = multi_action::get_threshold(new_resource_address);
        assert!(n == 2, 7357003);
        assert!(m == 2, 7357004);

        // bob votes and it becomes final. Bob could either use vote_governance()
        let passed = multi_action::vote_governance(bob, new_resource_address, &id);

        // check authorities and threshold
        assert!(passed, 7357005);
        let authorities = multi_action::get_authorities(new_resource_address);
        assert!(authorities == vector[@0x1000c, @0x1000b], 7357006); // no change
        let (n, m) = multi_action::get_threshold(new_resource_address);
        assert!(n == 1, 7357007);
        assert!(m == 2, 7357008);

        // now any other type of action can be taken with just one signer
        let proposal = multi_action::proposal_constructor(DummyType{}, option::none());
        let id = multi_action::propose_new<DummyType>(bob, new_resource_address, proposal);
        let (passed, cap_opt) = multi_action::vote_with_id<DummyType>(bob, &id, new_resource_address);
        assert!(passed == true, 7357009);

        // THE WITHDRAW CAPABILITY IS MISSING AS EXPECTED
        assert!(option::is_none(&cap_opt), 7357010);

        option::destroy_none(cap_opt);

        // now bob decide to invite dave and make it 3-of-3.
        multi_action::propose_governance(bob, new_resource_address, vector[signer::address_of(dave)], true, option::some(3), option::none());

        // check authorities and threshold did not change
        let authorities = multi_action::get_authorities(new_resource_address);
        assert!(vector::length(&authorities) == 2, 7357011);
        assert!(vector::contains(&authorities, &signer::address_of(bob)), 7357012);
        assert!(vector::contains(&authorities, &signer::address_of(carol)), 7357013);
        let (n, m) = multi_action::get_threshold(new_resource_address);
        assert!(n == 1, 7357014);
        assert!(m == 2, 7357015);

        // check the Offer
        assert!(multi_action::get_offer_proposed(new_resource_address) == vector[signer::address_of(dave)], 7357016);
        assert!(multi_action::get_offer_proposed_n_of_m(new_resource_address) == option::some(3), 7357017);

        // dave claims the offer and it becomes final.
        multi_action::claim_offer(dave, new_resource_address);

        // Chek new set of authorities
        let ret = multi_action::get_authorities(new_resource_address);
        assert!(ret == vector[ @0x1000c, @0x1000b, @0x1000d ], 7357018);

        // Check new threshold
        let (n, m) = multi_action::get_threshold(new_resource_address);
        assert!(n == 3, 7357019);
        assert!(m == 3, 7357020);

        // Check if offer was cleaned
        assert!(multi_action::get_offer_proposed(new_resource_address) == vector::empty(), 7357021);
        assert!(multi_action::get_offer_claimed(new_resource_address) == vector::empty(), 7357022);
        assert!(multi_action::get_offer_expiration_epoch(new_resource_address) == vector::empty(), 7357023);
        assert!(multi_action::get_offer_proposed_n_of_m(new_resource_address) == option::none(), 7357024);
    }

    // Vote new athority before the previous one is claimed
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c, dave = @0x1000d, erik = @0x1000e)]
    fun governance_vote_before_claim(root: &signer, alice: &signer, bob: &signer, carol: &signer) {
        mock::genesis_n_vals(root, 5);
        let alice_address = @0x1000a;

        // alice offer bob and carol authority on her account
        multi_action::init_gov(alice);
        multi_action::propose_offer(alice, vector[@0x1000b, @0x1000c], option::some(1));
        multi_action::claim_offer(bob, alice_address);
        multi_action::claim_offer(carol, alice_address);
        multi_action::finalize_and_cage(alice, 2);

        // carol is going to propose to change the authorities to add dave
        let id = multi_action::propose_governance(carol, alice_address, vector[@0x1000d], true, option::none(), option::none());

        // bob votes and dave does not claims the offer
        multi_action::vote_governance(bob, alice_address, &id);

        // check authorities and threshold
        assert!(multi_action::get_authorities(alice_address) == vector[@0x1000b, @0x1000c], 7357001);
        let (n, _m) = multi_action::get_threshold(alice_address);
        assert!(n == 2, 7357002);

        // check offer
        assert!(multi_action::get_offer_claimed(alice_address) == vector::empty(), 7357003);
        assert!(multi_action::get_offer_proposed(alice_address) == vector[@0x1000d], 7357004);
        assert!(multi_action::get_offer_expiration_epoch(alice_address) == vector[7], 7357005);

        mock::trigger_epoch(root); // epoch 1

        // bob is going to propose to change the authorities to add erik
        let id = multi_action::propose_governance(bob, alice_address, vector[@0x1000e], true, option::none(), option::none());

        // carol votes
        multi_action::vote_governance(carol, alice_address, &id);

        // check authorities and threshold
        assert!(multi_action::get_authorities(alice_address) == vector[@0x1000b, @0x1000c], 7357001);
        let (n, _m) = multi_action::get_threshold(alice_address);
        assert!(n == 2, 7357002);

        // check offer
        assert!(multi_action::get_offer_claimed(alice_address) == vector::empty(), 7357003);
        assert!(multi_action::get_offer_proposed(alice_address) == vector[@0x1000d, @0x1000e], 7357004);
        assert!(multi_action::get_offer_expiration_epoch(alice_address) == vector[7, 8], 7357005);
    }

    // Try to vote twice on the same ballot
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c, dave = @0x1000d)]
    #[expected_failure(abort_code = 0x3000C, location = ol_framework::multi_action)]
    fun vote_action_twice(root: &signer, alice: &signer, bob: &signer, carol: &signer) {
        // Scenario: Testing that a vote cannot be done twice on the same ballot.

        mock::genesis_n_vals(root, 4);
        mock::ol_initialize_coin_and_fund_vals(root, 10000000, true);
        let carol_address = @0x1000c;
        let dave_address = @0x1000d;
        ol_account::transfer(alice, carol_address, 100);

        // offer alice and bob authority on the safe
        multi_action::init_gov(carol);
        multi_action::init_type<DummyType>(carol, true);
        multi_action::propose_offer(carol, vector[@0x1000a, @0x1000b], option::none());
        multi_action::claim_offer(alice, carol_address);
        multi_action::claim_offer(bob, carol_address);
        multi_action::finalize_and_cage(carol, 2);

        // alice is going to propose to change the authorities to add dave
        let id = multi_action::propose_governance(alice, carol_address,
            vector[dave_address], true, option::none(), option::none());

        // bob votes
        let passed = multi_action::vote_governance(bob, carol_address, &id);
        assert!(passed, 7357002);

        // bob try to vote again
        let _passed = multi_action::vote_governance(bob, carol_address, &id);
    }

    // Try to vote an invalid address for new authority
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c)]
    #[expected_failure(abort_code = 0x60012, location = ol_framework::multisig_account)]
    fun governance_vote_invalid_address(root: &signer, alice: &signer, bob: &signer, carol: &signer) {
        mock::genesis_n_vals(root, 3);
        let alice_address = @0x1000a;

        // alice offer bob and carol authority on her account
        multi_action::init_gov(alice);
        multi_action::propose_offer(alice, vector[@0x1000b, @0x1000c], option::some(1));
        multi_action::claim_offer(bob, alice_address);
        multi_action::claim_offer(carol, alice_address);
        multi_action::finalize_and_cage(alice, 2);

        // carol is going to propose to change the authorities to add dave
        let id = multi_action::propose_governance(carol, alice_address, vector[@0xCAFE], true, option::none(), option::none());

        // bob votes and dave does not claims the offer
        multi_action::vote_governance(bob, alice_address, &id);
    }

    // Try to vote duplicated addresses for new authority
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c, dave = @0x1000d)]
    #[expected_failure(abort_code = 0x10001, location = ol_framework::multisig_account)]
    fun governance_vote_duplicated_addresses(root: &signer, alice: &signer, bob: &signer, carol: &signer) {
        mock::genesis_n_vals(root, 5);
        let alice_address = @0x1000a;

        // alice offer bob and carol authority on her account
        multi_action::init_gov(alice);
        multi_action::propose_offer(alice, vector[@0x1000b, @0x1000c], option::some(1));
        multi_action::claim_offer(bob, alice_address);
        multi_action::claim_offer(carol, alice_address);
        multi_action::finalize_and_cage(alice, 2);

        // carol is going to propose to change the authorities to add dave twice
        let _id = multi_action::propose_governance(carol, alice_address,
            vector[@0x1000d, @0x1000d], true, option::none(), option::none());
    }

    // Try to vote multisig account address for new authority
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c, dave = @0x1000d)]
    #[expected_failure(abort_code = 0x1000D, location = ol_framework::multisig_account)]
    fun governance_vote_multisig_address(root: &signer, alice: &signer, bob: &signer, carol: &signer) {
        mock::genesis_n_vals(root, 5);
        let alice_address = @0x1000a;

        // alice offer bob and carol authority on her account
        multi_action::init_gov(alice);
        multi_action::propose_offer(alice, vector[@0x1000b, @0x1000c], option::some(1));
        multi_action::claim_offer(bob, alice_address);
        multi_action::claim_offer(carol, alice_address);
        multi_action::finalize_and_cage(alice, 2);

        // carol try to propose to change the authorities adding alice
        let _id = multi_action::propose_governance(carol, alice_address, vector[alice_address], true, option::none(), option::none());
    }

    // Try to vote an owner as new authority
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c)]
    #[expected_failure(abort_code = 0x1001A, location = ol_framework::multi_action)]
    fun governance_vote_owner_as_new_authority(root: &signer, alice: &signer, bob: &signer, carol: &signer) {
        mock::genesis_n_vals(root, 3);
        let alice_address = @0x1000a;

        // alice offer bob and carol authority on her account
        multi_action::init_gov(alice);
        multi_action::propose_offer(alice, vector[@0x1000b, @0x1000c], option::some(1));
        multi_action::claim_offer(bob, alice_address);
        multi_action::claim_offer(carol, alice_address);
        multi_action::finalize_and_cage(alice, 2);

        // carol is going to propose to change the authorities to add bob
        let _id = multi_action::propose_governance(carol, alice_address, vector[@0x1000b], true, option::none(), option::none());
    }

    // Try to vote remove an authority that is not in the multisig
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c)]
    #[expected_failure(abort_code = 0x6001B, location = ol_framework::multi_action)]
    fun governance_vote_remove_non_authority(root: &signer, alice: &signer, bob: &signer, carol: &signer) {
        mock::genesis_n_vals(root, 3);
        let alice_address = @0x1000a;

        // alice offer bob and carol authority on her account
        multi_action::init_gov(alice);
        multi_action::propose_offer(alice, vector[@0x1000b, @0x1000c], option::some(1));
        multi_action::claim_offer(bob, alice_address);
        multi_action::claim_offer(carol, alice_address);
        multi_action::finalize_and_cage(alice, 2);

        // carol is going to propose to remove dave
        let _id = multi_action::propose_governance(carol, alice_address,
            vector[@0x1000d], false, option::none(), option::none());
    }

    // Two governance proposals at the same time
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c, dave = @0x1000d, eve = @0x1000e)]
    fun two_simultaneous_governance_vote(root: &signer, alice: &signer, bob: &signer, carol: &signer, dave: &signer, eve: &signer) {
        mock::genesis_n_vals(root, 5);
        let alice_address = @0x1000a;

        // alice offer bob and carol authority on her account
        multi_action::init_gov(alice);
        multi_action::propose_offer(alice, vector[@0x1000b, @0x1000c], option::some(1));
        multi_action::claim_offer(bob, alice_address);
        multi_action::claim_offer(carol, alice_address);
        multi_action::finalize_and_cage(alice, 2);

        // carol is going to propose to change the authorities to add dave
        let id_set_n_3 = multi_action::propose_governance(carol, alice_address, vector[@0x1000d], true, option::some(3), option::none());

        // bob is going to propose to change the authorities to add erik
        let id_set_n_1 = multi_action::propose_governance(bob, alice_address, vector[@0x1000e], true, option::some(1), option::none());

        // bob votes
        let passed = multi_action::vote_governance(bob, alice_address, &id_set_n_3);
        assert!(passed, 7357001);

        // check offer
        assert!(multi_action::get_offer_proposed(alice_address) == vector[@0x1000d], 7357002);
        assert!(multi_action::get_offer_proposed_n_of_m(alice_address) == option::some(3), 7357003);

        // carol votes
        let passed = multi_action::vote_governance(carol, alice_address, &id_set_n_1);
        assert!(passed, 7357004);

        // check offer
        assert!(multi_action::get_offer_proposed(alice_address) == vector[@0x1000d, @0x1000e], 7357005);
        assert!(multi_action::get_offer_proposed_n_of_m(alice_address) == option::some(1), 7357006);

        // dave claims the offer
        multi_action::claim_offer(dave, alice_address);

        // check authorities and threshold
        let authorities = multi_action::get_authorities(alice_address);
        assert!(authorities == vector[@0x1000b, @0x1000c, @0x1000d], 7357007);
        let (n, m) = multi_action::get_threshold(alice_address);
        assert!(n == 2, 7357008); // no change
        assert!(m == 3, 7357009);

        // eve claims the offer and the threshold is now 1
        multi_action::claim_offer(eve, alice_address);

        // check authorities and threshold
        let authorities = multi_action::get_authorities(alice_address);
        assert!(authorities == vector[@0x1000b, @0x1000c, @0x1000d, @0x1000e], 7357010);
        let (n, m) = multi_action::get_threshold(alice_address);
        assert!(n == 1, 7357011);
        assert!(m == 4, 7357012);
    }
}
