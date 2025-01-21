module diem_framework::genesis {
    // use diem_std::debug::print;

    use std::error;
    use std::vector;

    use diem_framework::account;
    use diem_framework::aggregator_factory;
    use diem_framework::diem_governance;
    use diem_framework::block;
    use diem_framework::chain_id;
    use diem_framework::chain_status;
    use diem_framework::coin;
    use diem_framework::consensus_config;
    use diem_framework::execution_config;
    use diem_framework::create_signer::create_signer;
    use diem_framework::gas_schedule;
    use diem_framework::reconfiguration;
    use diem_framework::stake;
    use diem_framework::match_index;
    use diem_framework::state_storage;
    use diem_framework::storage_gas;
    use diem_framework::timestamp;
    use diem_framework::transaction_fee;
    use diem_framework::transaction_validation;
    use diem_framework::version;
    use diem_framework::randomness;

    //////// 0L ////////
    use diem_framework::validator_universe;
    use ol_framework::ol_account;
    use ol_framework::musical_chairs;
    use ol_framework::proof_of_fee;
    use ol_framework::secret_bid;
    use ol_framework::slow_wallet;
    use ol_framework::libra_coin;
    use ol_framework::infra_escrow;
    use ol_framework::safe;
    use ol_framework::donor_voice;
    use ol_framework::epoch_helper;
    use ol_framework::burn;
    use ol_framework::fee_maker;
    use ol_framework::pledge_accounts;
    use ol_framework::vouch;
    use ol_framework::testnet;
    use ol_framework::epoch_boundary;
    use ol_framework::sacred_cows;

    //////// end 0L ////////


    const EDUPLICATE_ACCOUNT: u64 = 1;
    const EACCOUNT_DOES_NOT_EXIST: u64 = 2;

    struct AccountMap has drop {
        account_address: address,
        balance: u64,
    }

    struct EmployeeAccountMap has copy, drop {
        accounts: vector<address>,
        validator: ValidatorConfigurationWithCommission,
        vesting_schedule_numerator: vector<u64>,
        vesting_schedule_denominator: u64,
        beneficiary_resetter: address,
    }

    struct ValidatorConfiguration has copy, drop {
        owner_address: address,
        operator_address: address,
        voter_address: address,
        stake_amount: u64,
        consensus_pubkey: vector<u8>,
        proof_of_possession: vector<u8>,
        network_addresses: vector<u8>,
        full_node_network_addresses: vector<u8>,
    }

    struct ValidatorConfigurationWithCommission has copy, drop {
        validator_config: ValidatorConfiguration,
        commission_percentage: u64,
        join_during_genesis: bool,
    }

    /// Genesis step 1: Initialize diem framework account and core modules on chain.
    fun initialize(
        gas_schedule: vector<u8>,
        chain_id: u8,
        initial_version: u64,
        consensus_config: vector<u8>,
        execution_config: vector<u8>,
        epoch_interval_microsecs: u64,
        _minimum_stake: u64,
        _maximum_stake: u64,
        _recurring_lockup_duration_secs: u64,
        _allow_validator_set_change: bool,
        _rewards_rate: u64,
        _rewards_rate_denominator: u64,
        _voting_power_increase_limit: u64,
    ) {
        // Initialize the diem framework account. This is the account where system resources and modules will be
        // deployed to. This will be entirely managed by on-chain governance and no entities have the key or privileges
        // to use this account.
        let (diem_framework_account, diem_framework_signer_cap) = account::create_framework_reserved_account(@diem_framework);
        // Initialize account configs on diem framework account.
        account::initialize(&diem_framework_account);

        transaction_validation::initialize(
            &diem_framework_account,
            b"script_prologue",
            b"module_prologue",
            b"multi_agent_script_prologue",
            b"epilogue",
        );

        // Give the decentralized on-chain governance control over the core framework account.
        diem_governance::store_signer_cap(&diem_framework_account, @diem_framework, diem_framework_signer_cap);

        // put reserved framework reserved accounts under diem governance
        let framework_reserved_addresses = vector<address>[@0x2, @0x3, @0x4, @0x5, @0x6, @0x7, @0x8, @0x9, @0xa];
        while (!vector::is_empty(&framework_reserved_addresses)) {
            let address = vector::pop_back<address>(&mut framework_reserved_addresses);
            let (_, framework_signer_cap) = account::create_framework_reserved_account(address);
            diem_governance::store_signer_cap(&diem_framework_account, address, framework_signer_cap);
        };

        consensus_config::initialize(&diem_framework_account, consensus_config);
        execution_config::set(&diem_framework_account, execution_config);
        version::initialize(&diem_framework_account, initial_version);
        stake::initialize(&diem_framework_account);
        storage_gas::initialize(&diem_framework_account);
        gas_schedule::initialize(&diem_framework_account, gas_schedule);

        // Ensure we can create aggregators for supply, but not enable it for common use just yet.
        aggregator_factory::initialize_aggregator_factory(&diem_framework_account);
        coin::initialize_supply_config(&diem_framework_account);

        chain_id::initialize(&diem_framework_account, chain_id);
        reconfiguration::initialize(&diem_framework_account);
        block::initialize(&diem_framework_account, epoch_interval_microsecs);
        state_storage::initialize(&diem_framework_account);
        randomness::initialize(&diem_framework_account);

        //////// 0L ////////

        validator_universe::initialize(&diem_framework_account);
        proof_of_fee::init_genesis_baseline_reward(&diem_framework_account);
        slow_wallet::initialize(&diem_framework_account);
        // tower_state::initialize(&diem_framework_account);
        safe::initialize(&diem_framework_account);
        donor_voice::initialize(&diem_framework_account);
        epoch_boundary::initialize(&diem_framework_account);
        epoch_helper::initialize(&diem_framework_account);
        burn::initialize(&diem_framework_account);
        match_index::initialize(&diem_framework_account);
        fee_maker::initialize(&diem_framework_account);
        pledge_accounts::initialize(&diem_framework_account);
        account::maybe_initialize_duplicate_originating(&diem_framework_account);
        infra_escrow::initialize(&diem_framework_account);

        let zero_x_two_sig = create_signer(@0x2);
        sacred_cows::init(&zero_x_two_sig);
        // end 0L

        timestamp::set_time_has_started(&diem_framework_account);
    }


    // TODO: 0L: this is called at genesis from Rust side. Need to replace names there.
    // we are leaving vendor's coin in place.
    /// Genesis step 2: Initialize Diem coin.
    fun initialize_diem_coin(diem_framework: &signer) {
        // NOTE 0L: genesis ceremony is calling this
        libra_coin::initialize(diem_framework);

        transaction_fee::initialize_fee_collection_and_distribution(diem_framework, 0);
    }

    /// Only called for testnets and e2e tests.
    fun initialize_core_resources_and_diem_coin(
        diem_framework: &signer,
        core_resources_auth_key: vector<u8>,
    ) {
        // let (burn_cap, mint_cap) = diem_coin::initialize(diem_framework);

        let core_resources = account::create_account(@core_resources);
        account::rotate_authentication_key_internal(&core_resources, core_resources_auth_key);

        // initialize gas
        let (burn_cap_two, mint_cap_two) = libra_coin::initialize_for_core(diem_framework);
        // give coins to the 'core_resources' account, which has sudo
        // core_resources is a temporary account, not the same as framework account.
        libra_coin::configure_accounts_for_test(diem_framework, &core_resources, mint_cap_two);

        // NOTE: smoke tests will fail without initializing tx fees as in genesis
        transaction_fee::initialize_fee_collection_and_distribution(diem_framework, 0);

        // NOTE: 0L: the commented code below shows that we are destroying
        // there capabilities elsewhere, at libra_coin::initialize
        coin::destroy_mint_cap(mint_cap_two);
        coin::destroy_burn_cap(burn_cap_two);

    }

    fun create_accounts(diem_framework: &signer, accounts: vector<AccountMap>) {
        let i = 0;
        let num_accounts = vector::length(&accounts);
        let unique_accounts = vector::empty();

        while (i < num_accounts) {
            let account_map = vector::borrow(&accounts, i);
            assert!(
                !vector::contains(&unique_accounts, &account_map.account_address),
                error::already_exists(EDUPLICATE_ACCOUNT),
            );
            vector::push_back(&mut unique_accounts, account_map.account_address);

            create_account(
                diem_framework,
                account_map.account_address,
                account_map.balance,
            );

            i = i + 1;
        };
    }

    /// This creates an funds an account if it doesn't exist.
    /// If it exists, it just returns the signer.
    fun create_account(diem_framework: &signer, account_address: address, _balance: u64): signer {
        if (!account::exists_at(account_address)) {
            ol_account::create_account(diem_framework, account_address);
        };

        create_signer(account_address)
    }

    fun create_initialize_validators_with_commission(
        diem_framework: &signer,
        _depr_use_staking_contract: bool,
        validators: vector<ValidatorConfigurationWithCommission>,
    ) {
        let i = 0;
        let num_validators = vector::length(&validators);

        let val_addr_list = vector::empty();

        while (i < num_validators) {

            let validator = vector::borrow(&validators, i);
            register_one_genesis_validator(diem_framework, validator, false);
            vector::push_back(&mut val_addr_list, *&validator.validator_config.owner_address);

            infra_escrow::genesis_coin_validator(diem_framework,
            *&validator.validator_config.owner_address);

            // default 90% to align with thermostatic rule in the PoF paper.
            // otherwise the thermostatic rule starts kicking-in immediately
            let sig = create_signer(validator.validator_config.owner_address);

            // genesis validators need a bid struct
            secret_bid::genesis_helper(diem_framework, &sig, 100);

            if (testnet::is_not_mainnet()) {
              // TODO: this is for testnet purposes only
              // unlock some of the genesis validators coins so they can issue
              // transactions from epoch 0 in test runners.
              slow_wallet::slow_wallet_epoch_drip(diem_framework, 100000000);
            };

            i = i + 1;
        };

        vector::for_each(val_addr_list, |one_val| {
          vouch::vm_migrate(diem_framework, one_val, val_addr_list);
        });

        musical_chairs::initialize(diem_framework, num_validators);
        ////////
        // TODO: maybe consolidate reconfig methods in one place
        // for smoke tests
        // stake::maybe_reconfigure(diem_framework,
        // validator_universe::get_eligible_validators());
        ///////
        stake::on_new_epoch()
    }

    fun create_initialize_validators(diem_framework: &signer, validators: vector<ValidatorConfiguration>) {
        let i = 0;
        let num_validators = vector::length(&validators);

        let validators_with_commission = vector::empty();

      while (i < num_validators) {
          let validator_with_commission = ValidatorConfigurationWithCommission {
              validator_config: vector::pop_back(&mut validators),
              commission_percentage: 0,
              join_during_genesis: true,
          };
          vector::push_back(&mut validators_with_commission, validator_with_commission);

          i = i + 1;
      };

      create_initialize_validators_with_commission(diem_framework, false, validators_with_commission);
    }

    fun register_one_genesis_validator(
        diem_framework: &signer,
        commission_config: &ValidatorConfigurationWithCommission,
        _use_staking_contract: bool,
    ) {
      let validator = &commission_config.validator_config;

      let owner = &create_account(diem_framework, validator.owner_address, validator.stake_amount);

      validator_universe::register_validator(
        owner,
        validator.consensus_pubkey,
        validator.proof_of_possession,
        validator.network_addresses,
        validator.full_node_network_addresses,
      );

      stake::join_validator_set(owner, validator.owner_address);
    }

    /// The last step of genesis.
    fun set_genesis_end(diem_framework: &signer) {
        chain_status::set_genesis_end(diem_framework);
    }

    #[verify_only]
    use std::features;

    #[verify_only]
    fun initialize_for_verification(
        gas_schedule: vector<u8>,
        chain_id: u8,
        initial_version: u64,
        consensus_config: vector<u8>,
        execution_config: vector<u8>,
        epoch_interval_microsecs: u64,
        minimum_stake: u64,
        maximum_stake: u64,
        recurring_lockup_duration_secs: u64,
        allow_validator_set_change: bool,
        rewards_rate: u64,
        rewards_rate_denominator: u64,
        voting_power_increase_limit: u64,
        diem_framework: &signer,
        min_voting_threshold: u128,
        _required_proposer_stake: u64,
        voting_duration_secs: u64,
        accounts: vector<AccountMap>,
        _employee_vesting_start: u64,
        _employee_vesting_period_duration: u64,
        _employees: vector<EmployeeAccountMap>,
        _validators: vector<ValidatorConfigurationWithCommission>
    ) {
        initialize(
            gas_schedule,
            chain_id,
            initial_version,
            consensus_config,
            execution_config,
            epoch_interval_microsecs,
            minimum_stake,
            maximum_stake,
            recurring_lockup_duration_secs,
            allow_validator_set_change,
            rewards_rate,
            rewards_rate_denominator,
            voting_power_increase_limit
        );
        features::change_feature_flags(diem_framework, vector[1, 2], vector[]);
        initialize_diem_coin(diem_framework);
        diem_governance::initialize_for_verification(
            diem_framework,
            min_voting_threshold,
            voting_duration_secs
        );
        create_accounts(diem_framework, accounts);
        // create_employee_validators(employee_vesting_start, employee_vesting_period_duration, employees);
        // create_initialize_validators_with_commission(diem_framework, true, validators);
        set_genesis_end(diem_framework);
    }

    //////// 0L ////////
    #[test_only]
    public fun test_end_genesis(framework: &signer) {
        set_genesis_end(framework);
    }

    //////// 0L ////////
    #[test_only]
    public fun test_initalize_coins(framework: &signer) {
        initialize_diem_coin(framework);
    }


    #[test_only]
    public fun setup() {
        initialize(
            x"000000000000000000", // empty gas schedule
            4u8, // TESTING chain ID
            0,
            x"12",
            x"13",
            1,
            0,
            1,
            1,
            true,
            1,
            1,
            30,
        )
    }

    #[test]
    fun test_setup() {
        setup();
        assert!(account::exists_at(@diem_framework), 1);
        assert!(account::exists_at(@0x2), 1);
        assert!(account::exists_at(@0x3), 1);
        assert!(account::exists_at(@0x4), 1);
        assert!(account::exists_at(@0x5), 1);
        assert!(account::exists_at(@0x6), 1);
        assert!(account::exists_at(@0x7), 1);
        assert!(account::exists_at(@0x8), 1);
        assert!(account::exists_at(@0x9), 1);
        assert!(account::exists_at(@0xa), 1);
    }

    #[test(diem_framework = @0x1)]
    fun test_create_account(diem_framework: &signer) {
        setup();
        initialize_diem_coin(diem_framework);

        let addr = @0x121341; // 01 -> 0a are taken
        let test_signer_before = create_account(diem_framework, addr, 15);
        let test_signer_after = create_account(diem_framework, addr, 500);
        assert!(test_signer_before == test_signer_after, 0);
        assert!(libra_coin::balance(addr) == 0, 1); //////// 0L ////////
    }

    #[test(diem_framework = @0x1)]
    fun test_create_accounts(diem_framework: &signer) {
        setup();
        initialize_diem_coin(diem_framework);

        // 01 -> 0a are taken
        let addr0 = @0x121341;
        let addr1 = @0x121345;

        let accounts = vector[
            AccountMap {
                account_address: addr0,
                balance: 12345,
            },
            AccountMap {
                account_address: addr1,
                balance: 67890,
            },
        ];

        create_accounts(diem_framework, accounts);
        assert!(libra_coin::balance(addr0) == 0, 0); //////// 0L //////// no coins minted at genesis
        assert!(libra_coin::balance(addr1) == 0, 1); //////// 0L ////////

        create_account(diem_framework, addr0, 23456);
        assert!(libra_coin::balance(addr0) == 0, 2); //////// 0L ////////
    }
}
