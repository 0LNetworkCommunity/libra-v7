#[test_only]
module ol_framework::test_multi_action {
    use ol_framework::mock;
    use ol_framework::multi_action;
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
    use std::debug::print;

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
    fun propose_offer(root: &signer, carol: &signer, alice: &signer, bob: &signer) {
        let _vals = mock::genesis_n_vals(root, 4);
        let carol_address = @0x1000c;
        
        // check the offer does not exist
        assert!(!multi_action::exists_offer(carol_address), 7357001);
        assert!(!multi_action::is_multi_action(carol_address), 7357002);

        // initialize the multi_action account
        multi_action::init_gov(carol);

        // offer authorities
        let authorities = vector::empty<address>();
        vector::push_back(&mut authorities, signer::address_of(alice));
        vector::push_back(&mut authorities, signer::address_of(bob));
        multi_action::propose_offer(carol, authorities, option::none());

        // check the offer is proposed and account is not muti_action yet
        assert!(multi_action::exists_offer(carol_address), 7357003);
        assert!(multi_action::get_offer_proposed(carol_address) == authorities, 7357004);
        assert!(multi_action::get_offer_claimed(carol_address) == vector::empty(), 7357005);
        assert!(vector::is_empty(&multi_action::get_offer_claimed(carol_address)), 7357006);
        let expiration = vector::empty();
        vector::push_back(&mut expiration, 7);
        vector::push_back(&mut expiration, 7);
        assert!(multi_action::get_offer_expiration_epoch(carol_address) == expiration, 7357007);
        assert!(!multi_action::is_multi_action(carol_address), 7357008);
    }

    // Propose new offer after expired
    #[test(root = @ol_framework, carol = @0x1000c, alice = @0x1000a, bob = @0x1000b)]
    fun propose_offer_after_expired(root: &signer, carol: &signer) {
        let _vals = mock::genesis_n_vals(root, 3);
        let carol_address = @0x1000c;

        // initialize the multi_action account
        multi_action::init_gov(carol);

        // offer to alice
        multi_action::propose_offer(carol, vector::singleton(@0x1000a), option::some(2));

        // check the offer is valid
        assert!(multi_action::get_offer_expiration_epoch(carol_address) == vector::singleton(2), 7357004);

        // wait for the offer to expire
        mock::trigger_epoch(root); // epoch 1 valid
        mock::trigger_epoch(root); // epoch 2 expired
        assert!(multi_action::is_offer_expired(carol_address, @0x1000a), 7357005);

        // propose a new offer to bob
        multi_action::propose_offer(carol, vector::singleton(@0x1000b), option::some(3));

        // check the new offer is proposed
        assert!(multi_action::get_offer_proposed(carol_address) == vector::singleton(@0x1000b), 7357007);
        assert!(multi_action::get_offer_claimed(carol_address) == vector::empty(), 7357008);
        assert!(multi_action::get_offer_expiration_epoch(carol_address) == vector::singleton(5), 7357009);
    }

    // Happy Day: claim offer by authorities
    #[test(root = @ol_framework, carol = @0x1000c, alice = @0x1000a, bob = @0x1000b)]
    fun claim_offer(root: &signer, carol: &signer, alice: &signer, bob: &signer) {
        let _vals = mock::genesis_n_vals(root, 2);
        let carol_address = @0x1000c;

        // initialize the multi_action account
        multi_action::init_gov(carol);

        // invite the vals to the resource account
        let authorities = vector::empty<address>();
        vector::push_back(&mut authorities, signer::address_of(alice));
        vector::push_back(&mut authorities, signer::address_of(bob));
        multi_action::propose_offer(carol, authorities, option::none());

        // bob claim the offer
        multi_action::claim_offer(bob, carol_address);

        // check the claimed offer
        assert!(multi_action::exists_offer(carol_address), 7357001);
        let claimed = vector::singleton(signer::address_of(bob));
        let proposed = vector::singleton(signer::address_of(alice));
        assert!(multi_action::get_offer_claimed(carol_address) == claimed, 7357002);
        assert!(multi_action::get_offer_proposed(carol_address) == proposed, 7357003);

        // alice claim the offer
        multi_action::claim_offer(alice, carol_address);

        // check alice and bob claimed the offer
        let claimed = multi_action::get_offer_claimed(carol_address);
        let authorities = vector::empty<address>();
        vector::push_back(&mut authorities, signer::address_of(bob));
        vector::push_back(&mut authorities, signer::address_of(alice));
        assert!(claimed == authorities, 7357004);
        assert!(multi_action::get_offer_proposed(carol_address) == vector::empty(), 7357005);
    }

    // Happy Day: finalize multisign account
    #[test(root = @ol_framework, carol = @0x1000c, alice = @0x1000a, bob = @0x1000b)]
    fun finalize_multi_action(root: &signer, carol: &signer, alice: &signer, bob: &signer) {
        let _vals = mock::genesis_n_vals(root, 3);
        let carol_address = @0x1000c;

        // initialize the multi_action account
        multi_action::init_gov(carol);

        // invite the vals to the resource account
        let authorities = vector::empty<address>();
        vector::push_back(&mut authorities, signer::address_of(alice));
        vector::push_back(&mut authorities, signer::address_of(bob));
        multi_action::propose_offer(carol, authorities, option::none());

        // authorities claim the offer
        multi_action::claim_offer(alice, carol_address);
        multi_action::claim_offer(bob, carol_address);

        // finalize the multi_action account
        assert!(account::exists_at(carol_address), 7357001);
        multi_action::finalize_and_cage2(carol);

        // check the account is multi_action
        assert!(multi_action::is_multi_action(carol_address), 7357002);
        
        // check authorities
        let authorities = multi_action::get_authorities(carol_address);
        let claimed = vector::empty<address>();
        vector::push_back(&mut claimed, signer::address_of(alice));
        vector::push_back(&mut claimed, signer::address_of(bob));
        assert!(authorities == claimed, 7357003);

        // check offer was cleaned
        assert!(multi_action::get_offer_proposed(carol_address) == vector::empty(), 7357004);
        assert!(multi_action::get_offer_claimed(carol_address) == vector::empty(), 7357005);
        assert!(multi_action::get_offer_expiration_epoch(carol_address) == vector::empty(), 7357006);
    }

    // Finalize multisign account having a pending claim
    #[test(root = @ol_framework, carol = @0x1000c, alice = @0x1000a, bob = @0x1000b, dave = @0x1000d)]
    fun finalize_with_pending_claim(root: &signer, carol: &signer, alice: &signer, bob: &signer, dave: &signer) {
        let _vals = mock::genesis_n_vals(root, 4);
        let carol_address = @0x1000c;

        // initialize the multi_action account
        multi_action::init_gov(carol);

        // invite the vals to the resource account
        let authorities = vector::empty<address>();
        vector::push_back(&mut authorities, signer::address_of(alice));
        vector::push_back(&mut authorities, signer::address_of(bob));
        vector::push_back(&mut authorities, signer::address_of(dave));
        multi_action::propose_offer(carol, authorities, option::none());

        // authorities claim the offer
        multi_action::claim_offer(alice, carol_address);
        multi_action::claim_offer(bob, carol_address);

        // finalize the multi_action account
        assert!(account::exists_at(carol_address), 7357001);
        multi_action::finalize_and_cage2(carol);

        // check the account is multi_action
        assert!(multi_action::is_multi_action(carol_address), 7357002);
        
        // check authorities
        let authorities = multi_action::get_authorities(carol_address);
        let claimed = vector::empty<address>();
        vector::push_back(&mut claimed, signer::address_of(alice));
        vector::push_back(&mut claimed, signer::address_of(bob));
        assert!(authorities == claimed, 7357003);

        // check offer was cleared
        assert!(multi_action::get_offer_proposed(carol_address) == vector::empty(), 7357004);
        assert!(multi_action::get_offer_claimed(carol_address) == vector::empty(), 7357005);
        assert!(multi_action::get_offer_expiration_epoch(carol_address) == vector::empty(), 7357006);

    }

    // Propose another offer with different authorities
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c, dave = @0x1000d)]
    fun propose_another_offer_different_authorities(root: &signer, alice: &signer) {
        let _vals = mock::genesis_n_vals(root, 4);
        multi_action::init_gov(alice);

        // invite bob
        multi_action::propose_offer(alice, vector::singleton(@0x1000b), option::some(1));

        // invite carol and dave
        let authorities = vector::empty<address>();
        vector::push_back(&mut authorities, @0x1000c);
        vector::push_back(&mut authorities, @0x1000d);
        multi_action::propose_offer(alice, authorities, option::some(2));

        // check new authorities
        let expiration = vector::singleton(2);
        vector::push_back(&mut expiration, 2);
        assert!(multi_action::get_offer_expiration_epoch(@0x1000a) == expiration, 7357001);
        assert!(multi_action::get_offer_proposed(@0x1000a) == authorities, 7357002);
        assert!(multi_action::get_offer_claimed(@0x1000a) == vector::empty(), 7357003);
    }

    // Propose new offer with more authorities
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c, dave = @0x1000d)]
    fun propose_offer_more_authorities(root: &signer, alice: &signer, carol: &signer) {
        let _vals = mock::genesis_n_vals(root, 4);
        multi_action::init_gov(alice);

        // invite bob
        multi_action::propose_offer(alice, vector::singleton(@0x1000b), option::some(1));

        // new invite bob and carol
        let authorities = vector::empty<address>();
        vector::push_back(&mut authorities, @0x1000b);
        vector::push_back(&mut authorities, @0x1000c);
        multi_action::propose_offer(alice, authorities, option::some(2));

        // check offer
        assert!(multi_action::get_offer_proposed(@0x1000a) == authorities, 7357001);
        assert!(multi_action::get_offer_claimed(@0x1000a) == vector::empty(), 7357002);
        let expiration = vector::singleton(2);
        vector::push_back(&mut expiration, 2);
        assert!(multi_action::get_offer_expiration_epoch(@0x1000a) == expiration, 7357003);

        // carol claim the offer
        multi_action::claim_offer(carol, @0x1000a);

        // new invite bob, carol and dave
        vector::push_back(&mut authorities, @0x1000d);
        multi_action::propose_offer(alice, authorities, option::some(3));

        // check new authorities
        let proposed = vector::singleton(@0x1000b);
        vector::push_back(&mut proposed, @0x1000d);
        let expiration = vector::singleton(3);
        vector::push_back(&mut expiration, 3);
        assert!(multi_action::get_offer_proposed(@0x1000a) == proposed, 7357004);
        assert!(multi_action::get_offer_expiration_epoch(@0x1000a) == expiration, 7357003);
        assert!(multi_action::get_offer_claimed(@0x1000a) == vector::singleton(@0x1000c), 7357005);
    }

    // Propose new offer with less authorities
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c, dave = @0x1000d)]
    fun propose_offer_less_authorities(root: &signer, alice: &signer, carol: &signer) {
        let _vals = mock::genesis_n_vals(root, 4);
        multi_action::init_gov(alice);

        // invite bob, carol e dave
        let authorities = vector::singleton(@0x1000b);
        vector::push_back(&mut authorities, @0x1000c);
        vector::push_back(&mut authorities, @0x1000d);
        multi_action::propose_offer(alice, authorities, option::some(2));

        // new invite bob e carol
        let new_authorities = vector::singleton(@0x1000b);
        vector::push_back(&mut new_authorities, @0x1000c);
        multi_action::propose_offer(alice, new_authorities, option::some(3));

        // check new authorities minus dave
        assert!(multi_action::get_offer_proposed(@0x1000a) == new_authorities, 7357001);
        assert!(multi_action::get_offer_claimed(@0x1000a) == vector::empty(), 7357002);
        let expiration = vector::singleton(3);
        vector::push_back(&mut expiration, 3);
        assert!(multi_action::get_offer_expiration_epoch(@0x1000a) == expiration, 7357003);

        // carol claim the offer
        multi_action::claim_offer(carol, @0x1000a);

        // new invite bob only
        multi_action::propose_offer(alice, vector::singleton(@0x1000b), option::some(4));

        // check new authorities minus carol
        assert!(multi_action::get_offer_proposed(@0x1000a) == vector::singleton(@0x1000b), 7357003);
        assert!(multi_action::get_offer_claimed(@0x1000a) == vector::empty(), 7357004);
    }

    // Propose new offer with same authorities
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c)]
    fun propose_offer_same_authorities(root: &signer, alice: &signer, bob: &signer) {
        let _vals = mock::genesis_n_vals(root, 3);
        multi_action::init_gov(alice);

        // invite bob e carol
        let authorities = vector::empty<address>();
        vector::push_back(&mut authorities, @0x1000b);
        vector::push_back(&mut authorities, @0x1000c);
        multi_action::propose_offer(alice, authorities, option::some(2));

        // check offer
        assert!(multi_action::get_offer_proposed(@0x1000a) == authorities, 7357001);
        assert!(multi_action::get_offer_claimed(@0x1000a) == vector::empty(), 7357002);
        let expiration = vector::singleton(2);
        vector::push_back(&mut expiration, 2);
        assert!(multi_action::get_offer_expiration_epoch(@0x1000a) == expiration, 7357003);

        // new invite bob e carol
        multi_action::propose_offer(alice, authorities, option::some(3));

        // check offer
        assert!(multi_action::get_offer_proposed(@0x1000a) == authorities, 7357001);
        assert!(multi_action::get_offer_claimed(@0x1000a) == vector::empty(), 7357002);
        let expiration = vector::singleton(3);
        vector::push_back(&mut expiration, 3);
        assert!(multi_action::get_offer_expiration_epoch(@0x1000a) == expiration, 7357003);

        // bob claim the offer
        multi_action::claim_offer(bob, @0x1000a);

        // new invite bob e carol
        multi_action::propose_offer(alice, authorities, option::some(4));

        // check authorities
        assert!(multi_action::get_offer_expiration_epoch(@0x1000a) == vector::singleton(4), 7357002);
        assert!(multi_action::get_offer_proposed(@0x1000a) == vector::singleton(@0x1000c), 7357003);
        assert!(multi_action::get_offer_claimed(@0x1000a) == vector::singleton(@0x1000b), 7357004);
    }

    // Try to propose offer without governance
    #[test(root = @ol_framework, carol = @0x1000c, alice = @0x1000a, bob = @0x1000b)]
    #[expected_failure(abort_code = 0x30001, location = ol_framework::multi_action)]
    fun propose_offer_without_gov(root: &signer, carol: &signer, alice: &signer, bob: &signer) {
        let _vals = mock::genesis_n_vals(root, 3);

        // invite the vals to the resource account
        let authorities = vector::empty<address>();
        vector::push_back(&mut authorities, signer::address_of(alice));
        vector::push_back(&mut authorities, signer::address_of(bob));
        multi_action::propose_offer(carol, authorities, option::none());
    }

    // Try to propose offer to an multisig account
    #[test(root = @ol_framework, dave = @0x1000d, carol = @0x1000c, alice = @0x1000a, bob = @0x1000b)]
    #[expected_failure(abort_code = 0x30019, location = ol_framework::multi_action)]
    fun propose_offer_to_multisign(root: &signer, carol: &signer, alice: &signer, bob: &signer) {
        let _vals = mock::genesis_n_vals(root, 4);
        let carol_address = @0x1000c;
        let dave_address = @0x1000d;
        multi_action::init_gov(carol);
        let authorities = vector::empty<address>();
        vector::push_back(&mut authorities, signer::address_of(alice));
        vector::push_back(&mut authorities, signer::address_of(bob));
        multi_action::propose_offer(carol, authorities, option::none());
        multi_action::claim_offer(alice, carol_address);
        multi_action::claim_offer(bob, carol_address);
        multi_action::finalize_and_cage2(carol);

        // propose offer to multisig account
        multi_action::propose_offer(carol, vector::singleton(dave_address), option::none());
    }

    // Try to propose an empty offer
    #[test(root = @ol_framework, alice = @0x1000a)]
    #[expected_failure(abort_code = 0x10016, location = ol_framework::multi_action)]
    fun propose_empty_offer(root: &signer, alice: &signer) {
        let _vals = mock::genesis_n_vals(root, 4);
        multi_action::init_gov(alice);
        multi_action::propose_offer(alice, vector::empty<address>(), option::none());
    }

    // Try to propose too many authorities
    #[test(root = @ol_framework, alice = @0x1000a)]
    #[expected_failure(abort_code = 0x10024, location = ol_framework::multi_action)]
    fun propose_too_many_authorities(root: &signer, alice: &signer) {
        let _vals = mock::genesis_n_vals(root, 1);
        multi_action::init_gov(alice);
        let authorities = vector::empty<address>();
        vector::push_back(&mut authorities, @0x10001);
        vector::push_back(&mut authorities, @0x10002);
        vector::push_back(&mut authorities, @0x10003);
        vector::push_back(&mut authorities, @0x10004);
        vector::push_back(&mut authorities, @0x10005);
        vector::push_back(&mut authorities, @0x10006);
        vector::push_back(&mut authorities, @0x10007);
        vector::push_back(&mut authorities, @0x10008);
        vector::push_back(&mut authorities, @0x10009);
        vector::push_back(&mut authorities, @0x10010);
        vector::push_back(&mut authorities, @0x10011);
        multi_action::propose_offer(alice, authorities, option::none());
    }

    // Try to propose offer to the signer address
    #[test(root = @ol_framework, alice = @0x1000a)]
    #[expected_failure(abort_code = 0x10013, location = ol_framework::multisig_account)]
    fun propose_offer_to_signer(root: &signer, alice: &signer) {
        let _vals = mock::genesis_n_vals(root, 1);
        let alice_address = signer::address_of(alice);
        multi_action::init_gov(alice);
        multi_action::propose_offer(alice, vector::singleton<address>(alice_address), option::none());
    }

    // Try to propose offer with duplicated addresses
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c)]
    #[expected_failure(abort_code = 0x10001, location = ol_framework::multisig_account)]
    fun propose_offer_duplicated_authorities(root: &signer, alice: &signer) {
        let _vals = mock::genesis_n_vals(root, 3);
        multi_action::init_gov(alice);

        let authorities = vector::singleton<address>(@0x1000b);
        vector::push_back(&mut authorities, @0x1000c);
        vector::push_back(&mut authorities, @0x1000b);
        multi_action::propose_offer(alice, authorities, option::none());
    }

    // Try to propose offer to an invalid signer
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b)]
    #[expected_failure(abort_code = 0x60018, location = ol_framework::multisig_account)]
    fun offer_to_invalid_authority(root: &signer, alice: &signer, bob: &signer) {
        let _vals = mock::genesis_n_vals(root, 3);
        multi_action::init_gov(alice);

        // propose to invalid address
        let authorities = vector::empty<address>();
        vector::push_back(&mut authorities, signer::address_of(bob));
        vector::push_back(&mut authorities, @0xCAFE);
        multi_action::propose_offer(alice, authorities, option::some(2));
    }

    // Try to propose offer with zero duration epochs
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b)]
    #[expected_failure(abort_code = 0x10022, location = ol_framework::multi_action)]
    fun offer_with_zero_duration(root: &signer, alice: &signer, bob: &signer) {
        let _vals = mock::genesis_n_vals(root, 3);
        multi_action::init_gov(alice);

        // propose to invalid address
        let authorities = vector::empty<address>();
        vector::push_back(&mut authorities, signer::address_of(bob));
        multi_action::propose_offer(alice, authorities, option::some(0));
    }

    // Try to claim offer not offered to signer
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c)]
    #[expected_failure(abort_code = 0x60020, location = ol_framework::multi_action)]
    fun claim_offer_not_offered(root: &signer, alice: &signer, carol: &signer) {
        let _vals = mock::genesis_n_vals(root, 3);
        let carol_address = @0x1000c;
        multi_action::init_gov(carol);
        
        // invite bob
        multi_action::propose_offer(carol, vector::singleton(@0x1000b), option::none());

        // alice try to claim the offer
        multi_action::claim_offer(alice, carol_address);
    }

    // Try to claim expired offer
    #[test(root = @ol_framework, carol = @0x1000c, alice = @0x1000a, bob = @0x1000b)]
    #[expected_failure(abort_code = 0x20015, location = ol_framework::multi_action)]
    fun claim_expired_offer(root: &signer, carol: &signer, alice: &signer, bob: &signer) {
        let _vals = mock::genesis_n_vals(root, 3);
        let carol_address = @0x1000c;
        multi_action::init_gov(carol);
        
        // invite the vals to the resource account
        let authorities = vector::empty<address>();
        vector::push_back(&mut authorities, signer::address_of(alice));
        vector::push_back(&mut authorities, signer::address_of(bob));
        multi_action::propose_offer(carol, authorities, option::some(2));

        // alice claim the offer
        multi_action::claim_offer(alice, carol_address);
        
        mock::trigger_epoch(root); // epoch 1 valid
        mock::trigger_epoch(root); // epoch 2 valid
        mock::trigger_epoch(root); // epoch 3 expired

        // bob claim expired offer
        multi_action::claim_offer(bob, carol_address);
    }

    // Try to claim offer of an account without proposal
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b)]  
    #[expected_failure(abort_code = 0x60017, location = ol_framework::multi_action)]
    fun claim_offer_without_proposal(root: &signer, alice: &signer) {
        let _vals = mock::genesis_n_vals(root, 2);
        let bob_address = @0x1000c;
        multi_action::claim_offer(alice, bob_address);
    }

    // Try to claim offer twice
    #[test(root = @ol_framework, carol = @0x1000c, alice = @0x1000a, bob = @0x1000b)]
    #[expected_failure(abort_code = 0x80023, location = ol_framework::multi_action)]
    fun claim_offer_twice(root: &signer, carol: &signer, alice: &signer, bob: &signer) {
        let _vals = mock::genesis_n_vals(root, 3);
        let carol_address = @0x1000c;
        multi_action::init_gov(carol);
        
        // invite the vals to the resource account
        let authorities = vector::empty<address>();
        vector::push_back(&mut authorities, signer::address_of(alice));
        vector::push_back(&mut authorities, signer::address_of(bob));
        multi_action::propose_offer(carol, authorities, option::some(2));

        // Alice claim the offer twice
        multi_action::claim_offer(alice, carol_address);
        multi_action::claim_offer(alice, carol_address);
    }

    // Try to finalize account without governance
    #[test(root = @ol_framework, alice = @0x1000a)]
    #[expected_failure(abort_code = 0x30001, location = ol_framework::multi_action)]
    fun finalize_without_gov(root: &signer, alice: &signer) {
        let _vals = mock::genesis_n_vals(root, 1);
        multi_action::finalize_and_cage2(alice);
    }

    // Try to finalize account without offer
    #[test(root = @ol_framework, alice = @0x1000a)]
    #[expected_failure(abort_code = 0x30018, location = ol_framework::multi_action)]
    fun finalize_without_offer(root: &signer, alice: &signer) {
        let _vals = mock::genesis_n_vals(root, 1);
        multi_action::init_gov(alice);
        multi_action::finalize_and_cage2(alice);
    }

    // Try to finalize account without enough offer claimed
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c)]
    #[expected_failure(abort_code = 0x30018, location = ol_framework::multi_action)]
    fun finalize_without_enough_claimed(root: &signer, alice: &signer, bob: &signer, carol: &signer) {
        let _vals = mock::genesis_n_vals(root, 3);
        let alice_address = @0x1000a;
        multi_action::init_gov(alice);
        
        // invite the vals to the resource account
        let authorities = vector::empty<address>();
        vector::push_back(&mut authorities, signer::address_of(bob));
        vector::push_back(&mut authorities, signer::address_of(carol));
        multi_action::propose_offer(alice, authorities, option::none());

        // bob claim the offer
        multi_action::claim_offer(bob, alice_address);

        // finalize the multi_action account
        multi_action::finalize_and_cage2(alice);
    }

    // Try to finalize account already finalized
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c)]
    #[expected_failure(abort_code = 0x80019, location = ol_framework::multi_action)]
    fun finalize_already_finalized(root: &signer, alice: &signer, bob: &signer, carol: &signer) {
        let _vals = mock::genesis_n_vals(root, 3);
        let alice_address = @0x1000a;
        multi_action::init_gov(alice);
        
        // invite the vals to the resource account
        let authorities = vector::empty<address>();
        vector::push_back(&mut authorities, signer::address_of(bob));
        vector::push_back(&mut authorities, signer::address_of(carol));
        multi_action::propose_offer(alice, authorities, option::none());

        // bob claim the offer
        multi_action::claim_offer(bob, alice_address);
        multi_action::claim_offer(carol, alice_address);

        // finalize the multi_action account
        multi_action::finalize_and_cage2(alice);
        multi_action::finalize_and_cage2(alice);
    }

    // Governance Tests
    
    // Happy Day: propose a new action and check zero votes
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c)]
    fun propose_action(root: &signer, alice: &signer, bob: &signer, carol: &signer) {
        let _vals = mock::genesis_n_vals(root, 3);
        let alice_address = @0x1000a;

        // offer to bob and carol authority on the alice safe
        multi_action::init_gov(alice);
        multi_action::init_type<DummyType>(alice, true);
        let authorities = vector::empty<address>();
        vector::push_back(&mut authorities, signer::address_of(bob));
        vector::push_back(&mut authorities, signer::address_of(carol));
        multi_action::propose_offer(alice, authorities, option::none());
        
        // bob and alice claim the offer
        multi_action::claim_offer(bob, alice_address);
        multi_action::claim_offer(carol, alice_address);  
        
        // alice finalize multi action workflow to release control of the account
        multi_action::finalize_and_cage2(alice);

        // bob create a proposal
        let proposal = multi_action::proposal_constructor(DummyType{}, option::none());
        let id = multi_action::propose_new(bob, alice_address, proposal);

        // SHOULD NOT HAVE COUNTED ANY VOTES
        let v = multi_action::get_votes<DummyType>(alice_address, guid::id_creation_num(&id));
        assert!(vector::length(&v) == 0, 7357001);
    }

    // Multisign authorities bob and carol try to send the same proposal
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c)]
    fun propose_action_prevent_duplicated(root: &signer, carol: &signer, alice: &signer, bob: &signer) {
        let _vals = mock::genesis_n_vals(root, 3);
        let alice_address = @0x1000a;

        // offer to bob and carol authority on the alice safe
        multi_action::init_gov(alice);
        multi_action::init_type<DummyType>(alice, true);
        let authorities = vector::empty<address>();
        vector::push_back(&mut authorities, signer::address_of(bob));
        vector::push_back(&mut authorities, signer::address_of(carol));
        multi_action::propose_offer(alice, authorities, option::none());

        // bob and alice claim the offer
        multi_action::claim_offer(bob, alice_address);
        multi_action::claim_offer(carol, alice_address);  
        
        // alice finalize multi action workflow to release control of the account
        multi_action::finalize_and_cage2(alice);

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
        let _vals = mock::genesis_n_vals(root, 3);
        let alice_address = @0x1000a;
        multi_action::init_gov(alice);
        // Ths is a simple multi_action: there is no capability being stored
        multi_action::init_type<DummyType>(alice, false);  
        let authorities = vector::empty<address>();
        vector::push_back(&mut authorities, signer::address_of(bob));
        vector::push_back(&mut authorities, signer::address_of(carol));
        multi_action::propose_offer(alice, authorities, option::none());
        multi_action::claim_offer(bob, alice_address);
        multi_action::claim_offer(carol, alice_address);  
        multi_action::finalize_and_cage2(alice);

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

        let _vals = mock::genesis_n_vals(root, 4);
        mock::ol_initialize_coin_and_fund_vals(root, 10000000, true);
        let alice_address = @0x1000a;

        // fund the alice multi_action's account
        ol_account::transfer(alice, alice_address, 100);

        // make the bob and carol the signers on the alice safe, and 2-of-2 need to sign
        multi_action::init_gov(alice);
        multi_action::init_type<DummyType>(alice, true);
        let authorities = vector::empty<address>();
        vector::push_back(&mut authorities, signer::address_of(bob));
        vector::push_back(&mut authorities, signer::address_of(carol));
        multi_action::propose_offer(alice, authorities, option::none());
        multi_action::claim_offer(bob, alice_address);
        multi_action::claim_offer(carol, alice_address);  
        multi_action::finalize_and_cage2(alice);

        // bob create a proposal and vote
        let proposal = multi_action::proposal_constructor(DummyType{}, option::none());
        let id = multi_action::propose_new<DummyType>(bob, alice_address, proposal);
        let (passed, cap_opt) = multi_action::vote_with_id<DummyType>(bob, &id, alice_address);
        assert!(passed == false, 7357001);
        option::destroy_none(cap_opt);

        // carol vote on bob proposal
        let (passed, cap_opt) = multi_action::vote_with_id<DummyType>(carol, &id, alice_address);
        assert!(passed == true, 7357002);

        // THE WITHDRAW CAPABILITY IS WHERE WE EXPECT
        assert!(option::is_some(&cap_opt), 7357003);
        let cap = option::extract(&mut cap_opt);
        let c = ol_account::withdraw_with_capability(
        &cap,
        42,
        );
        // deposit to erik account 
        ol_account::create_account(root, @0x1000e);
        ol_account::deposit_coins(@0x1000e, c);
        option::fill(&mut cap_opt, cap);
        // check erik account balance
        let (_, balance) = ol_account::balance(@0x1000e);
        assert!(balance == 42, 7357004);

        multi_action::maybe_restore_withdraw_cap(cap_opt);
    }

    // Try to vote on a closed ballot
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c, dave = @0x1000d)]
    #[expected_failure(abort_code = 0x30012, location = ol_framework::multi_action)]
    fun vote_action_expiration(root: &signer, alice: &signer, bob: &signer, dave: &signer) {
        // Scenario: Testing that if an action expires voting cannot be done.

        let _vals = mock::genesis_n_vals(root, 3);
        mock::ol_initialize_coin_and_fund_vals(root, 10000000, true);

        // we are at epoch 0
        let epoch = reconfiguration::get_current_epoch();
        assert!(epoch == 0, 7357001);

        // dave creates erik resource account. He is not one of the validators, and is not an authority in the multisig.
        let (erik, _cap) = ol_account::test_ol_create_resource_account(dave, b"0x1000e");
        let erik_address = signer::address_of(&erik);
        assert!(resource_account::is_resource_account(erik_address), 7357002);

        // fund the account
        ol_account::transfer(alice, erik_address, 100);
        // offer alice and bob authority on the safe
        safe::init_payment_multisig(&erik); // both need to sign
        let authorities = vector::empty<address>();
        vector::push_back(&mut authorities, signer::address_of(alice));
        vector::push_back(&mut authorities, signer::address_of(bob));
        multi_action::propose_offer(&erik, authorities, option::none());
        multi_action::claim_offer(alice, erik_address);
        multi_action::claim_offer(bob, erik_address);  
        multi_action::finalize_and_cage2(&erik);

        // make a proposal for governance, expires in 2 epoch from now
        let id = multi_action::propose_governance(alice, erik_address, vector::empty(), true, option::some(1), option::some(2));

        mock::trigger_epoch(root); // epoch 1
        mock::trigger_epoch(root); // epoch 2
        mock::trigger_epoch(root); // epoch 3 -- voting ended here
        mock::trigger_epoch(root); // epoch 4 -- now expired

        let epoch = reconfiguration::get_current_epoch();
        assert!(epoch == 4, 7357003);

        // trying to vote on a closed ballot will error
        let _passed = multi_action::vote_governance(bob, erik_address, &id);
    }


    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c, dave = @0x1000d)]
    fun governance_change_auths(root: &signer, alice: &signer, bob: &signer, carol: &signer, dave: &signer) {
        // Scenario: The multisig gets initiated with the 2 validators as the only authorities. IT takes 2-of-2 to sign.
        // later they add a third (Dave) so it becomes a 2-of-3.
        // Dave and Bob, then remove alice so it becomes 2-of-2 again

        let _vals = mock::genesis_n_vals(root, 4);
        mock::ol_initialize_coin_and_fund_vals(root, 10000000, true);
        let carol_address = @0x1000c;
        let dave_address = @0x1000d;
        
        // fund the account
        ol_account::transfer(alice, carol_address, 100);
        // offer alice and bob authority on the safe
        multi_action::init_gov(carol);// both need to sign
        multi_action::init_type<DummyType>(carol, true);
        let authorities = vector::empty<address>();
        vector::push_back(&mut authorities, signer::address_of(alice));
        vector::push_back(&mut authorities, signer::address_of(bob));
        multi_action::propose_offer(carol, authorities, option::none());
        multi_action::claim_offer(alice, carol_address);
        multi_action::claim_offer(bob, carol_address);  
        multi_action::finalize_and_cage2(carol);

        // alice is going to propose to change the authorities to add dave
        let id = multi_action::propose_governance(alice, carol_address,
        vector::singleton(dave_address), true, option::none(),
        option::none());

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
        let ret = multi_action::get_offer_proposed(carol_address);
        assert!(ret == vector::singleton(dave_address), 7357004);

        // dave claims the offer and it becomes final.
        multi_action::claim_offer(dave, carol_address);

        // Chek new set of authorities
        let ret = multi_action::get_authorities(carol_address);
        vector::push_back(&mut authorities, dave_address);
        assert!(ret == authorities, 7357005);

        // Check if offer was cleaned
        assert!(multi_action::get_offer_proposed(carol_address) == vector::empty(), 7357006);
        assert!(multi_action::get_offer_claimed(carol_address) == vector::empty(), 7357007);
        assert!(multi_action::get_offer_expiration_epoch(carol_address) == vector::empty(), 7357008);

        // Now dave and bob, will conspire to remove alice.
        // NOTE: `false` means `remove account` here
        let id = multi_action::propose_governance(dave, carol_address, vector::singleton(signer::address_of(alice)), false, option::none(), option::none());
        let a = multi_action::get_authorities(carol_address);
        assert!(vector::length(&a) == 3, 7357009); // no change yet

        // bob votes and it becomes final. Bob could either use vote_governance()
        let passed = multi_action::vote_governance(bob, carol_address, &id);
        assert!(passed, 7357008);
        let a = multi_action::get_authorities(carol_address);
        assert!(vector::length(&a) == 2, 73570010);
        assert!(!multi_action::is_authority(carol_address, signer::address_of(alice)), 7357011);

        // Check if offer was cleaned
        assert!(multi_action::get_offer_proposed(carol_address) == vector::empty(), 73570012);
        assert!(multi_action::get_offer_claimed(carol_address) == vector::empty(), 73570013);
        assert!(multi_action::get_offer_expiration_epoch(carol_address) == vector::empty(), 73570014);
    }

    // Happy day: change the threshold of a multisig
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c, dave = @0x1000d)]
    fun governance_change_threshold(root: &signer, alice: &signer, bob: &signer, carol: &signer, dave: &signer) {
        // Scenario: The multisig gets initiated with the 2 bob and carol as the only authorities. It takes 2-of-2 to sign.
        // They decide next only 1-of-2 will be needed.

        let _vals = mock::genesis_n_vals(root, 3);
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
        let authorities = vector::empty<address>();
        vector::push_back(&mut authorities, signer::address_of(bob));
        vector::push_back(&mut authorities, signer::address_of(carol));
        multi_action::propose_offer(&resource_sig, authorities, option::none());
        multi_action::claim_offer(carol, new_resource_address);
        multi_action::claim_offer(bob, new_resource_address);  
        multi_action::finalize_and_cage2(&resource_sig);

        // carol is going to propose to change the authorities to add Rando
        let id = multi_action::propose_governance(carol, new_resource_address, vector::empty(), true, option::some(1), option::none());
        
        // check authorities and threshold
        let a = multi_action::get_authorities(new_resource_address);
        assert!(vector::length(&a) == 2, 7357002); // no change
        let (n, _m) = multi_action::get_threshold(new_resource_address);
        assert!(n == 2, 7357003);

        // bob votes and it becomes final. Bob could either use vote_governance()
        let passed = multi_action::vote_governance(bob, new_resource_address, &id);

        // check authorities and threshold
        assert!(passed, 7357004);
        let a = multi_action::get_authorities(new_resource_address);
        assert!(vector::length(&a) == 2, 7357005); // no change
        let (n, _m) = multi_action::get_threshold(new_resource_address);
        assert!(n == 1, 7357006);

        // now any other type of action can be taken with just one signer
        let proposal = multi_action::proposal_constructor(DummyType{}, option::none());
        let id = multi_action::propose_new<DummyType>(bob, new_resource_address, proposal);
        let (passed, cap_opt) = multi_action::vote_with_id<DummyType>(bob, &id, new_resource_address);
        assert!(passed == true, 7357007);

        // THE WITHDRAW CAPABILITY IS MISSING AS EXPECTED
        assert!(option::is_none(&cap_opt), 7357008);

        option::destroy_none(cap_opt);
    }

    // Vote new athority before the previous one is claimed
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c, dave = @0x1000d, erik = @0x1000e)]
    fun governance_vote_before_claim(root: &signer, alice: &signer, bob: &signer, carol: &signer) {
        let _vals = mock::genesis_n_vals(root, 5);
        let alice_address = @0x1000a;

        // alice offer bob and carol authority on her account
        multi_action::init_gov(alice);
        let authorities = vector::empty<address>();
        vector::push_back(&mut authorities, signer::address_of(bob));
        vector::push_back(&mut authorities, signer::address_of(carol));
        multi_action::propose_offer(alice, authorities, option::some(1));
        multi_action::claim_offer(bob, alice_address);
        multi_action::claim_offer(carol, alice_address);
        multi_action::finalize_and_cage2(alice);

        // carol is going to propose to change the authorities to add dave
        let id = multi_action::propose_governance(carol, alice_address, vector::singleton(@0x1000d), true, option::none(), option::none());
        
        // bob votes and dave does not claims the offer
        multi_action::vote_governance(bob, alice_address, &id);
        
        // check authorities and threshold
        assert!(multi_action::get_authorities(alice_address) == authorities, 7357001);
        let (n, _m) = multi_action::get_threshold(alice_address);
        assert!(n == 2, 7357002);

        // check offer
        print(&multi_action::get_offer_proposed(alice_address));
        assert!(multi_action::get_offer_claimed(alice_address) == vector::empty(), 7357003);
        print(&multi_action::get_offer_proposed(alice_address));
        assert!(multi_action::get_offer_proposed(alice_address) == vector::singleton(@0x1000d), 7357004);
        assert!(multi_action::get_offer_expiration_epoch(alice_address) == vector::singleton(7), 7357005);

        mock::trigger_epoch(root); // epoch 1

        // bob is going to propose to change the authorities to add erik
        let id = multi_action::propose_governance(bob, alice_address, vector::singleton(@0x1000e), true, option::none(), option::none());

        // carol votes
        multi_action::vote_governance(carol, alice_address, &id);

        // check authorities and threshold
        assert!(multi_action::get_authorities(alice_address) == authorities, 7357001);
        let (n, _m) = multi_action::get_threshold(alice_address);
        assert!(n == 2, 7357002);

        // check offer
        assert!(multi_action::get_offer_claimed(alice_address) == vector::empty(), 7357003);
        let proposed = vector::singleton(@0x1000d);
        vector::push_back(&mut proposed, @0x1000e);
        assert!(multi_action::get_offer_proposed(alice_address) == proposed, 7357004);
        let expiration = vector::singleton(7);
        vector::push_back(&mut expiration, 8);
        assert!(multi_action::get_offer_expiration_epoch(alice_address) == expiration, 7357005);    
    }

    // Try to vote an invalid address for new authority
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c)]
    #[expected_failure(abort_code = 0x60018, location = ol_framework::multisig_account)]
    fun governance_vote_invalid_address(root: &signer, alice: &signer, bob: &signer, carol: &signer) {
        let _vals = mock::genesis_n_vals(root, 3);
        let alice_address = @0x1000a;

        // alice offer bob and carol authority on her account
        multi_action::init_gov(alice);
        let authorities = vector::empty<address>();
        vector::push_back(&mut authorities, signer::address_of(bob));
        vector::push_back(&mut authorities, signer::address_of(carol));
        multi_action::propose_offer(alice, authorities, option::some(1));
        multi_action::claim_offer(bob, alice_address);
        multi_action::claim_offer(carol, alice_address);
        multi_action::finalize_and_cage2(alice);

        // carol is going to propose to change the authorities to add dave
        let id = multi_action::propose_governance(carol, alice_address, vector::singleton(@0xCAFE), true, option::none(), option::none());
        
        // bob votes and dave does not claims the offer
        multi_action::vote_governance(bob, alice_address, &id);
    }

    // Try to vote duplicated addresses for new authority
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c, dave = @0x1000d)]
    #[expected_failure(abort_code = 0x10001, location = ol_framework::multisig_account)]
    fun governance_vote_duplicated_addresses(root: &signer, alice: &signer, bob: &signer, carol: &signer) {
        let _vals = mock::genesis_n_vals(root, 5);
        let alice_address = @0x1000a;

        // alice offer bob and carol authority on her account
        multi_action::init_gov(alice);
        let authorities = vector::empty<address>();
        vector::push_back(&mut authorities, signer::address_of(bob));
        vector::push_back(&mut authorities, signer::address_of(carol));
        multi_action::propose_offer(alice, authorities, option::some(1));
        multi_action::claim_offer(bob, alice_address);
        multi_action::claim_offer(carol, alice_address);
        multi_action::finalize_and_cage2(alice);

        // carol is going to propose to change the authorities to add dave twice
        let authorities = vector::singleton(@0x1000d);
        vector::push_back(&mut authorities, @0x1000d);
        let _id = multi_action::propose_governance(carol, alice_address, authorities, true, option::none(), option::none());
    }

    // Try to vote multisig account address for new authority
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c, dave = @0x1000d)]
    #[expected_failure(abort_code = 0x10013, location = ol_framework::multisig_account)]
    fun governance_vote_multisig_address(root: &signer, alice: &signer, bob: &signer, carol: &signer) {
        let _vals = mock::genesis_n_vals(root, 5);
        let alice_address = @0x1000a;

        // alice offer bob and carol authority on her account
        multi_action::init_gov(alice);
        let authorities = vector::empty<address>();
        vector::push_back(&mut authorities, signer::address_of(bob));
        vector::push_back(&mut authorities, signer::address_of(carol));
        multi_action::propose_offer(alice, authorities, option::some(1));
        multi_action::claim_offer(bob, alice_address);
        multi_action::claim_offer(carol, alice_address);
        multi_action::finalize_and_cage2(alice);

        // carol is going to propose to change the authorities to add dave twice
        let _id = multi_action::propose_governance(carol, alice_address, vector::singleton(alice_address), true, option::none(), option::none());
    }

    // Try to vote an owner as new authority
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c)]
    #[expected_failure(abort_code = 0x10026, location = ol_framework::multi_action)]
    fun governance_vote_owner_as_new_authority(root: &signer, alice: &signer, bob: &signer, carol: &signer) {
        let _vals = mock::genesis_n_vals(root, 3);
        let alice_address = @0x1000a;

        // alice offer bob and carol authority on her account
        multi_action::init_gov(alice);
        let authorities = vector::empty<address>();
        vector::push_back(&mut authorities, signer::address_of(bob));
        vector::push_back(&mut authorities, signer::address_of(carol));
        multi_action::propose_offer(alice, authorities, option::some(1));
        multi_action::claim_offer(bob, alice_address);
        multi_action::claim_offer(carol, alice_address);
        multi_action::finalize_and_cage2(alice);

        // carol is going to propose to change the authorities to add bob
        let _id = multi_action::propose_governance(carol, alice_address, vector::singleton(signer::address_of(bob)), true, option::none(), option::none());
    }

    // Try to vote remove an authority that is not in the multisig
    #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b, carol = @0x1000c)]
    #[expected_failure(abort_code = 0x60027, location = ol_framework::multi_action)]
    fun governance_vote_remove_non_authority(root: &signer, alice: &signer, bob: &signer, carol: &signer) {
        let _vals = mock::genesis_n_vals(root, 3);
        let alice_address = @0x1000a;

        // alice offer bob and carol authority on her account
        multi_action::init_gov(alice);
        let authorities = vector::empty<address>();
        vector::push_back(&mut authorities, signer::address_of(bob));
        vector::push_back(&mut authorities, signer::address_of(carol));
        multi_action::propose_offer(alice, authorities, option::some(1));
        multi_action::claim_offer(bob, alice_address);
        multi_action::claim_offer(carol, alice_address);
        multi_action::finalize_and_cage2(alice);

        // carol is going to propose to remove dave
        let _id = multi_action::propose_governance(carol, alice_address, vector::singleton(@0x1000d), false, option::none(), option::none());
    }
}
