use anyhow::Result;
use neo4rs::Graph;

pub static ACCOUNT_UNIQUE: &str =
    "CREATE CONSTRAINT unique_address FOR (n:Account) REQUIRE n.address IS UNIQUE";

// pub static ACCOUNT_NOT_NULL: &str =
//   "CREATE CONSTRAINT account_not_null FOR (n:Account) REQUIRE n.address IS NOT NULL";

pub static TX_CONSTRAINT: &str =
    "CREATE CONSTRAINT unique_tx_hash FOR ()-[r:Tx]-() REQUIRE r.tx_hash IS UNIQUE";

// assumes the Account.address is stored as a hex string
// NOTE: hex numericals may query faster but will be hard to use in user interface
pub static INDEX_HEX_ADDR: &str =
    "CREATE TEXT INDEX hex_addr IF NOT EXISTS FOR (n:Account) ON (n.address)";

pub static INDEX_TX_TIMESTAMP: &str =
    "CREATE INDEX tx_timestamp IF NOT EXISTS FOR ()-[r:Tx]-() ON (r.block_timestamp)";

pub static INDEX_TX_FUNCTION: &str =
    "CREATE INDEX tx_function IF NOT EXISTS FOR ()-[r:Tx]-() ON (r.function)";

/// get the driver connection object
pub async fn get_neo4j_pool(port: u16) -> Result<Graph> {
    let uri = format!("127.0.0.1:{port}");
    let user = "neo4j";
    let pass = "neo";
    Ok(Graph::new(uri, user, pass).await?)
}

pub async fn create_indexes(graph: &Graph) -> Result<()> {
    let mut txn = graph.start_txn().await.unwrap();

    txn.run_queries([
        ACCOUNT_UNIQUE,
        TX_CONSTRAINT,
        INDEX_HEX_ADDR,
        INDEX_TX_TIMESTAMP,
        INDEX_TX_FUNCTION,
    ])
    .await?;
    txn.commit().await?;
    Ok(())
}
