use diem_crypto::HashValue;
use libra_types::exports::AccountAddress;
use neo4rs::{BoltList, BoltMap, BoltType};
use serde_json::json;
use sqlx::prelude::FromRow;

#[derive(Debug, Clone)]
/// The basic information for an account
pub struct WarehouseRecord {
    pub account: WarehouseAccount,
    pub time: WarehouseTime,
    pub balance: Option<WarehouseBalance>,
}

impl WarehouseRecord {
    pub fn new(address: AccountAddress) -> Self {
        Self {
            account: WarehouseAccount { address },
            time: WarehouseTime::default(),
            balance: Some(WarehouseBalance::default()),
        }
    }
    pub fn set_time(&mut self, timestamp: u64, version: u64, epoch: u64) {
        self.time.timestamp = timestamp;
        self.time.version = version;
        self.time.epoch = epoch;
    }
}
// holds timestamp, chain height, and epoch
#[derive(Debug, Clone, Default)]
pub struct WarehouseTime {
    pub timestamp: u64,
    pub version: u64,
    pub epoch: u64,
}
#[derive(Debug, Clone)]
pub struct WarehouseAccount {
    pub address: AccountAddress,
}

#[derive(Debug, Default, Clone, FromRow)]
pub struct WarehouseBalance {
    // balances in v6+ terms
    #[sqlx(try_from = "i64")]
    pub balance: u64,
}

#[derive(Debug, Clone, FromRow)]
pub struct WarehouseTxMaster {
    pub tx_hash: HashValue, // primary key
    pub sender: String,
    pub function: String,
    pub epoch: u64,
    pub round: u64,
    pub block_timestamp: u64,
    pub expiration_timestamp: u64,
    // maybe there are counter parties
    pub recipients: Option<Vec<AccountAddress>>,
    pub args: serde_json::Value,
}

impl Default for WarehouseTxMaster {
    fn default() -> Self {
        Self {
            tx_hash: HashValue::zero(),
            sender: AccountAddress::ZERO.short_str_lossless(),
            function: "none".to_owned(),
            epoch: 0,
            round: 0,
            block_timestamp: 0,
            expiration_timestamp: 0,
            recipients: None,
            args: json!(""),
        }
    }
}

impl WarehouseTxMaster {
    /// since no sane Cypher serialization libraries exist.
    /// and I'm not going to write a deserializer.
    /// and JSON is not the same format as cypher property maps
    /// JSON5 but the last time someone updated
    /// that crate was 3 years ago.
    pub fn to_cypher_object_template(&self) -> String {
        format!(
            r#"{{tx_hash: "{}", sender: "{}", recipient: "{}"}}"#,
            self.tx_hash, self.sender, self.sender,
        )
    }

    /// make a string from the warehouse object
    pub fn slice_to_template(txs: &[Self]) -> String {
        let mut list_literal = "".to_owned();
        for el in txs {
            let s = el.to_cypher_object_template();
            list_literal = format!("{}\n", s);
        }
        format!("[{}]", list_literal)
    }

    // NOTE: this seems to be memory inefficient.
    // also creates a vendor lockin with neo4rs instead of any open cypher.
    // Hence the query templating
    pub fn to_boltmap(&self) -> BoltMap {
        let mut map = BoltMap::new();
        map.put("tx_hash".into(), self.tx_hash.to_string().into());
        map.put("sender".into(), self.sender.clone().into());
        map.put("recipient".into(), self.sender.clone().into());

        // TODO
        // map.put("epoch".into(), self.epoch.into());
        // map.put("round".into(), self.round.into());
        // map.put("epoch".into(), self.epoch.into());
        // map.put("block_timestamp".into(), self.block_timestamp.into());
        // map.put(
        //     "expiration_timestamp".into(),
        //     self.expiration_timestamp.into(),
        // );
        map
    }
    /// how one might implement the bolt types.
    pub fn slice_to_bolt_list(txs: &[Self]) -> BoltType {
        let mut list = BoltList::new();
        for el in txs {
            let map = el.to_boltmap();
            list.push(BoltType::Map(map));
        }
        BoltType::List(list)
    }
}

#[derive(Debug, Clone, FromRow)]
pub struct WarehouseDepositTx {
    pub tx_hash: HashValue, // primary key
    pub to: AccountAddress,
    pub amount: u64,
}

#[derive(Debug, Clone, FromRow)]
pub struct WarehouseEvent {
    pub tx_hash: HashValue, // primary key
    pub event_name: String,
    pub data: serde_json::Value,
}
