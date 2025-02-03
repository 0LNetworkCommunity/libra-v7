
/// Donor Voice wallets is a service of the chain.
/// Any address can voluntarily turn their account into a Donor Voice account.

/// Definitions
/// Unless otherwise specified the assumption of the Donor Voice app is
/// that there is an Owner of the account and property.
/// The Owner can assign Proxy Authorities, who acting as custodians can issue
/// transactions on behalf of Owner
/// Depositors are called Donors, and the app gives depositors
/// visibility of the transactions, and also limited authority over
/// specific actions: alerting the Owner and Depositors from
/// unauthorized transaction.

/// The DonorVoice Account Lifecycle:
/// Proxy Authorities use a MultiSig to schedule ->
/// Once scheduled the Donors use a TurnoutTally to Veto ->
/// Epoch boundary: transaction executes when the VM reads the Schedule struct at the epoch boundary, and issues payment.

/// By creating a TxSchedule wallet you are providing certain restrictions and guarantees to the users that interact with this wallet.

/// 1. The wallet's contents is property of the owner. The owner is free to issue transactions which change the state of the wallet, including transferring funds. There are however time, and veto policies.

/// 2. All transfers out of the account are timed. Meaning, they will execute automatically after a set period of time passes. The VM address triggers these events at each epoch boundary. The purpose of the delayed transfers is that the transaction can be paused for analysis, and eventually rejected by the donors of the wallet.

/// 3. Every pending transaction can be "vetoed". Each veto delays the finalizing of the transaction, to allow more time for analysis. Each veto adds one day/epoch to the transaction PER DAY THAT A VETO OCCURs. That is, two vetos happening in the same day, only extend the vote by one day. If a sufficient number of Donors vote on the Veto, then the transaction will be rejected. Since TxSchedule has an expiration time, as does ParticipationVote, each time there is a veto, the deadlines for both are synchronized, based on the new TxSchedule expiration time.

/// 4. After three consecutive transaction rejections, the account will become frozen. The funds remain in the account but no operations are available until the Donors, un-freeze the account.

/// 5. Voting for all purposes are done on a pro-rata basis according to the amounts donated. Voting using ParticipationVote method, which in short, biases the threshold based on the turnout of the vote. TL;DR a low turnout of 12.5% would require 100% of the voters to veto, and lower thresholds for higher turnouts until 51%.

/// 6. The donors can vote to liquidate a frozen TxSchedule account. The result will depend on the configuration of the TxSchedule account from when it was initialized: the funds by default return to the end user who was the donor.

/// 7. Third party contracts can wrap the Donor Voice wallet. The outcomes of the votes can be returned to a handler in a third party contract For example, liquidation of a frozen account is programmable: a handler can be coded to determine the outcome of the Donor Voice wallet. See in CommunityWallets the funds return to the InfrastructureEscrow side-account of the user.

module ol_framework::donor_voice {
    use std::vector;
    use std::signer;
    use std::error;
    use diem_framework::system_addresses;

    // use diem_std::debug::print;
    friend diem_framework::genesis;

    friend ol_framework::community_wallet_init;
    friend ol_framework::donor_voice_txs;

    /// Root registry not initialized
    const ENOT_REGISTRY_NOT_INIT: u64 = 1;

    // root registry for the Donor Voice accounts
    struct Registry has key {
      list: vector<address>,
      liquidation_queue: vector<address>,
    }


    //////// INIT REGISTRY OF DONOR VOICE ACCOUNTS  ////////

    // Donor Voice Accounts are a root security service. So the root account needs to keep a registry of all Donor Voice accounts, using this service.

    // Utility used at genesis (and on upgrade) to initialize the system state.
    public(friend) fun initialize(vm: &signer) {
      system_addresses::assert_ol(vm);

      if (!is_root_init()) {
        move_to<Registry>(vm, Registry {
          list: vector::empty<address>(),
          liquidation_queue: vector::empty<address>(),
        });
      };
    }
    //////// GETTERS ///////

    public fun is_root_init():bool {
      exists<Registry>(@ol_framework)
    }

    /// public helper to add account to donor voice registry
    // commit note: this so we don't break compatibility of add_to_registry
    public(friend) fun add(sig: &signer) acquires Registry {
      add_to_registry(sig)
    }

    // add to root registry
    fun add_to_registry(sig: &signer) acquires Registry {
      assert!(exists<Registry>(@ol_framework), error::invalid_state(ENOT_REGISTRY_NOT_INIT));

      let addr = signer::address_of(sig);
      let list = get_root_registry();
      if (!vector::contains<address>(&list, &addr)) {
        let s = borrow_global_mut<Registry>(@ol_framework);
        vector::push_back(&mut s.list, addr);
      };
    }

    // Function to add an address to the liquidation queue directly
    public(friend) fun add_to_liquidation_queue(addr: address) acquires Registry {
        let registry = borrow_global_mut<Registry>(@ol_framework);
        vector::push_back(&mut registry.liquidation_queue, addr);
    }


    #[view]
    /// check if an account is in the registry
    public fun is_donor_voice(addr: address): bool acquires Registry {
      let list = get_root_registry();
      vector::contains<address>(&list, &addr)
    }

    #[view]
    /// Getter for retrieving the list of TxSchedule wallets.
    public fun get_root_registry(): vector<address> acquires Registry{
      if (exists<Registry>(@ol_framework)) {
        let s = borrow_global<Registry>(@ol_framework);
        return *&s.list
      } else {
        return vector::empty<address>()
      }
    }

  #[view]
  /// list of accounts that are pending liquidation after a successful vote to liquidate
  public fun get_liquidation_queue(): vector<address> acquires Registry{
    let f = borrow_global<Registry>(@ol_framework);
    *&f.liquidation_queue
  }
}
