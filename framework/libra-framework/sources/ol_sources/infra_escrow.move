///////////////////////////////////////////////////////////////////////////
// 0L Module
// Infra Escrow
///////////////////////////////////////////////////////////////////////////
// Controls funds that have been pledged to infrastructure subsidy
// Like other Pledged segregated accounts, the value lives on the
// user's account. The funding is not pooled into a system account.
// According to the policy the funds may be drawn down from Pledged
// segregated accounts.
///////////////////////////////////////////////////////////////////////////

module ol_framework::infra_escrow{
    use std::error;
    use std::option::{Self, Option};
    use diem_framework::coin;
    use diem_framework::transaction_fee;
    use diem_framework::system_addresses;
    use ol_framework::ol_account;
    use ol_framework::libra_coin::LibraCoin;
    use ol_framework::pledge_accounts;
    use ol_framework::testnet;
    use ol_framework::epoch_helper;

    // use diem_framework::debug::print;

    friend diem_framework::genesis;
    friend ol_framework::epoch_boundary;

    #[test_only]
    friend ol_framework::mock;


    /// Not enough supply for genesis reward
    const EGENESIS_REWARD: u64 = 0;

    /// I'm sorry dave, this is only for testing
    const EWITHDRAW_NOT_ON_MAINNET: u64 = 1;



    /// for use on genesis, creates the infra escrow pledge policy struct
    public(friend) fun initialize(framework: &signer) {
        // NOTE: THIS MUST BE THE 0x0 address, because on epoch boundary it is that address @vm_reserved which will be calling the functions.
        system_addresses::assert_diem_framework(framework);
        // TODO: perhaps this policy needs to be published to a different address?
        pledge_accounts::publish_beneficiary_policy(
          framework, // only framework calls at genesis
          b"infra escrow",
          90,
          true
        );
    }

    /// VM can call down pledged funds.
    // NOTE: the signer MUST_BE 0x0 address
    fun infra_pledge_withdraw(vm: &signer, amount: u64): Option<coin::Coin<LibraCoin>> {
        system_addresses::assert_ol(vm);
        pledge_accounts::withdraw_from_all_pledge_accounts(vm, amount)
    }

    /// Helper for epoch boundaries.
    /// Collects funds from pledge and places temporarily in network account
    // (the TransactionFee account)
    /// @return tuple of 2
    /// 0: if collection succeeded
    /// 1: how much was collected
    public(friend) fun epoch_boundary_collection(root: &signer, amount: u64):
    (bool, u64) {
        system_addresses::assert_ol(root);
        let opt = pledge_accounts::withdraw_from_all_pledge_accounts(root, amount);

        if (option::is_none(&opt)) {
          option::destroy_none(opt);
          return (false, 0)
        };
        let c = option::extract(&mut opt);
        option::destroy_none(opt);
        let value = coin::value(&c);
        transaction_fee::vm_pay_fee(root, @ol_framework, c); // don't attribute
        // to the user
        return(true, value)
    }


    // Transaction script for user to pledge to infra escrow.
    fun user_pledge_infra(user_sig: &signer, amount: u64){
      pledge_accounts::user_pledge(user_sig, @ol_framework, amount);
    }

    #[view]
    /// gets the amount a user has pledged to infra escrow
    public fun user_infra_pledge_balance(addr: address): u64 {
      pledge_accounts::get_user_pledge_amount(addr, @ol_framework)
    }

    #[view]
    /// gets the amount a user has pledged to infra escrow
    public fun infra_escrow_balance(): u64 {
      pledge_accounts::get_available_to_beneficiary(@ol_framework)
    }

    //////// TESTNET HELPERS ////////
    /// For testnet scenarios we may want to mint a minimal coin to the validators
    // this is only called through genesis when using the production rust libra-genesis-tool
    // and in the move code, we want the validators to start with zero balances
    // and add them with mock.move when we need it.
    public(friend) fun genesis_coin_validator(framework: &signer, to: address) {
      system_addresses::assert_diem_framework(framework);
      assert!(epoch_helper::get_current_epoch() == 0, EGENESIS_REWARD);
      let bootstrap_amount = 1_000 * 1_000_000; // 1K times scaling
      framework_fund_account(framework, to, bootstrap_amount);
    }

    // DANGER: keep this private, and only used in testnet
    fun framework_fund_account(framework: &signer, to: address, amount: u64) {
      system_addresses::assert_diem_framework(framework);
      assert!(testnet::is_not_mainnet(), error::invalid_state(EWITHDRAW_NOT_ON_MAINNET));

      if (infra_escrow_balance() > amount) {
        let c_opt = infra_pledge_withdraw(framework, amount);
        assert!(option::is_some(&c_opt), error::invalid_state(EGENESIS_REWARD));
          let coin = option::extract(&mut c_opt);
          ol_account::deposit_coins(to, coin);
        option::destroy_none(c_opt);
      }
    }

    #[test_only]
    // test helper to initialize escrow for unit tests which don't do a full genesis
    public fun init_escrow_with_deposit(framework: &signer, depositor: &signer, amount: u64){
      pledge_accounts::initialize(framework);
      initialize(framework);
      user_pledge_infra(depositor, amount);
    }
}
