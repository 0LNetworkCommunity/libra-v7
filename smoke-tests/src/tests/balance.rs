use crate::helpers::{get_libra_balance, mint_libra};
use libra_framework::release::ReleaseTarget;
use zapatos_forge::Swarm;
use zapatos_sdk::types::LocalAccount;
use zapatos_smoke_test::smoke_test_environment::new_local_swarm_with_release;

#[tokio::test]
// let's check that this test environment produces same coins as expected in unit tests, and we have the tools to mint and test balances
async fn sanity_balances() -> anyhow::Result<()>{
    let release = ReleaseTarget::Head.load_bundle().unwrap();
    let mut swarm = new_local_swarm_with_release(4, release).await;
    let v = swarm.validators_mut().next().unwrap();
    let pri_key = v.account_private_key().as_ref().unwrap();
    let address = v.peer_id().to_owned();
    let _account = LocalAccount::new(v.peer_id(), pri_key.private_key(), 0);
    let mut public_info: zapatos_forge::DiemPublicInfo = swarm.diem_public_info();

    let bal_vec = get_libra_balance(public_info.client(), address).await?;
    assert!(bal_vec.first().unwrap() == &0, "expected zero balance at genesis");

    let _ = mint_libra(&mut public_info, address, 12345).await;

    let bal_vec = get_libra_balance(public_info.client(), address).await?;
    assert!(bal_vec.first().unwrap() == &12345, "expected balance of 12345");

    Ok(())
}

