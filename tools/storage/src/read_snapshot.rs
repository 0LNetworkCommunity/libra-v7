//! read-archive
use anyhow::{anyhow, Context, Error, Result};
use diem_backup_cli::{
    backup_types::{
        epoch_ending::manifest::EpochEndingBackup, state_snapshot::manifest::StateSnapshotBackup,
    },
    storage::{FileHandle, FileHandleRef},
    utils::read_record_bytes::ReadRecordBytes,
};
use diem_types::{
    account_address::AccountAddress,
    account_state::AccountState,
    state_store::{
        state_key::{StateKey, StateKeyInner},
        state_value::StateValue,
    },
};
use libra_backwards_compatibility::legacy_recovery_v6;
use serde_json::json;
use std::{
    collections::HashMap,
    fs,
    path::{Path, PathBuf},
};
use tokio::{fs::OpenOptions, io::AsyncRead};

////// SNAPSHOT FILE IO //////
/// read snapshot manifest file into object
pub fn load_snapshot_manifest(path: &Path) -> Result<StateSnapshotBackup, Error> {
    let config =
        std::fs::read_to_string(path).context(format!("Error: cannot read file at {:?}", path))?;

    let map: StateSnapshotBackup = serde_json::from_str(&config)?;

    Ok(map)
}

/// get the epoch manifest from file
/// NOTE: this file may sometimes be gzipped. So if it's not parsing, that may
/// be why.
// https://github.com/0LNetworkCommunity/diem/blob/restore-hard-forks/storage/backup/backup-cli/src/backup_types/state_snapshot/backup.rs#L260
pub fn load_epoch_manifest(p: &Path) -> Result<EpochEndingBackup> {
    let bytes = fs::read(p)?;
    Ok(serde_json::from_slice::<EpochEndingBackup>(&bytes)?)
}

/// parse each chunk of a state snapshot manifest
pub async fn read_account_state_chunk(
    file_handle: FileHandle,
    archive_path: &Path,
) -> Result<Vec<(StateKey, StateValue)>, Error> {
    let full_handle = archive_path
        .parent()
        .expect("could not read archive path")
        .join(file_handle);
    let handle_str = full_handle.to_str().unwrap();
    let mut file = open_for_read(handle_str)
        .await
        .map_err(|e| anyhow!("snapshot chunk {:?}, {:?}", &handle_str, e))?;

    let mut chunk = vec![];

    while let Some(record_bytes) = file.read_record_bytes().await? {
        chunk.push(bcs::from_bytes(&record_bytes)?);
    }
    Ok(chunk)
}

async fn open_for_read(file_handle: &FileHandleRef) -> Result<Box<dyn AsyncRead + Send + Unpin>> {
    let file = OpenOptions::new().read(true).open(file_handle).await?;
    Ok(Box::new(file))
}

/// Tokio async parsing of state snapshot into blob
pub async fn accounts_from_snapshot_backup(
    manifest: StateSnapshotBackup,
    archive_path: &Path,
) -> anyhow::Result<Vec<AccountState>> {
    // parse AccountStateBlob from chunks of the archive
    let mut account_states_map: HashMap<AccountAddress, Vec<(StateKey, StateValue)>> =
        HashMap::new();
    for chunk in manifest.chunks {
        let blobs: Vec<(StateKey, StateValue)> =
            read_account_state_chunk(chunk.blobs, archive_path).await?;

        // Filter out the AccountState blobs
        // and group by address
        let account_states_map_chunk: HashMap<AccountAddress, Vec<(StateKey, StateValue)>> = blobs
            .into_iter()
            .fold(HashMap::new(), |mut acc, (key, blob)| {
                if let StateKeyInner::AccessPath(access_path) = key.inner() {
                    acc.entry(access_path.address)
                        .or_default()
                        .push((key, blob));
                }
                acc
            });

        // merge account_states_map_chunk into account_states_map
        for (address, blobs) in account_states_map_chunk {
            account_states_map.entry(address).or_default().extend(blobs);
        }
    }
    // materialize account state for each address
    let mut account_states: Vec<AccountState> = Vec::new();
    for (address, blobs) in account_states_map {
        #[allow(clippy::mutable_key_type)]
        let mut blobs_hash_table = HashMap::new();
        blobs.into_iter().for_each(|(key, blob)| {
            blobs_hash_table.insert(key, blob);
        });
        if let Some(a_state) =
            AccountState::from_access_paths_and_values(address, &blobs_hash_table)?
        {
            account_states.push(a_state);
        };
    }

    Ok(account_states)
}

#[test]
// TODO: adapt for V7.

fn test_parse_manifest() {
    use std::str::FromStr;
    let mut this_path = PathBuf::from_str(env!("CARGO_MANIFEST_DIR")).unwrap();
    this_path.push("fixtures/v7/state_epoch_116_ver_38180075.05af/state.manifest");
    let _r = load_snapshot_manifest(&this_path).expect("parse manifest");
    // dbg!(&r.epoch);
}

pub async fn manifest_to_json(manifest_path: PathBuf, out_path: Option<PathBuf>) {
    let snapshot_manifest = load_snapshot_manifest(&manifest_path).expect("parse manifest");
    let archive_path = manifest_path.parent().unwrap();
    let account_states = accounts_from_snapshot_backup(snapshot_manifest, archive_path)
        .await
        .expect("could not decode snapshot");
    let mut legacy_recovery_vec = Vec::new();
    for account_state in account_states.iter() {
        let legacy_recovery = legacy_recovery_v6::get_legacy_recovery(account_state)
            .expect("could not get legacy recovery");

        legacy_recovery_vec.push(legacy_recovery);
    }

    let json = json!(&legacy_recovery_vec);
    let out = out_path.unwrap_or(manifest_path.parent().unwrap().join("migration.json"));
    fs::write(out, json.to_string()).expect("could not save file");
}

#[tokio::test]
// TODO: adapt for V7.
#[ignore]

async fn test_export() {
    use std::str::FromStr;
    let this_path = PathBuf::from_str(env!("CARGO_MANIFEST_DIR")).unwrap();
    let manifest_path = this_path.join("fixtures/state_epoch_79_ver_33217173.795d/state.manifest");
    let export_path = this_path.join("json/v6_migration.json");
    manifest_to_json(manifest_path, Some(export_path)).await;
}

#[tokio::test]
// TODO: adapt for V7.
#[ignore]
async fn test_deserialize_account() {
    use std::str::FromStr;
    let mut this_path = PathBuf::from_str(env!("CARGO_MANIFEST_DIR")).unwrap();
    this_path.push("fixtures/state_epoch_79_ver_33217173.795d/state.manifest");
    let snapshot_manifest = load_snapshot_manifest(&this_path).expect("parse manifest");
    let archive_path = this_path.parent().unwrap();
    let account_states = accounts_from_snapshot_backup(snapshot_manifest, archive_path)
        .await
        .expect("could not decode snapshot");
    let mut legacy_recovery_vec = Vec::new();
    for account_state in account_states.iter() {
        let legacy_recovery = legacy_recovery_v6::get_legacy_recovery(account_state)
            .expect("could not get legacy recovery");

        legacy_recovery_vec.push(legacy_recovery);
    }

    // basic validation of the account state
    let account_count = 23634;
    assert_eq!(account_states.len(), account_count);

    // auth key
    assert_eq!(
        legacy_recovery_vec
            .iter()
            .filter(|l| l.auth_key.is_some())
            .fold(0, |count, _| count + 1),
        23633
    );
    // role
    assert_eq!(
        legacy_recovery_vec
            .iter()
            .filter(|l| l.role == legacy_recovery_v6::AccountRole::System)
            .fold(0, |count, _| count + 1),
        1
    );

    assert_eq!(
        legacy_recovery_vec
            .iter()
            .filter(|l| l.role == legacy_recovery_v6::AccountRole::Validator)
            .fold(0, |count, _| count + 1),
        74
    );

    // TODO: check that there are no operators in snapshot
    assert_eq!(
        legacy_recovery_vec
            .iter()
            .filter(|l| l.role == legacy_recovery_v6::AccountRole::Operator)
            .fold(0, |count, _| count + 1),
        0
    );

    // balance
    assert_eq!(
        legacy_recovery_vec
            .iter()
            .filter(|l| l.balance.is_some())
            .fold(0, |count, _| count + 1),
        23622
    );

    // val_cfg
    assert_eq!(
        legacy_recovery_vec
            .iter()
            .filter(|l| l.val_cfg.is_some())
            .fold(0, |count, _| count + 1),
        74
    );

    // val operator
    assert_eq!(
        legacy_recovery_vec
            .iter()
            .filter(|l| l.val_operator_cfg.is_some())
            .fold(0, |count, _| count + 1),
        0
    );

    // comm wallet
    assert_eq!(
        legacy_recovery_vec
            .iter()
            .filter(|l| l.comm_wallet.is_some())
            .fold(0, |count, _| count + 1),
        143
    );

    // ancestry
    assert_eq!(
        legacy_recovery_vec
            .iter()
            .filter(|l| l.ancestry.is_some())
            .fold(0, |count, _| count + 1),
        23574
    );

    // receipts
    assert_eq!(
        legacy_recovery_vec
            .iter()
            .filter(|l| l.receipts.is_some())
            .fold(0, |count, _| count + 1),
        4740
    );

    // cumulative deposits
    assert_eq!(
        legacy_recovery_vec
            .iter()
            .filter(|l| l.cumulative_deposits.is_some())
            .fold(0, |count, _| count + 1),
        145
    );

    // slow wallet
    assert_eq!(
        legacy_recovery_vec
            .iter()
            .filter(|l| l.slow_wallet.is_some())
            .fold(0, |count, _| count + 1),
        1210
    );

    // slow wallet list
    assert_eq!(
        legacy_recovery_vec
            .iter()
            .filter(|l| l.slow_wallet_list.is_some())
            .fold(0, |count, _| count + 1),
        1
    );

    // user burn preference
    // TODO:         // fixtures/state_epoch_79_ver_33217173.795d/0-.chunk has no such users
    assert_eq!(
        legacy_recovery_vec
            .iter()
            .filter(|l| l.user_burn_preference.is_some())
            .fold(0, |count, _| count + 1),
        0
    );

    // my vouches
    assert_eq!(
        legacy_recovery_vec
            .iter()
            .filter(|l| l.my_vouches.is_some())
            .fold(0, |count, _| count + 1),
        74
    );

    // tx schedule
    assert_eq!(
        legacy_recovery_vec
            .iter()
            .filter(|l| l.tx_schedule.is_some())
            .fold(0, |count, _| count + 1),
        145
    );

    // fee maker
    assert_eq!(
        legacy_recovery_vec
            .iter()
            .filter(|l| l.fee_maker.is_some())
            .fold(0, |count, _| count + 1),
        65
    );

    // jail
    assert_eq!(
        legacy_recovery_vec
            .iter()
            .filter(|l| l.jail.is_some())
            .fold(0, |count, _| count + 1),
        74
    );

    // my pledge
    assert_eq!(
        legacy_recovery_vec
            .iter()
            .filter(|l| l.my_pledge.is_some())
            .fold(0, |count, _| count + 1),
        199
    );

    // burn counter
    assert_eq!(
        legacy_recovery_vec
            .iter()
            .filter(|l| l.burn_counter.is_some())
            .fold(0, |count, _| count + 1),
        1
    );

    // donor voice registry
    assert_eq!(
        legacy_recovery_vec
            .iter()
            .filter(|l| l.donor_voice_registry.is_some())
            .fold(0, |count, _| count + 1),
        1
    );

    // epoch fee maker registry
    assert_eq!(
        legacy_recovery_vec
            .iter()
            .filter(|l| l.epoch_fee_maker_registry.is_some())
            .fold(0, |count, _| count + 1),
        1
    );

    // match index
    assert_eq!(
        legacy_recovery_vec
            .iter()
            .filter(|l| l.match_index.is_some())
            .fold(0, |count, _| count + 1),
        1
    );

    // validator universe
    assert_eq!(
        legacy_recovery_vec
            .iter()
            .filter(|l| l.validator_universe.is_some())
            .fold(0, |count, _| count + 1),
        1
    );
}
