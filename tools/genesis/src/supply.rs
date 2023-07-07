
use libra_types::legacy_types::{
  legacy_address::LegacyAddress,
  legacy_recovery::LegacyRecovery,
};
use std::path::PathBuf;
use anyhow::Context;

#[derive(Debug, Clone, Default)]
pub struct Supply {
  pub total: f64,
  pub normal: f64,
  pub validator: f64, // will overlap with slow wallet
  pub slow_total: f64,
  pub slow_locked: f64,
  pub slow_validator_locked: f64,
  pub slow_unlocked: f64,
  pub donor_directed: f64,
}

fn inc_supply(mut acc: Supply, r: &LegacyRecovery, dd_wallet_list: &Vec<LegacyAddress>) -> anyhow::Result<Supply> {

    // get balances
    let amount: f64 = match &r.balance {
        Some(b) => {
          b.coin as f64
        },
        None => 0.0,
    };
    acc.total += amount;

    // get donor directed
    if dd_wallet_list.contains(&r.account.unwrap()) {
      acc.donor_directed += amount;
    } else if let Some(sl) = &r.slow_wallet {
      acc.slow_total += amount;
      if sl.unlocked > 0 {
        acc.slow_unlocked += amount;
        if amount > sl.unlocked as f64 { // Note: the validator may have transferred everything out, and the unlocked may not have changed
          let locked = amount - sl.unlocked as f64;
          acc.slow_locked += locked;
          // if this is the special case of a validator account with slow locked balance
          if r.val_cfg.is_some() {
            acc.validator += amount;
            acc.slow_validator_locked += locked;
          }

        }
      }


    } else if r.cumulative_deposits.is_some() { 
      // catches the cases of any dd wallets that were mapped to slow wallets
      acc.slow_locked += amount;
      acc.slow_total += amount;
    } else {
      
      acc.normal += amount;
    }
    Ok(acc)
}

/// iterate over the recovery file and get the sum of all balances.
/// there's an option to map certain donor-directed wallets to be counted as slow wallets
/// Note: this may not be the "total supply", since there may be coins in other structs beside an account::balance, e.g escrowed in contracts.
pub fn get_supply_struct(rec: &Vec<LegacyRecovery>, map_dd_to_slow: Vec<LegacyAddress>) -> anyhow::Result<Supply> {
  let zeroth = Supply {
    total: 0.0,
    normal: 0.0,
    validator: 0.0,
    slow_total: 0.0,
    slow_locked: 0.0,
    slow_validator_locked: 0.0,
    slow_unlocked: 0.0,
    donor_directed: 0.0,
  };

  let dd_wallets = rec.iter()
    .find(|el| { el.comm_wallet.is_some() })
    .context("could not find 0x0 state")?
    .comm_wallet
    .as_ref()
    .context("could not find list of community wallets")?;

  let dd_list: Vec<LegacyAddress> = dd_wallets.clone().list
      .into_iter()
      .filter(|e| !map_dd_to_slow.contains(e))
      .collect();

  rec.iter().try_fold(zeroth, |acc, r| {
    inc_supply(acc, r, &dd_list)
  })
}


#[test]
fn test_genesis_math() {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/sample_export_recovery.json");
    
    let r = crate::parse_json::parse(p).unwrap();

    // donor directed addresses that should be liquided before upgrade
    // the sample would be distorted by including these
    let ignore_for_dd_count =  vec![
      // FTW
      "3A6C51A0B786D644590E8A21591FA8E2".parse::<LegacyAddress>().unwrap(),
      // tip jar
      "2B0E8325DEA5BE93D856CFDE2D0CBA12".parse::<LegacyAddress>().unwrap(),
    ];

    // confirm the supply of normal, slow, and donor directed will add up to 100%
    
    let supply = get_supply_struct(&r, ignore_for_dd_count).unwrap();
    dbg!(&supply);

    println!("before");
    let pct_normal= supply.normal / supply.total;
    dbg!(&pct_normal);
    let pct_dd = supply.donor_directed / supply.total;
    dbg!(&pct_dd);
    let pct_slow = supply.slow_total / supply.total;
    dbg!(&pct_slow);
    let pct_val_locked = supply.slow_validator_locked / supply.total;
    dbg!(&pct_val_locked);

    let sum_all_pct = pct_normal + pct_slow + pct_dd;
    assert!(sum_all_pct == 1.0);
    assert!(supply.total == 2397436809784621.0);

    // genesis infra escrow math
    // future uses is intended to equal 70% in this scenario.
    println!("after");
    let target_future_uses = supply.total * 0.70;
    let remaining_to_fund = target_future_uses - supply.donor_directed;
    let ratio: f64 = remaining_to_fund / supply.slow_validator_locked;

    // escrow comes out of validator locked only
    let to_escrow = ratio * supply.slow_validator_locked;
    let new_slow = supply.slow_total - to_escrow;
    dbg!(&pct_normal);
    dbg!(&pct_dd);
    dbg!(new_slow /supply.total);
    dbg!(to_escrow /supply.total);

    let sum_all = to_escrow + new_slow + supply.normal + supply.donor_directed;
    assert!(supply.total == sum_all);
}