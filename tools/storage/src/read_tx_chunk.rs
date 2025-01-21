use std::path::Path;

use anyhow::{anyhow, Context, Result};

use diem_backup_cli::backup_types::transaction::manifest::TransactionBackup;
use diem_backup_cli::backup_types::transaction::manifest::TransactionChunk;
use diem_backup_cli::utils::read_record_bytes::ReadRecordBytes;
use diem_types::contract_event::ContractEvent;
use diem_types::transaction::Transaction;
use diem_types::transaction::TransactionInfo;
use diem_types::write_set::WriteSet;
use libra_backwards_compatibility::version_five::state_snapshot_v5::open_for_read;

/// read snapshot manifest file into object
pub fn load_tx_chunk_manifest(path: &Path) -> anyhow::Result<TransactionBackup> {
    let s =
        std::fs::read_to_string(path).context(format!("Error: cannot read file at {:?}", path))?;

    let map: TransactionBackup = serde_json::from_str(&s)?;

    Ok(map)
}

// similar to Loaded Chunk
// diem/storage/backup/backup-cli/src/backup_types/transaction/restore.rs
// The vectors below are OF THE SAME LENGTH
// It is a table where for example, a tx without events will be an empty slot in the vector.
pub struct TransactionArchiveChunk {
    pub manifest: TransactionChunk,
    pub txns: Vec<Transaction>,
    pub txn_infos: Vec<TransactionInfo>,
    pub event_vecs: Vec<Vec<ContractEvent>>,
    pub write_sets: Vec<WriteSet>,
}

pub async fn load_chunk(
    archive_path: &Path,
    manifest: TransactionChunk,
) -> Result<TransactionArchiveChunk> {
    let full_handle = archive_path
        .parent()
        .expect("could not read archive path")
        .join(&manifest.transactions);
    let handle_str = full_handle.to_str().unwrap();
    assert!(full_handle.exists(), "file does not exist");

    let mut file = open_for_read(handle_str)
        .await
        .map_err(|e| anyhow!("snapshot chunk {:?}, {:?}", &handle_str, e))?;

    let mut txns = Vec::new();
    let mut txn_infos = Vec::new();
    let mut event_vecs = Vec::new();
    let mut write_sets = Vec::new();

    while let Some(record_bytes) = file.read_record_bytes().await? {
        let (txn, txn_info, events, write_set): (_, _, _, WriteSet) =
            bcs::from_bytes(&record_bytes)?;
        txns.push(txn);
        txn_infos.push(txn_info);
        event_vecs.push(events);
        write_sets.push(write_set);
    }

    // the chunk is a table implements with vectors,
    // they should have the same length
    assert!(
        txns.len() == txn_infos.len()
            && txn_infos.len() == event_vecs.len()
            && event_vecs.len() == write_sets.len(),
        "transactions chunk have different vector length for txs, events, and writesets"
    );

    // TODO: for purposes of explorer/warehouse do we want to do the full tx restore controller verifications

    Ok(TransactionArchiveChunk {
        manifest,
        txns,
        txn_infos,
        event_vecs,
        write_sets,
    })
}
