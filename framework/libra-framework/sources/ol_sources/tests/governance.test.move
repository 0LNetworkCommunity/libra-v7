#[test_only]
module ol_framework::test_governance {

  use ol_framework::mock;
  use diem_framework::diem_governance;
  use diem_framework::governance_proposal::GovernanceProposal;
  use diem_framework::voting;
  use diem_framework::timestamp;
  use ol_framework::ol_features_constants;
  use std::features;
  // use diem_std::debug::print;

  #[test(root = @ol_framework, alice = @0x1000a, bob = @0x1000b)]
  fun gov_threshold_can_resolve_early(root: &signer, alice: &signer, bob: &signer) {
    let _vals = mock::genesis_n_vals(root, 2);
    diem_governance::initialize_for_test(root);
    let prop_id = diem_governance::get_next_governance_proposal_id();

    diem_governance::ol_create_proposal_v2(
      alice,
      x"deadbeef",
      b"hi",
      b"again",
      true,
    );

    let prop_id_next = diem_governance::get_next_governance_proposal_id();
    assert!(prop_id_next > prop_id, 73570001);

    // alice votes
    diem_governance::ol_vote(
      alice,
      prop_id,
      true,
    );

    // bob votes
    diem_governance::ol_vote(
      bob,
      prop_id,
      true,
    );

    let (yes, no) = diem_governance::get_votes(prop_id);
    assert!(yes == 2, 73570002);
    assert!(no == 0, 73570003);

    // are we above the threshold for early voting?
    let early = voting::is_early_close_possible<GovernanceProposal>(@ol_framework, prop_id);
    assert!(early, 73570004);

    // will it close
    let closed = voting::is_voting_closed<GovernanceProposal>(@ol_framework, prop_id);
    assert!(closed, 73570005);

    // state of 1 means passed
    let state = diem_governance::get_proposal_state(prop_id);
    assert!(state == 1, 73570006);

    // issue with transactions being atomic
    timestamp::fast_forward_seconds(1);

    // confirm that the voting would allow for a resolution
    // it cannot resolve because the transaction hashes (of this test script) do no match.
    let (can_resolve, _err) = voting::check_resolvable_ex_hash<GovernanceProposal>(@ol_framework, prop_id);
    assert!(can_resolve, 73570007);
  }


  #[test(root = @ol_framework, alice = @0x1000a, marlon = @0x12345)]
  fun test_enable_ol_features(root: &signer) {
    let _vals = mock::genesis_n_vals(root, 2);
    // case: set a dummy feature flag
    features::change_feature_flags(root, vector[ol_features_constants::test_get_dummy_flag()], vector[]);
    assert!(features::is_enabled(ol_features_constants::test_get_dummy_flag()), 7357002);
    assert!(ol_features_constants::test_dummy_flag_enabled(), 7357003);
  }
}
