///////////////////////////////////////////////////////////////////////////
// 0L Module
// Pledge Accounts
///////////////////////////////////////////////////////////////////////////
// How does a decentralized project gather funds, without the authority of a foundation?
// 0L presents two options to builders: PledgeAccounts and DonorDirectedAccounts. Pledge accounts are coins which are the user's property
// but use strong coordination of smart contracts to guarantee funding.
// DonorDirectedAccounts are coins which are the beneficiary's property, but have strong coordination to refund, and veto account transactions.
// Regarding DonorDirectedAccounts, there is a subtype called CommunityWallets which have special properties: they can (permissionlessly) receive matching funds from the Burn Match of user/validator rewards. These have voluntary restrictions such as funds can only be transferred to slow wallet (to prevent gaming of the matching funds ), and have a purpose designed multisig n-of-m authorization for transactions.

// each of these accounts have a unique purpose, and are designed to be used in a specific way. DonorDirected accounts will be best suited to programs that have a lot of human management involved: evaluating the merit of proposals for spending. The donors need agility to spend the funds, hence they are in the user's proprty.

// PledgeAccounts are best suited for automated contributions. For charing fees algorithmically. It's also important for cases where pooled funding may not be practical or regulatorily advisable.

// The hard problem of coordination is how to get a group of people to
// fund common interest, when each person in the group
// can only pledge a small amount, and has no guarantee that the remainder
// will be filled. And once pledged there is always the risk that the
// user will renege on the pledge, this is a classic prisoner's dilemma.
// As such not even the first funds of most committed members will arrive
// because it's known that the project is doomed. This is the tragedy of
// the commons.

// Smart contracts may help, if they can be trusted. Thus the service needs
// to be provided with the highest level of shared security (no one can hold
// the key to the funds.
// Pledge Accounts are a service that the chain provides.
// The funds never leave the user's possession. They are placed in Pledged Accounts, a segregated sub-account on the user's account.
// The pledged accounts are project-specific.
// Projects which raise through pledges, can lose the pledge though a vote
// of the pledgers. There are no funds to return, instead the earmarked funds are no longer authorized for withdrawal, i.e. they return to user accounts.

// For voting we can only use the value pledged at the time of the vote,
// same for the purposes of revoking.
// Note that there's a known policy issue here, which is not addresses for
// now. A "chip bully" can add funds to the pledge, and then vote to revoke, knowing that they can get over the threshold. The current
// mitigation is to only allow Unlocked coins, which levels the playing field.
///////////////////////////////////////////////////////////////////////////


    module ol_framework::pledge_accounts{
        use std::vector;
        use std::signer;
        use std::error;
        use std::option::{Self, Option};
        use std::fixed_point64;
        use ol_framework::libra_coin::{Self, LibraCoin};
        use ol_framework::ol_account;
        use ol_framework::epoch_helper;
        use ol_framework::burn;
        use diem_framework::coin;
        use diem_framework::system_addresses;

        //use diem_std::debug::print;

        friend ol_framework::infra_escrow;
        friend ol_framework::genesis_migration;
        friend ol_framework::genesis;

        #[test_only]
        friend ol_framework::mock;

        /// no policy at this address
        const ENO_BENEFICIARY_POLICY: u64 = 1;
        /// there is a non zero balance
        const ENON_ZERO_BALANCE: u64 = 2;
        /// pledge is not initialized
        const ENO_PLEDGE_INIT: u64 = 3;

        struct MyPledges has key {
          list: vector<PledgeAccount>
        }

        // A Pledge Account is a sub-account on a user's account.
        struct PledgeAccount has key, store {
            // project_id: vector<u8>, // a string that identifies the project
            address_of_beneficiary: address, // the address of the project, also where the BeneficiaryPolicy is stored for reference.
            amount: u64,
            pledge: coin::Coin<LibraCoin>,
            epoch_of_last_deposit: u64,
            lifetime_pledged: u64,
            lifetime_withdrawn: u64
        }

        // A struct with some rules established by the beneficiary
        // that is agreed on, upon pledge.
        // IMPORTANT: this struct cannot be modified after a pledge is made.

        struct BeneficiaryPolicy has key, store, copy {
          purpose: vector<u8>, // a string that describes the purpose of the pledge
          vote_threshold_to_revoke: u64, // Percent in two digits, no decimals: the threshold of votes, weighted by pledged balance, needed to dissolve, and revoke the pledge.
          burn_funds_on_revoke: bool, // neither the beneficiary not the pledger can get the funds back, they are burned. Changes the game theory, may be necessary to in certain cases to prevent attacks in high stakes projects.
          amount_available: u64, // The amount available to withdraw
          lifetime_pledged: u64, // Of all users
          lifetime_withdrawn: u64, // Of all users
          pledgers: vector<address>,
          // TODO: use proper table data structure. This is oldschool Libra pattern.
          table_votes_to_revoke: vector<u64>, // recalculate on each vote to revoke.
          table_revoking_electors: vector<address>, // the list of electors who have voted to revoke. They can also cancel their vote.
          total_revoke_vote: u64, // for informational purposes,
          revoked: bool, // for historical record keeping.
        }

        // convenience tracker of all beneficiaries
        struct BeneficiaryRegistry has key {
          list: vector<address>
        }

        public(friend) fun initialize(framework: &signer) {
          if (!exists<BeneficiaryRegistry>(@ol_framework)) {
              move_to(framework, BeneficiaryRegistry {
              list: vector::empty()
            })
          }
        }
        // beneficiary publishes a policy to their account.
        // NOTE: It cannot be modified after a first pledge is made!.
        public(friend) fun publish_beneficiary_policy(
          user_sig: &signer,
          purpose: vector<u8>,
          vote_threshold_to_revoke: u64,
          burn_funds_on_revoke: bool
        ) acquires BeneficiaryPolicy, BeneficiaryRegistry {
            let addr = signer::address_of(user_sig);
            if (!exists<BeneficiaryPolicy>(addr)) {
                let beneficiary_policy = BeneficiaryPolicy {
                    purpose: purpose,
                    vote_threshold_to_revoke: vote_threshold_to_revoke,
                    burn_funds_on_revoke: burn_funds_on_revoke,
                    amount_available: 0,
                    lifetime_pledged: 0,
                    lifetime_withdrawn: 0,
                    pledgers: vector::empty(),
                    table_votes_to_revoke: vector::empty(),
                    table_revoking_electors: vector::empty(),
                    total_revoke_vote: 0,
                    revoked: false

                };
                move_to(user_sig, beneficiary_policy);
                let registry = borrow_global_mut<BeneficiaryRegistry>(addr);
                vector::push_back(&mut registry.list, addr)
            } else {
              // allow the beneficiary to write drafts, and modify the policy, as long as no pledge has been made.
              let b = borrow_global_mut<BeneficiaryPolicy>(addr);
              if (vector::length(&b.pledgers) == 0) {
                b.purpose = purpose;
                b.vote_threshold_to_revoke = vote_threshold_to_revoke;
                b.burn_funds_on_revoke = burn_funds_on_revoke;
              }
            }
            // no changes can be made if a pledge has been made.
        }

        // Initialize a list of pledges on a user's account
        fun maybe_initialize_my_pledges(account: &signer) {
            if (!exists<MyPledges>(signer::address_of(account))) {
                let my_pledges = MyPledges { list: vector::empty() };
                move_to(account, my_pledges);
            }
        }

        /// saves a pledge if it exists
        public(friend) fun save_pledge(
          sig: &signer,
          address_of_beneficiary: address,
          pledge: coin::Coin<LibraCoin>
        ) acquires MyPledges, BeneficiaryPolicy {
          maybe_initialize_my_pledges(sig);
          assert!(exists<BeneficiaryPolicy>(address_of_beneficiary), error::invalid_state(ENO_BENEFICIARY_POLICY));
          let sender_addr = signer::address_of(sig);
          let (found, idx) = pledge_at_idx(&sender_addr, &address_of_beneficiary);
          if (found) {
            add_coin_to_pledge_account(sender_addr, idx, pledge)
          } else {
            create_pledge_account(sig, address_of_beneficiary, pledge)
          }
        }

        fun vm_add_to_pledge(
          vm: &signer,
          pledger: address,
          address_of_beneficiary: address,
          pledge: &mut coin::Coin<LibraCoin>
        ) acquires MyPledges, BeneficiaryPolicy {
          system_addresses::assert_ol(vm);
          assert!(exists<BeneficiaryPolicy>(address_of_beneficiary), error::invalid_state(ENO_BENEFICIARY_POLICY));

          let (found, idx) = pledge_at_idx(&pledger, &address_of_beneficiary);
          let value = coin::value(pledge);
          if (found) {
            let c = libra_coin::extract(pledge, value);
            add_coin_to_pledge_account(pledger, idx, c)
          }
          // caller of this function needs to decide what to do if the coin cannot be added. Which is why its a mutable reference.
        }

        // Create a new pledge account on a user's list of pledges
        fun create_pledge_account(
          sig: &signer,
          // project_id: vector<u8>,
          address_of_beneficiary: address,
          init_pledge: coin::Coin<LibraCoin>,
        ) acquires MyPledges, BeneficiaryPolicy {
            let account = signer::address_of(sig);
            maybe_initialize_my_pledges(sig);
            let my_pledges = borrow_global_mut<MyPledges>(account);
            let value = coin::value(&init_pledge);
            let new_pledge_account = PledgeAccount {
                address_of_beneficiary: address_of_beneficiary,
                amount: value,
                pledge: init_pledge,
                epoch_of_last_deposit: epoch_helper::get_current_epoch(),
                lifetime_pledged: value,
                lifetime_withdrawn: 0
            };
            vector::push_back(&mut my_pledges.list, new_pledge_account);

          let b = borrow_global_mut<BeneficiaryPolicy>(address_of_beneficiary);
          vector::push_back(&mut b.pledgers, account);

          b.amount_available = b.amount_available  + value;
          b.lifetime_pledged = b.lifetime_pledged + value;
        }

        // add funds to an existing pledge account
        // Note: only funds that are Unlocked and otherwise unrestricted can be used in pledge account.
        fun add_coin_to_pledge_account(sender_addr: address, idx: u64, coin: coin::Coin<LibraCoin>) acquires MyPledges, BeneficiaryPolicy {

          let amount = coin::value(&coin);
          let my_pledges = borrow_global_mut<MyPledges>(sender_addr);
          let pledge_account = vector::borrow_mut(&mut my_pledges.list, idx);

          pledge_account.amount = pledge_account.amount + amount;
          pledge_account.epoch_of_last_deposit = epoch_helper::get_current_epoch();
          pledge_account.lifetime_pledged = pledge_account.lifetime_pledged + amount;

          // merge the coins in the account
          libra_coin::merge(&mut pledge_account.pledge, coin);

          // must add pledger address the ProjectPledgers list on beneficiary account

          let b = borrow_global_mut<BeneficiaryPolicy>(pledge_account.address_of_beneficiary);
          vector::push_back(&mut b.pledgers, sender_addr);

          b.amount_available = b.amount_available  + amount;
          b.lifetime_pledged = b.lifetime_pledged + amount;

          // exits silently if nothing is found.
          // this is to prevent halting in the event that a VM route is calling the function and is unable to check the return value.
        }

        // withdraw an amount from all pledge accounts. Check first that there are remaining funds before attempting to withdraw.
        public(friend) fun withdraw_from_all_pledge_accounts(sig_beneficiary: &signer, amount: u64): option::Option<coin::Coin<LibraCoin>> acquires MyPledges, BeneficiaryPolicy {

          let address_of_beneficiary = signer::address_of(sig_beneficiary);
          if (!exists<BeneficiaryPolicy>(address_of_beneficiary)) {
            return option::none<coin::Coin<LibraCoin>>()
          };

          let pledgers = *&borrow_global<BeneficiaryPolicy>(address_of_beneficiary).pledgers;
          let amount_available = *&borrow_global<BeneficiaryPolicy>(address_of_beneficiary).amount_available;

          if (amount_available == 0 || amount == 0) {
            return option::none<coin::Coin<LibraCoin>>()
          };

          let pct_withdraw = fixed_point64::create_from_rational((amount as u128), (amount_available as u128));

          let i = 0;
          let all_coins = option::none<coin::Coin<LibraCoin>>();
          while (i < vector::length(&pledgers)) {
            let pledge_account = *vector::borrow(&pledgers, i);

            // DANGER: this is a private function that changes balances.
            if (!exists<MyPledges>(pledge_account)) continue;

            let c = withdraw_pct_from_one_pledge_account(&address_of_beneficiary, &pledge_account, &pct_withdraw);
            // GROSS: dealing with options in Move.
            // TODO: find a better way.
            if (option::is_none(&all_coins) && option::is_some(&c)) {

              let coin =  option::extract(&mut c);
              option::fill(&mut all_coins, coin);
              option::destroy_none(c);
            } else if (option::is_some(&c)) {

              let temp = option::extract(&mut all_coins);
              let coin =  option::extract(&mut c);
              libra_coin::merge(&mut temp, coin);
              option::destroy_none(all_coins);
              all_coins = option::some(temp);
              option::destroy_none(c);
            } else {
              option::destroy_none(c);
            };

            i = i + 1;
          };

          all_coins
        }


        fun get_user_pledges(account: &address): vector<address> acquires MyPledges {
          let list = vector::empty<address>();
          if (!exists<MyPledges>(*account)) return list;
          let user_state = borrow_global<MyPledges>(*account);
          let i = 0;
          while (i < vector::length(&user_state.list)) {
            let p = vector::borrow(&user_state.list, i);
            vector::push_back(&mut list, p.address_of_beneficiary);
            i = i + 1;
          };
          return list
        }

        // DANGER: private function that changes balances.
        // withdraw funds from one pledge account
        // this is to be used for funding,
        // but also for revoking a pledge
        // WARN: we must know there is a coin at this account before calling it.
        fun withdraw_from_one_pledge_account(address_of_beneficiary: &address, payer: &address, amount: u64): option::Option<coin::Coin<LibraCoin>> acquires MyPledges, BeneficiaryPolicy {

            let (found, idx) = pledge_at_idx(payer, address_of_beneficiary);

            if (found) {
              let pledge_state = borrow_global_mut<MyPledges>(*payer);

              let pledge_account = vector::borrow_mut(&mut pledge_state.list, idx);
              if (
                pledge_account.amount > 0 &&
                pledge_account.amount >= amount

                ) {

                  pledge_account.amount = pledge_account.amount - amount;

                  pledge_account.lifetime_withdrawn = pledge_account.lifetime_withdrawn + amount;


                  let coin = libra_coin::extract(&mut pledge_account.pledge, amount);

                  // return coin

                  // update the beneficiaries state too

                  let bp = borrow_global_mut<BeneficiaryPolicy>(*address_of_beneficiary);


                  bp.amount_available = bp.amount_available - amount;
                  bp.lifetime_withdrawn = bp.lifetime_withdrawn + amount;

                  return option::some(coin)
                };
            };

            option::none()
        }

        // DANGER: private function that changes balances.
        // withdraw funds from one pledge account
        // this is to be used for funding,
        // but also for revoking a pledge
        // WARN: we must know there is a coin at this account before calling it.
        fun withdraw_pct_from_one_pledge_account(address_of_beneficiary: &address, payer: &address, pct: &fixed_point64::FixedPoint64):Option<coin::Coin<LibraCoin>> acquires MyPledges, BeneficiaryPolicy {

            let (found, idx) = pledge_at_idx(payer, address_of_beneficiary);
            if (!found) return option::none<coin::Coin<LibraCoin>>(); // don't error on functions called by VM.

            let pledge_state = borrow_global_mut<MyPledges>(*payer);

            let pledge_account = vector::borrow_mut(&mut pledge_state.list, idx);

            let user_pledged_balance = (pledge_account.amount as u128);

            if (user_pledged_balance == 0) {
              return option::none<coin::Coin<LibraCoin>>()
            };


            let amount_withdraw = fixed_point64::multiply_u128(user_pledged_balance, *pct);

            if (amount_withdraw == 0) {
              return option::none<coin::Coin<LibraCoin>>()
            };

            if (user_pledged_balance >= amount_withdraw) {

                let downcast_withdraw = (amount_withdraw as u64);
                // update user pledge state
                pledge_account.amount = pledge_account.amount - downcast_withdraw;
                pledge_account.lifetime_withdrawn = pledge_account.lifetime_withdrawn + downcast_withdraw;

                // update the beneficiaries state too

                let bp = borrow_global_mut<BeneficiaryPolicy>(*address_of_beneficiary);

                bp.amount_available = bp.amount_available - downcast_withdraw;

                bp.lifetime_withdrawn = bp.lifetime_withdrawn + downcast_withdraw;

                let coin = libra_coin::extract(&mut pledge_account.pledge, downcast_withdraw);
                return option::some(coin)
              };
            option::none()
        }

        // vote to revoke a beneficiary's policy
        // this is just a vote, it requires a tally, and consensus to
        // revert the fund OR burn them, depending on policy
        fun vote_to_revoke_beneficiary_policy(account: &signer, address_of_beneficiary: address) acquires MyPledges, BeneficiaryPolicy {


            // first check if they have already voted
            // and if so, cancel in one step
            try_cancel_vote(account, address_of_beneficiary);

            let pledger = signer::address_of(account);
            let bp = borrow_global_mut<BeneficiaryPolicy>(address_of_beneficiary);

            vector::push_back(&mut bp.table_revoking_electors, pledger);
            let user_pledge_balance = get_user_pledge_amount(pledger, address_of_beneficiary);
            vector::push_back(&mut bp.table_votes_to_revoke, user_pledge_balance);
            bp.total_revoke_vote = bp.total_revoke_vote + user_pledge_balance;

            // The first voter to cross the threshold  also
            // triggers the dissolution.
            if (tally_vote(address_of_beneficiary)) {
              dissolve_beneficiary_project(address_of_beneficiary);
            };
        }

        // The user changes their mind.
        // They are retracting/cancelling their vote.
        fun try_cancel_vote(account: &signer, address_of_beneficiary: address) acquires BeneficiaryPolicy {
            let pledger = signer::address_of(account);
            let bp = borrow_global_mut<BeneficiaryPolicy>(address_of_beneficiary);

            let idx = find_index_of_vote(&bp.table_revoking_electors, &pledger);

            if (idx == 0) {
                return
            };
            //adjust the running totals
            let prior_vote = vector::borrow(&bp.table_votes_to_revoke, idx);
            bp.total_revoke_vote = bp.total_revoke_vote - *prior_vote;

            // update the vote
            vector::remove(&mut bp.table_revoking_electors, idx);
            vector::remove(&mut bp.table_votes_to_revoke, idx);
        }

        // helper to find the index of a vote the user has already cast
        fun find_index_of_vote(table_revoking_electors: &vector<address>, pledger: &address): u64 {
            if (vector::contains(table_revoking_electors, pledger)) {
                return 0
            };

            let i = 0;
            while (i < vector::length(table_revoking_electors)) {
                if (vector::borrow(table_revoking_electors, i) == pledger) {
                    return i
                };
                i = i + 1;
            };
            0 // TODO: return an option type
        }

        // count the votes.
        // does not change any state.
        fun tally_vote(address_of_beneficiary: address): bool acquires BeneficiaryPolicy {
            let bp = borrow_global<BeneficiaryPolicy>(address_of_beneficiary);
            let amount_available = (bp.amount_available as u128);
            let total_revoke_vote = (bp.total_revoke_vote as u128);

            // TODO: use FixedPoint here.
            let ratio = fixed_point64::create_from_rational(total_revoke_vote, amount_available);
            let pct = fixed_point64::multiply_u128(100, ratio);
            if (pct > (bp.vote_threshold_to_revoke as u128)) {
                return true
            };
            false
        }


        // Danger: this function must remain private!
        // private function to dissolve the beneficiary project, and return all funds to the pledgers.
        fun dissolve_beneficiary_project(address_of_beneficiary: address) acquires MyPledges, BeneficiaryPolicy {
            let pledgers = *&borrow_global<BeneficiaryPolicy>(address_of_beneficiary).pledgers;

            let is_burn = *&borrow_global<BeneficiaryPolicy>(address_of_beneficiary).burn_funds_on_revoke;

            let i = 0;
            while (i < vector::length(&pledgers)) {
                let pledge_account = vector::borrow(&pledgers, i);
                let user_pledge_balance = get_user_pledge_amount(*pledge_account, address_of_beneficiary);
                let c = withdraw_from_one_pledge_account(&address_of_beneficiary, pledge_account, user_pledge_balance);

                if (is_burn && option::is_some(&c)) {
                  let burn_this = option::extract(&mut c);
                  burn::burn_and_track(burn_this);
                  option::destroy_none(c);
                } else if (option::is_some(&c)) {
                  let refund_coin = option::extract(&mut c);
                  ol_account::deposit_coins(
                    address_of_beneficiary,
                    refund_coin,
                  );
                  option::destroy_none(c);
                } else {
                  option::destroy_none(c);
                };


                i = i + 1;
            };

          let bp = borrow_global_mut<BeneficiaryPolicy>(address_of_beneficiary);
          bp.revoked = true;

          // otherwise leave the information as-is for reference purposes
        }


        ////////// TX  //////////
        // for general pledge accounts
        public(friend) fun user_pledge(user_sig: &signer, beneficiary: address, amount: u64) acquires BeneficiaryPolicy, MyPledges {
          let coin = ol_account::withdraw(user_sig, amount);
          save_pledge(user_sig, beneficiary, coin);
        }

        ////////// GETTERS //////////

        fun pledge_at_idx(account: &address, address_of_beneficiary: &address): (bool, u64) acquires MyPledges {
          if (exists<MyPledges>(*account)) {
          let my_pledges = &borrow_global<MyPledges>(*account).list;
            let i = 0;
            while (i < vector::length(my_pledges)) {
                let p = vector::borrow(my_pledges, i);
                if (&p.address_of_beneficiary == address_of_beneficiary) {
                    return (true, i)
                };
                i = i + 1;
            };
          };
          (false, 0)
        }

      #[view]
      public fun get_user_pledge_amount(account: address, address_of_beneficiary: address): u64 acquires MyPledges {
          let (found, idx) = pledge_at_idx(&account, &address_of_beneficiary);
          if (found) {
            let my_pledges = borrow_global<MyPledges>(account);
            let p = vector::borrow(&my_pledges.list, idx);
            return p.amount
          };
          return 0
      }

      #[view]
      /// total amount availabe to withdraw for a beneficiary
      public fun get_available_to_beneficiary(bene: address): u64 acquires BeneficiaryPolicy {
        if (exists<BeneficiaryPolicy>(bene)) {
          let bp = borrow_global<BeneficiaryPolicy>(bene);
          return bp.amount_available
        };
        0
      }

      #[view]
      /// total amount pledged to a beneficiary over the lifetime of account
      public fun get_lifetime_to_beneficiary(bene: address): (u64, u64)acquires BeneficiaryPolicy {
        if (exists<BeneficiaryPolicy>(bene)) {
          let bp = borrow_global<BeneficiaryPolicy>(bene);
          return (bp.lifetime_pledged, bp.lifetime_withdrawn)
        };
        (0, 0)
      }

      #[view]
      /// get a list of all the addresses that pledged to this beneficiary
      public fun get_all_pledgers(bene: address): vector<address> acquires BeneficiaryPolicy {
        if (exists<BeneficiaryPolicy>(bene)) {
          let bp = borrow_global<BeneficiaryPolicy>(bene);
          return *&bp.pledgers
        };
        vector::empty<address>()
      }

      #[view]
      /// list the revocation votes for a beneficiary
      public fun get_revoke_vote(bene: address): (bool, fixed_point64::FixedPoint64) acquires BeneficiaryPolicy {
        let null = fixed_point64::create_from_raw_value(0);
        if (exists<BeneficiaryPolicy>(bene)) {
          let bp = borrow_global<BeneficiaryPolicy>(bene);
          if (bp.revoked) {
            return (true, null)
          } else if (
            bp.total_revoke_vote > 0 &&
            bp.amount_available > 0
          ) {
            return (
              false,
              fixed_point64::create_from_rational((bp.total_revoke_vote as u128), (bp.amount_available as u128))
            )
          }
        };
        (false, null)
      }

      #[view]
      public fun get_pledge_supply(): u64 acquires BeneficiaryRegistry, BeneficiaryPolicy {
        let registry = borrow_global<BeneficiaryRegistry>(@ol_framework);
        let sum = 0;
        vector::for_each(registry.list, |a| {
          sum = sum + get_available_to_beneficiary(a);
        });
        sum
      }

      ///////// MIGRATION ////////

              // Create a new pledge account on a user's list of pledges
      public(friend) fun migrate_pledge_account(
          framework: &signer,
          sig: &signer,
          // project_id: vector<u8>,
          address_of_beneficiary: address,
          init_pledge: coin::Coin<LibraCoin>,
          lifetime_pledged: u64,
          lifetime_withdrawn: u64,
        ) acquires MyPledges, BeneficiaryPolicy {
            system_addresses::assert_diem_framework(framework);
            let account = signer::address_of(sig);
            maybe_initialize_my_pledges(sig);
            let my_pledges = borrow_global_mut<MyPledges>(account);
            let value = coin::value(&init_pledge);
            let new_pledge_account = PledgeAccount {
                address_of_beneficiary: address_of_beneficiary,
                amount: value,
                pledge: init_pledge,
                epoch_of_last_deposit: epoch_helper::get_current_epoch(),
                lifetime_pledged: lifetime_pledged,
                lifetime_withdrawn: lifetime_withdrawn
            };
            vector::push_back(&mut my_pledges.list, new_pledge_account);

          let b = borrow_global_mut<BeneficiaryPolicy>(address_of_beneficiary);
          vector::push_back(&mut b.pledgers, account);

          b.amount_available = b.amount_available  + value;
          b.lifetime_pledged = b.lifetime_pledged + value;
        }


      //////// TEST HELPERS ///////
      #[test_only]
      // Danger! withdraws from an account.
      public fun test_single_withdrawal(framework: &signer, donor: address, amount: u64): coin::Coin<LibraCoin> acquires MyPledges, BeneficiaryPolicy{
        use ol_framework::testnet;
        system_addresses::assert_diem_framework(framework);
        testnet::assert_testnet(framework);

        let opt = withdraw_from_one_pledge_account(&@ol_framework, &donor, amount);
        assert!(option::is_some(&opt), 0);

        let c =  option::extract(&mut opt);
          option::destroy_none(opt);
          return c
      }

}
