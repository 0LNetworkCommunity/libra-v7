//! chain queries

use crate::query_view::{self, get_view};
use anyhow::Context;
use diem_sdk::rest_client::{diem_api_types::ViewRequest, Client};
use libra_types::type_extensions::client_ext::entry_function_id;

/// Retrieves the current epoch from the blockchain.
pub async fn get_epoch(client: &Client) -> anyhow::Result<u64> {
    let res = get_view(client, "0x1::epoch_helper::get_current_epoch", None, None).await?;

    let value: Vec<String> = serde_json::from_value(res)?;
    let num = value.first().unwrap().parse::<u64>()?;

    Ok(num)
}

/// helper to get libra balance at a SlowWalletBalance type which shows
/// total balance and the unlocked balance.
pub async fn get_tower_difficulty(client: &Client) -> anyhow::Result<(u64, u64)> {
    let slow_balance_id = entry_function_id("tower_state", "get_difficulty")?;
    let request = ViewRequest {
        function: slow_balance_id,
        type_arguments: vec![],
        arguments: vec![],
    };

    let res = client.view(&request, None).await?.into_inner();

    // TODO: Gross.
    let difficulty: u64 =
        serde_json::from_value::<String>(res.first().context("no difficulty returned")?.clone())?
            .parse()?;
    let security: u64 = serde_json::from_value::<String>(
        res.get(1).context("no security param returned")?.clone(),
    )?
    .parse()?;

    Ok((difficulty, security))
}

/// Retrieves the ID of the next governance proposal.
pub async fn get_next_governance_proposal_id(client: &Client) -> anyhow::Result<u64> {
    let query_res = query_view::get_view(
        client,
        "0x1::diem_governance::get_next_governance_proposal_id",
        None,
        None,
    )
    .await?;
    // let id: Vec<String> = serde_json::from_value(query_res)?;
    let num: u64 = serde_json::from_value::<Vec<String>>(query_res)?
        .first()
        .context("could not get a response from view function get_next_governance_proposal_id")?
        .parse()?;
    Ok(num)
}

/// Checks if a governance proposal can be resolved.
pub async fn can_gov_proposal_resolve(client: &Client, id: u64) -> anyhow::Result<bool> {
    let query_res = query_view::get_view(
        client,
        "0x1::diem_governance::get_can_resolve",
        None,
        Some(id.to_string()),
    )
    .await?;

    serde_json::from_value::<bool>(query_res).context("cannot parse api res")
}

// TODO: code duplication
/// Checks if a governance proposal with the given ID has been resolved.
pub async fn is_gov_proposal_resolved(client: &Client, id: u64) -> anyhow::Result<bool> {
    let query_res = query_view::get_view(
        client,
        "0x1::diem_governance::is_resolved",
        None,
        Some(id.to_string()),
    )
    .await?;

    serde_json::from_value::<Vec<bool>>(query_res)?
        .into_iter()
        .next()
        .context("could not get a response from view function is_resolved")
}

// TODO: code duplication
/// Retrieves votes for a governance proposal with the given ID.
pub async fn get_gov_proposal_votes(client: &Client, id: u64) -> anyhow::Result<Vec<u128>> {
    let query_res = query_view::get_view(
        client,
        "0x1::diem_governance::get_votes",
        None,
        Some(id.to_string()),
    )
    .await?;

    Ok(serde_json::from_value::<Vec<u128>>(query_res)?)
}

/// Retrieves the current blockchain height.
pub async fn get_height(client: &Client) -> anyhow::Result<u64> {
    let res = get_view(client, "0x1::block::get_current_block_height", None, None).await?;

    let value: Vec<String> = serde_json::from_value(res)?;
    let height = value.first().unwrap().parse::<u64>()?;

    Ok(height)
}
