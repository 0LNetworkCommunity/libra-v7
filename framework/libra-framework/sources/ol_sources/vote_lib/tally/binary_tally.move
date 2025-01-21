
  /// This is a simple implementation of a simple binary choice poll with a deadline.
  /// It can be used to instantiate very simple referenda, and to programatically initiate actions/events/transactions based on a result.
  /// It's also intended as a demonstration. Developers can use this as a template to create their own tally algorithm and other workflows.
  /// Ballot itself does not have any storage. It just creates the ballot box, and the methods to query or mutate the ballot box, and ballots.
  /// So this module is a wrapper around Ballot with simple storage and simple logic.

  module ol_framework::binary_tally {

    use ol_framework::ballot::{Self, BallotTracker};
    use std::guid;
    use std::vector;
    use std::signer;
    use std::error;
    use std::option::{Self, Option};
    use diem_framework::reconfiguration;

    #[test_only]
    friend ol_framework::turnkey_binary_poll;

    /// tally not initialized
    const ENOT_INITIALIZED: u64 = 0;
    /// no ballot found
    const ENO_BALLOT_FOUND: u64 = 1;
    /// not enrolled to participate in ballot
    const ENOT_ENROLLED: u64 = 2;
    /// you've already voted
    const EALREADY_VOTED: u64 = 3;
    /// not a valid vote option
    const EINVALID_VOTE: u64 = 4;

    // Duplicated from Ballot
    const PENDING: u8  = 1;
    const APPROVED: u8 = 2;
    const REJECTED: u8 = 3;

    /// We keep a tracker of all the Polls for a given Issue.
    /// Ballot leverages generics to make ballots have rich data, for custom handlers.
    /// This makes it confusing at first glance, because it creates a russian doll of structs.

    /// In BinaryPoll we have a single place to track every BinaryTally of a given "issue" that can carry IssueData as a payload.

    /// struct ballot::BallotTracker<
    ///     ballot::Ballot<
    ///       BinaryPoll::BinaryTally<
    ///         IssueData { whatever: you_decide }

    /// the ability to update tallies is usually restricted to signer
    /// since the signer is the one who can create the guid::CreateCapability
    /// A third party contract can store that capability to access based on its own vote logic. Danger.
    // You'll need something like this:
    // struct VoteCapability has key {
    //   guid_cap: guid::CreateCapability,
    // }


    /// in Ballot a TallyType can have any kind of data to support the vote.
    /// In our case it's a BinaryTally type.
    /// The counter fields are very straightforward.
    /// What may not be straigtforward is the "issue_data" field.
    /// This is a generic field that can be used to store any kind of data.
    /// If for example you want every ballot to just have a description, but on each ballot the description is different (like a referendum "prop"). MyCoolVote { vote_text: ASCII };
    /// If your vote is always a recurring topic, it could be as simple as an empty struct where the definition has some semantics. `DoWeForkThisChain {}`
    /// or more interestingly, it could be an address for a payment `PayThisGuy { user: address, amount: u64 }` which then you can handle with a custom payment logic.

    /// The data stored in IssueData can be used to trigger an event lazily when a voter finally crosses the threshold for the count
    // See for example the result of vote() returns the IssueData.

    struct BinaryTally<IssueData> has store, drop {
      votes_for: u64,
      votes_against: u64,
      voted: vector<address>, // this is a list of voters who have voted. You may prefer to move the voted flag to the end user's address (or do a bloom filter).
      enrollment: vector<address>, // this is a list of voters who are eligible to vote.
      deadline_epoch: u64,
      tally_result: Option<bool>,
      issue_data: IssueData,
    }


    //////// PROPOSE BALLOT WITH AN ISSUE ////////

    public(friend) fun ballot_constructor<IssueData: drop + store>(issue_data: IssueData): BinaryTally<IssueData> {
      BinaryTally {
        votes_for: 0,
        votes_against: 0,
        voted: vector::empty<address>(),
        enrollment: vector::empty<address>(),
        deadline_epoch: 0,
        tally_result: option::none<bool>(),
        issue_data,
      }
    }

    public(friend) fun propose_ballot<IssueData: drop + store>(
      tracker: &mut BallotTracker<BinaryTally<IssueData>>,
      guid: guid::GUID,
      issue_data: IssueData,
    ) {
      let prop = ballot_constructor<IssueData>(issue_data);
      ballot::propose_ballot(tracker, guid, prop);
    }

    public(friend) fun update_enrollment<IssueData: drop + store>(
      tracker: &mut BallotTracker<BinaryTally<IssueData>>,
      uid: &guid::ID,
      list: vector<address>,
      add_remove: bool,
    ) {
      let ballot = ballot::get_ballot_by_id_mut(tracker, uid);
      let tally_type: &mut BinaryTally<IssueData> = ballot::get_type_struct_mut(ballot);
      if (add_remove) {
        vector::append(&mut tally_type.enrollment, list);
      } else {
        let i = 0;
        while (i < vector::length(&list)) {
          let addr = vector::borrow(&list, i);
          let (found, idx) = vector::index_of(&tally_type.enrollment, addr);
          if (found) {
            vector::remove(&mut tally_type.enrollment, idx);
          };
          i = i + 1;
        }
      }
    }


    ///////// GETTERS  /////////
    public(friend) fun is_enrolled<IssueData: drop + store>(
      sig: &signer,
      tally_type: &BinaryTally<IssueData>,
    ): bool {
      let addr = signer::address_of(sig);
       vector::contains(&tally_type.enrollment, &addr)
    }

    public(friend) fun has_voted<IssueData: drop + store>(
      sig: &signer,
      tally_type: &BinaryTally<IssueData>,
      // uid: &guid::ID,

    ): bool {
      let addr = signer::address_of(sig);
      vector::contains(&tally_type.voted, &addr)
    }


    //////// TALLY METHODS ////////

    public(friend) fun vote<IssueData: drop + store>(
      sig: &signer,
      tracker: &mut BallotTracker<BinaryTally<IssueData>>,
      uid: &guid::ID,
      vote_for: bool,
    ): Option<bool> { // Returns some() if the result is complete, and APPROVED==true

    assert_can_vote<IssueData>(sig, tracker, uid);

    let ballot = ballot::get_ballot_by_id_mut(tracker, uid);
    let tally_type: &mut BinaryTally<IssueData> = ballot::get_type_struct_mut(ballot);

      if (vote_for) {
        tally_type.votes_for = tally_type.votes_for + 1;
      } else {
        tally_type.votes_against = tally_type.votes_against + 1;
      };

      // add the signer to the list of voters
      vector::push_back(&mut tally_type.voted, signer::address_of(sig));

      // update the tally
      maybe_tally(tally_type);

      maybe_complete(tracker, uid)
    }

    fun assert_can_vote<IssueData: drop + store>(
      sig: &signer,
      tracker: &mut BallotTracker<BinaryTally<IssueData>>,
      uid: &guid::ID,
    ) {
      let ballot = ballot::get_ballot_by_id(tracker, uid);

      let tally_type = ballot::get_type_struct(ballot);

      assert!(is_enrolled<IssueData>(sig, tally_type), error::invalid_argument(ENOT_ENROLLED));

      assert!(!has_voted<IssueData>(sig, tally_type), error::invalid_argument(EALREADY_VOTED));

      let (found, _idx, status_enum, is_completed) = ballot::find_anywhere(tracker, uid);

      assert!(found, error::invalid_argument(EINVALID_VOTE));
      assert!(!is_completed, error::invalid_argument(EINVALID_VOTE));
      // is a pending ballot
      assert!(status_enum == 0, error::invalid_argument(EINVALID_VOTE));
    }

    /// Just check the tally and mark the result.
    /// this function doesn't move the ballot to a different list, since it doesn't have the outer struct and data needed.
    fun maybe_tally<IssueData: drop + store>(t: &mut BinaryTally<IssueData>): Option<bool> {


      if (reconfiguration::current_epoch() > t.deadline_epoch) {

        if (t.votes_for > t.votes_against) {
          t.tally_result = option::some(true);
        } else {
          t.tally_result = option::some(false);
        }

      };

      *&t.tally_result
    }

    /// With access to the outer struct of the Poll, move completed ballots to their correct location: approved or rejected
    /// returns an option type for approved or rejected, so that the caller can decide what to do with the result.
    fun maybe_complete<IssueData: drop + store>(
      tracker: &mut BallotTracker<BinaryTally<IssueData>>,
      uid: &guid::ID
    ): Option<bool> { // returns if it was enum APPROVED == true

      let ballot = ballot::get_ballot_by_id_mut(tracker, uid);
      let tally_type = ballot::get_type_struct_mut(ballot);

      if (option::is_some(&tally_type.tally_result)) {
          let passed = *option::borrow(&tally_type.tally_result);
          let status_enum = if (passed) {
            APPROVED // approved
          } else {
            REJECTED // rejected
          };
          // since we have a result lets update the Ballot state
          complete_and_move<IssueData>(tracker, uid, *&status_enum);
          return option::some(passed)
        };

        option::none()
    }

    public(friend) fun complete_and_move<IssueData: drop + store>(
      tracker: &mut BallotTracker<BinaryTally<IssueData>>,
      uid: &guid::ID,
      to_status_enum: u8
    ) {
      let (found, _idx, status_enum, _completed) = ballot::find_anywhere(tracker, uid);
      assert!(found, error::invalid_argument(ENO_BALLOT_FOUND));

      let b = ballot::get_ballot_by_id_mut(tracker, uid);
      ballot::complete_ballot(b);
      ballot::move_ballot(tracker, uid, status_enum, to_status_enum);
    }

    // Convenience function to overwrite the tally data of a ballot, in case you got boxed in somewhere
    public(friend) fun force_update_tally<IssueData: drop + store> (
      tracker: &mut BallotTracker<BinaryTally<IssueData>>,
      uid: &guid::ID,
      new_tally: BinaryTally<IssueData>,
    ) {
      let (found, _idx, _status_enum, _completed) = ballot::find_anywhere(tracker, uid);
      assert!(found, error::invalid_argument(ENO_BALLOT_FOUND));

      let b = ballot::get_ballot_by_id_mut(tracker, uid);
      ballot::set_ballot_data(b, new_tally);
    }

  }
