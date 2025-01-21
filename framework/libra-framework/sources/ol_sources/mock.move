// Some fixtures are complex and are repeatedly needed
#[test_only]
module ol_framework::mock {
  use std::vector;
  use diem_framework::coin;
  use diem_framework::block;
  use diem_framework::stake;
  use diem_framework::account;
  use diem_framework::genesis;
  use diem_framework::timestamp;
  use diem_framework::reconfiguration;
  use diem_framework::system_addresses;
  use diem_framework::transaction_fee;
  use ol_framework::grade;
  use ol_framework::vouch;
  use ol_framework::slow_wallet;
  use ol_framework::proof_of_fee;
  use ol_framework::validator_universe;
  use ol_framework::epoch_boundary;
  use ol_framework::libra_coin::{Self, LibraCoin};
  use ol_framework::ol_account;
  use ol_framework::epoch_helper;
  use ol_framework::musical_chairs;
  use ol_framework::infra_escrow;
  use ol_framework::pledge_accounts;
  use ol_framework::secret_bid;

  // use diem_std::debug::print;

  const ENO_GENESIS_END_MARKER: u64 = 1;
  const EDID_NOT_ADVANCE_EPOCH: u64 = 2;
  /// coin supply does not match expected
  const ESUPPLY_MISMATCH: u64 = 3;

  //////// STATIC ////////
  /// The starting nominal reward. Also how much each validator will have in their starting balance; as a genesis reward at start of network
  const EPOCH_REWARD: u64 = 1_000_000; /// 1M
  /// What is the fixed and final supply of the network at start
  const FINAL_SUPPLY_AT_GENESIS: u64 = 100_000_000_000; // 100B
  /// Place some coins in the system transaction fee account;
  const TX_FEE_ACCOUNT_AT_GENESIS: u64 =  100_000_000; // 100M
  /// Tbe starting entry fee for validators
  const ENTRY_FEE: u64 =  1_000; // 1K
  /// Initial funding of infra-escrow
  const INFRA_ESCROW_START: u64 =  37_000_000_000; // 37B

  #[test_only]
  public fun default_epoch_reward(): u64 { EPOCH_REWARD }

  #[test_only]
  /// What is the fixed and final supply of the network at start
  public fun default_final_supply_at_genesis(): u64 { FINAL_SUPPLY_AT_GENESIS }

  #[test_only]
  public fun default_tx_fee_account_at_genesis(): u64 { TX_FEE_ACCOUNT_AT_GENESIS }

  #[test_only]
  public fun default_entry_fee(): u64 { ENTRY_FEE }


  #[test_only]
  public fun reset_val_perf_one(vm: &signer, addr: address) {
    stake::mock_performance(vm, addr, 0, 0);
  }

  #[test_only]
  public fun reset_val_perf_all(vm: &signer) {
    let vals = stake::get_current_validators();
    let i = 0;
    while (i < vector::length(&vals)) {
      let a = vector::borrow(&vals, i);
      stake::mock_performance(vm, *a, 0, 0);
      i = i + 1;
    };
  }


  #[test_only]
  public fun mock_case_1(vm: &signer, addr: address) {
    assert!(stake::is_valid(addr), 01);
    stake::mock_performance(vm, addr, 100, 10);
    let (compliant, _, _) = grade::get_validator_grade(addr);
    assert!(compliant, 01);
  }


  #[test_only]
  // did not do enough mining, but did validate.
  public fun mock_case_4(vm: &signer, addr: address) {
    assert!(stake::is_valid(addr), 01);
    stake::mock_performance(vm, addr, 0, 100); // 100 failing proposals
    // let (compliant, _, _, _) = grade::get_validator_grade(addr, 0);
    let (compliant, _, _) = grade::get_validator_grade(addr);
    assert!(!compliant, 02);
  }

  // Mock all nodes being compliant case 1
  #[test_only]
  public fun mock_all_vals_good_performance(vm: &signer) {
    let vals = stake::get_current_validators();
    let i = 0;
    while (i < vector::length(&vals)) {
      let a = vector::borrow(&vals, i);
      mock_case_1(vm, *a);
      i = i + 1;
    };
  }

  // Mock some nodes not compliant
  /*#[test_only]
  public fun mock_some_vals_bad_performance(vm: &signer, bad_vals: u64) {
    let vals = stake::get_current_validators();
    let vals_compliant = vector::length(&vals) - bad_vals;
    let i = 0;
    while (i < vals_compliant) {
      let a = vector::borrow(&vals, i);
      stake::mock_performance(vm, *a, 0, 100); // 100 failing proposals
      i = i + 1;
    };
  }*/

  //////// PROOF OF FEE ////////
  #[test_only]
  public fun pof_default(framework: &signer): (vector<address>, vector<u64>){

    let vals = stake::get_current_validators();

    let bids = mock_bids(framework, &vals);

    // make all validators pay auction fee
    // the clearing price in the fibonacci sequence is is 1
    let alice_bid = secret_bid::get_bid_unchecked(*vector::borrow(&vals, 0));

    assert!(alice_bid == 1, 03);
    (vals, bids)
  }

  #[test_only]
  public fun mock_bids(framework: &signer, vals: &vector<address>): vector<u64> {
    let bids = vector::empty<u64>();
    let i = 0;
    let prev = 0;
    let fib = 1;
    while (i < vector::length(vals)) {
      let b = prev + fib;
      vector::push_back(&mut bids, b);

      let a = vector::borrow(vals, i);
      let sig = account::create_signer_for_test(*a);
      // initialize and set. Will likely by epoch 0, genesis.
      let epoch = epoch_helper::get_current_epoch();
      secret_bid::mock_revealed_bid(framework, &sig, b, epoch);
      prev = fib;
      fib = b;
      i = i + 1;
    };

    bids
  }

  use diem_framework::chain_status;
  #[test_only]
  public fun ol_test_genesis(root: &signer) {
    system_addresses::assert_ol(root);
    genesis::setup();
    genesis::test_end_genesis(root);

    let mint_cap = coin_init_minimal(root);
    libra_coin::restore_mint_cap(root, mint_cap);

    assert!(!chain_status::is_genesis(), 0);
  }

  #[test_only]
  public fun ol_initialize_coin(root: &signer) {
    system_addresses::assert_ol(root);

    let mint_cap = coin_init_minimal(root);

    libra_coin::restore_mint_cap(root, mint_cap);
  }

  #[test_only]
  public fun ol_mint_to(root: &signer, addr: address, amount: u64) {
    system_addresses::assert_ol(root);

    let mint_cap = if (coin::is_coin_initialized<LibraCoin>()) {
      libra_coin::extract_mint_cap(root)
    } else {
      coin_init_minimal(root)
    };

    if (!account::exists_at(addr)) {
        ol_account::create_account(root, addr);
    };

    let c = coin::test_mint(amount, &mint_cap);
    ol_account::deposit_coins(addr, c);

    let b = coin::balance<LibraCoin>(addr);
    assert!(b == amount, 0001);

    libra_coin::restore_mint_cap(root, mint_cap);
  }

  #[test_only]
  public fun ol_initialize_coin_and_fund_vals(root: &signer, amount: u64,
  drip: bool) {
    if (!coin::is_coin_initialized<LibraCoin>()) {
      let mint_cap = coin_init_minimal(root);
      libra_coin::restore_mint_cap(root, mint_cap);
    };

    fund_validators(root, amount, drip);
  }

  fun fund_validators(root: &signer, amount: u64,
  drip: bool) {
    system_addresses::assert_ol(root);

    let vals = stake::get_current_validators();
    let i = 0;
    while (i < vector::length(&vals)) {
      let addr = vector::borrow(&vals, i);

      let coin = pledge_accounts::test_single_withdrawal(root, @0xBA7, amount);
      ol_account::vm_deposit_coins_locked(root, *addr, coin);

      let b = libra_coin::balance(*addr);

      assert!(b == amount, 0001);

      i = i + 1;
    };

    if (drip) {
      slow_wallet::slow_wallet_epoch_drip(root, amount);
    };
  }

  public fun mock_tx_fees_in_account(root: &signer, amount: u64) {
    let tx_fees_start = pledge_accounts::test_single_withdrawal(root, @0xBA7, amount);
    transaction_fee::vm_pay_fee(root, @ol_framework, tx_fees_start);
  }

  #[test_only]
  // For unit test, we need to try to initialize the minimal state for
  // user transactions. In the case of a unit tests which does a genesis with validators, this will not attempt to re-initialize the state.
  fun coin_init_minimal(root: &signer): coin::MintCapability<LibraCoin> {
    system_addresses::assert_ol(root);

    let (burn_cap, mint_cap) = libra_coin::initialize_for_test(root);
    coin::destroy_burn_cap(burn_cap);

    transaction_fee::initialize_fee_collection_and_distribution(root, 0);

    // let initial_fees = 5_000_000 * 100; // coin scaling * 100 coins
    let genesis_coins = coin::test_mint(FINAL_SUPPLY_AT_GENESIS, &mint_cap);
    libra_coin::test_set_final_supply(root, FINAL_SUPPLY_AT_GENESIS);
    let supply_pre = libra_coin::supply();

    assert!(supply_pre == FINAL_SUPPLY_AT_GENESIS, ESUPPLY_MISMATCH);

    // transaction_fee::vm_pay_fee(root, @ol_framework, tx_fees);

    // Forge Bruce
    // We need to simulate a long running network
    // where the Infra Pledge account accumulated.
    // Here we use Wayne Enterprises as the sole sponsor of the
    // test environment Infra Pledge
    let bruce_address = @0xBA7;
    ol_account::create_account(root, bruce_address);
    let bruce_sig = account::create_signer_for_test(bruce_address);

    // Bruce inherits a fortune, all the coins from genesis
    ol_account::deposit_coins(bruce_address, genesis_coins);

    // Bruce mints a fortune
    // let fortune_mint = coin::test_mint(fortune, &mint_cap);
    // ol_account::deposit_coins(bruce_address, fortune_mint);

    // Bruce funds infra escrow
    infra_escrow::init_escrow_with_deposit(root, &bruce_sig, INFRA_ESCROW_START);

    assert!(supply_pre == libra_coin::supply(), ESUPPLY_MISMATCH);

    mint_cap
  }
  // #[test_only]
  // // For unit test, we need to try to initialize the minimal state for
  // // user transactions. In the case of a unit tests which does a genesis with validators, this will not attempt to re-initialize the state.
  // fun coin_init_minimal(root: &signer): coin::MintCapability<LibraCoin> {
  //   system_addresses::assert_ol(root);

  //   let (burn_cap, mint_cap) = libra_coin::initialize_for_test(root);
  //   coin::destroy_burn_cap(burn_cap);

  //   transaction_fee::initialize_fee_collection_and_distribution(root, 0);

  //   let genesis_mint = coin::test_mint(FINAL_SUPPLY_AT_GENESIS, &mint_cap);
  //   libra_coin::test_set_final_supply(root, FINAL_SUPPLY_AT_GENESIS);
  //   assert!(libra_coin::supply() == FINAL_SUPPLY_AT_GENESIS, ESUPPLY_MISMATCH);


  //   // We need to simulate a long running network
  //   // where the Infra Pledge account accumulated.
  //   // Here we use Wayne Enterprises as the sole sponsor of the
  //   // test environment Infra Pedge
  //   let bruce_address = @0xBA7;
  //   ol_account::create_account(root, bruce_address);
  //   // Bruce inherits a fortune, the remainder of genesis mint
  //   ol_account::deposit_coins(bruce_address, genesis_mint);

  //   // Bruce pledges 37B to infra escrow
  //   let bruce = account::create_signer_for_test(bruce_address);
  //   pledge_accounts::user_pledge(&bruce, @ol_framework, INFRA_ESCROW_START);

  //   assert!(libra_coin::supply() == FINAL_SUPPLY_AT_GENESIS, ESUPPLY_MISMATCH);

  //   mint_cap
  // }

  #[test_only]
  public fun personas(): vector<address> {
    let val_addr = vector::empty<address>();
    vector::push_back(&mut val_addr, @0x1000a);
    vector::push_back(&mut val_addr, @0x1000b);
    vector::push_back(&mut val_addr, @0x1000c);
    vector::push_back(&mut val_addr, @0x1000d);
    vector::push_back(&mut val_addr, @0x1000e);
    vector::push_back(&mut val_addr, @0x1000f);
    vector::push_back(&mut val_addr, @0x10010); // g
    vector::push_back(&mut val_addr, @0x10011); // h
    vector::push_back(&mut val_addr, @0x10012); // i
    vector::push_back(&mut val_addr, @0x10013); // k
    val_addr
  }

  #[test_only]
  /// mock up to 6 validators alice..frank
  public fun genesis_n_vals(root: &signer, num: u64): vector<address> {
    // create vals with vouches
    create_vals(root, num, true);

    timestamp::fast_forward_seconds(2); // or else reconfigure wont happen
    stake::test_reconfigure(root, validator_universe::get_eligible_validators());

    stake::get_current_validators()
  }

  #[test_only]
  public fun create_vals(root: &signer, num: u64, with_vouches: bool) {
    system_addresses::assert_ol(root);
    let framework_sig = account::create_signer_for_test(@diem_framework);
    ol_test_genesis(&framework_sig);
    // need to initialize musical chairs separate from genesis.
    let musical_chairs_default_seats = 10;
    musical_chairs::initialize(root, musical_chairs_default_seats);

    let val_addr = personas();
    let i = 0;
    while (i < num) {
      let val = vector::borrow(&val_addr, i);
      let sig = account::create_signer_for_test(*val);
      let (_sk, pk, pop) = stake::generate_identity();
      validator_universe::test_register_validator(root, &pk, &pop, &sig, 100, true, true);

      vouch::init(&sig);
      if (with_vouches) {
        vouch::test_set_buddies(*val, val_addr);
      };

      i = i + 1;
    };

    pof_default(root);
  }

  #[test_only]
  const EPOCH_DURATION: u64 = 60;

  #[test_only]
  // NOTE: The order of these is very important.
  // ol first runs its own accounting at end of epoch with epoch_boundary
  // Then the stake module needs to update the validators.
  // the reconfiguration module must run last, since no other
  // transactions or operations can happen after the reconfig.
  public fun trigger_epoch(root: &signer) {
    trigger_epoch_exactly_at(
      root,
      reconfiguration::current_epoch(),
      block::get_current_block_height()
    );
  }

  public fun trigger_epoch_exactly_at(root: &signer, old_epoch: u64, round: u64) {
    timestamp::fast_forward_seconds(EPOCH_DURATION);
    epoch_boundary::ol_reconfigure_for_test(root, old_epoch, round);

    // always advance
    assert!(reconfiguration::current_epoch() > old_epoch,
    EDID_NOT_ADVANCE_EPOCH);

    // epoch helper should always be in sync
    assert!(reconfiguration::current_epoch() == epoch_helper::get_current_epoch(), 666);
  }


  //////// META TESTS ////////
  #[test(root=@ol_framework)]
  /// test we can trigger an epoch reconfiguration.
  public fun meta_epoch(root: signer) {
    ol_test_genesis(&root);
    musical_chairs::initialize(&root, 10);

    let epoch = reconfiguration::current_epoch();
    trigger_epoch(&root);
    let new_epoch = reconfiguration::current_epoch();
    assert!(new_epoch > epoch, 7357001);
  }

  #[test(root = @ol_framework)]
  public entry fun meta_val_perf(root: signer) {
    let set = genesis_n_vals(&root, 4);
    assert!(vector::length(&set) == 4, 7357001);

    let addr = vector::borrow(&set, 0);

    // will assert! case_1
    mock_case_1(&root, *addr);

    pof_default(&root);

    // will assert! case_4
    mock_case_4(&root, *addr);

    reset_val_perf_all(&root);

    mock_all_vals_good_performance(&root);
  }

  #[test(root = @ol_framework)]
  fun test_initial_supply(root: &signer) {
    // Scenario:
    // There are two community wallets. Alice and Bob's
    // EVE donates to both. But mostly to Alice.
    // The Match Index, should reflect that.

    let n_vals = 5;
    let _vals = genesis_n_vals(root, n_vals); // need to include eve to init funds

    ol_initialize_coin_and_fund_vals(root, EPOCH_REWARD, true);

    assert!(libra_coin::supply() == FINAL_SUPPLY_AT_GENESIS, 73570001);
  }


  #[test(root = @ol_framework)]
  fun test_setting_pof(root: &signer) {
    // Scenario: unit testing that pof_default results in a usable auction
    let n_vals = 5;
    let vals = genesis_n_vals(root, n_vals); // need to include eve to init funds
    pof_default(root);

    proof_of_fee::fill_seats_and_get_price(root, n_vals, &vals, &vals);

    let (nominal_reward, entry_fee, clearing_percent, median_bid ) = proof_of_fee::get_consensus_reward();

    assert!(nominal_reward == EPOCH_REWARD, 73570001);
    assert!(clearing_percent == 1, 73570002);
    assert!(entry_fee == ENTRY_FEE, 73570003);
    assert!(median_bid == 3, 73570004);
  }


  #[test(framework = @0x1, bob = @0x10002)]
  fun meta_test_minimal_account_init(framework: &signer, bob: address) {
    ol_mint_to(framework, bob, 123);
  }
}
