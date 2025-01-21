// Burn or Match
// This (experimental) mechanism allows users to set their preferences for system-wide burns.
// A system burn may exist because of rate-limiting, or collecting more fees than there are rewards to pay out. Or other third-party contracts may have a requirement to burn.
// The user can elect a simple Burn, where the coin is permanently taken out of circulation, and the total supply is adjusted downward.
// A Match (aka recycle) will keep the coin internal, submit to wallets which have opted into being a Match recipient.
// There's a longer discussion on the game theory in ol/docs/burn_match.md
// The short version is: in 0L there are no whitelists anyhwere. As such an important design goal for Burn or Match is that there is no privilege required for an account to opt it. Another design goal is that you "put your money where your mouth is" and the cost is real (you could not weight the index by "stake-based" voting, you must forfeit the coins). This does not mean that opting-in has no constraints.
/// It doesn't require any permission to be a recipient of matching funds, it's open to all (including attackers). However, this mechanism uses a market to establish which of the opt-in accounts will receive funds. And this is a simple weighting algorithm which more heavily weights toward recent donations. Evidently there are attacks possible,

// It will be costly and unpredictable (but not impossible) for attacker to close the loop, on Matching funds to themselves. It's evident that an attacker can get return on investment by re-weighting the Match Index to favor a recipient controlled by them. This is especially the case if there is low participation in the market (i.e. very few people are donating out of band).
// Mitigations: There are conditions to qualify for matching. Matching accounts must be Community Wallets, which mostly means they are a Donor Directed with multi-sig enabled. See more under donor_voice.move, but in short there is a multisig to authorize transactions, and donors to that account can vote to delay, freeze, and ultimately liquidate the donor directed account. Since the attacker can clearly own all the multisig authorities on the Donor Directed account, there is another condition which is checked for: the multisig signers cannot be related by Ancestry, meaning the attacker needs to collect conspirators from across the network graph. Lastly, any system burns (e.g. proof-of-fee) from other honest users to that account gives them governance and possibly legal claims against that wallet, there is afterall an off-chain world.
// The expectation is that there is no additional overhead to honest actors, but considerable uncertainty and cost to abusers. Probabilistically there will be will some attacks or anti-social behavior. However, not all is lost: abusive behavior requires playing many other games honestly. The expectation of this experiment is that abuse is de-minimis compared to the total coin supply. As the saying goes: You can only prevent all theft if you also prevent all sales.

module ol_framework::burn {
  use std::fixed_point32;
  use std::signer;
  use std::vector;
  use diem_framework::account;
  use ol_framework::system_addresses;
  use ol_framework::libra_coin::LibraCoin;
  use ol_framework::coin::{Self, Coin};
  use ol_framework::match_index;
  use ol_framework::fee_maker;
  // use ol_framework::Debug::print;

  friend diem_framework::genesis;

  friend ol_framework::epoch_boundary;
  friend ol_framework::pledge_accounts;
  friend ol_framework::make_whole;

  #[test_only]
  friend ol_framework::mock;
  #[test_only]
  friend ol_framework::test_burn;
  #[test_only]
  friend ol_framework::test_rewards;
  #[test_only]
  friend ol_framework::test_slow_wallet;

  // the users preferences for system burns
  struct UserBurnPreference has key {
    send_community: bool
  }

  /// The Match index he accounts that have opted-in. Also keeps the lifetime_burned for convenience.
  struct BurnCounter has key {
    lifetime_burned: u64,
    lifetime_recycled: u64,
  }

    /// initialize, usually for testnet.
  public(friend) fun initialize(vm: &signer) {
    system_addresses::assert_ol(vm);

    move_to<BurnCounter>(vm, BurnCounter {
        lifetime_burned: 0,
        lifetime_recycled: 0,
      })
  }

  /// At the end of the epoch, after everyone has been paid
  /// subsidies (validators, oracle, maybe future infrastructure)
  /// then the remaining fees are burned or recycled
  /// Note that most of the time, the amount of fees produced by the Fee Makers
  /// is much larger than the amount of fees available burn.
  /// So we need to find the proportion of the fees that each Fee Maker has
  /// produced, and then do a weighted burn/recycle.
  /// @return a tuple of 2
  /// 0: BOOL, if epoch burn ran correctly
  /// 1: U64, how many coins burned
  public(friend) fun epoch_burn_fees(
      vm: &signer,
      coins: &mut Coin<LibraCoin>,
  ): (bool, u64)  acquires UserBurnPreference, BurnCounter {
      system_addresses::assert_ol(vm);

      // get the total fees made. This will likely be different than
      // the value of Coins, since some have already been spent on validator rewards.
      let total_fees_made = fee_maker::get_all_fees_made();

      // extract fees
      let available_to_burn = coin::value(coins);
      if (available_to_burn == 0) {
        // don't destroy, let the caller handle empty coins
        return (false, 0)
      };

      // get the list of fee makers
      let fee_makers = fee_maker::get_fee_makers();

      let len = vector::length(&fee_makers);

      // for every user in the list burn their fees per Burn.move preferences
      let i = 0;
      while (i < len) {
          let user = vector::borrow(&fee_makers, i);
          // belt and suspenders for dropped accounts in hard fork.
          if (!account::exists_at(*user)) {
            i = i + 1;
            continue
          };
          let user_made = fee_maker::get_user_fees_made(*user);
          let share = fixed_point32::create_from_rational(user_made, total_fees_made);

          let to_withdraw = fixed_point32::multiply_u64(available_to_burn, share);

          if (to_withdraw > 0 && to_withdraw <= available_to_burn) {
            let user_share = coin::extract(coins, to_withdraw);

            vm_burn_with_user_preference(vm, *user, user_share);
          };


          i = i + 1;
      };

    // Transaction fee account should be empty at the end of the epoch
    // Superman 3 decimal errors. https://www.youtube.com/watch?v=N7JBXGkBoFc
    // anything that is remaining should be burned
    let remainder = coin::value(coins);
    let leftover = coin::extract(coins, remainder);
    burn_and_track(leftover);
    // Note: we are still retruning an empty coin to be destroyed by the caller
    (true, total_fees_made)
  }



  /// Migration script for hard forks
  fun vm_migration(vm: &signer,
    lifetime_burned: u64, // these get reset on final supply V6. Future upgrades need to decide what to do with this
    lifetime_recycled: u64,
  ) {

    // TODO: assert genesis when timesetamp is working again.
    system_addresses::assert_vm(vm);

    move_to<BurnCounter>(vm, BurnCounter {
        lifetime_burned,
        lifetime_recycled,
      })
  }


  /// performs a burn and increments the tracker
  /// NOTE: this is unchecked, any user can perform this.
  /// the user should call this function and not burn methods on coin.move
  /// since those methods do not track the lifetime_burned
  public(friend) fun burn_and_track(coin: Coin<LibraCoin>) acquires BurnCounter {
    let value_sent = coin::value(&coin);
    let state = borrow_global_mut<BurnCounter>(@ol_framework);
    coin::user_burn(coin);
    state.lifetime_burned = state.lifetime_burned + value_sent;
  }

  #[test_only]
  public fun test_vm_burn_with_user_preference(
    vm: &signer, payer: address, user_share: Coin<LibraCoin>
  ) acquires BurnCounter, UserBurnPreference {
    vm_burn_with_user_preference(vm, payer, user_share);
  }

  /// performs a burn or recycle according to the attributed user's preference
  fun vm_burn_with_user_preference(
    vm: &signer, payer: address, user_share: Coin<LibraCoin>
  ) acquires BurnCounter, UserBurnPreference {
    system_addresses::assert_ol(vm);
    let value_sent = coin::value(&user_share);
    if (exists<UserBurnPreference>(payer)) {

      if (borrow_global<UserBurnPreference>(payer).send_community) {
        match_index::match_and_recycle(vm, &mut user_share);

         // update the root state tracker
        let state = borrow_global_mut<BurnCounter>(@ol_framework);
        state.lifetime_recycled = state.lifetime_recycled + value_sent;
      }
    };

    // do a default burn which is not attributed
    // also checks for Superman 3
    burn_and_track(user_share);
  }

  /// User opts into burns being sent to community (recycle burn).
  /// default is false (burn is final).
  public entry fun set_send_community(sender: &signer, community: bool) acquires UserBurnPreference {
    let addr = signer::address_of(sender);
    if (exists<UserBurnPreference>(addr)) {
      let b = borrow_global_mut<UserBurnPreference>(addr);
      b.send_community = community;
    } else {
      move_to<UserBurnPreference>(sender, UserBurnPreference {
        send_community: community
      });
    }
  }

  //////// GETTERS ////////

  #[view]
  /// returns tuple of (lifetime burned, lifetime recycled)
  public fun get_lifetime_tracker(): (u64, u64) acquires BurnCounter {
    let state = borrow_global<BurnCounter>(@ol_framework);
    (state.lifetime_burned, state.lifetime_recycled)
  }

  //////// TEST HELPERS ////////

}
