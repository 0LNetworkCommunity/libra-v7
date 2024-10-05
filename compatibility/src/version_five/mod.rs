pub mod balance_v5;
pub mod core_account_v5;
pub mod diem_account_v5;
pub mod freezing_v5;
pub mod legacy_address_v5;
pub mod state_snapshot_v5;
// NOTE: the ones below should likely be private always,
// so that they do not get suggested in the place of
// up-to-date structs of the same name.

mod account_blob_v5;
mod event_v5;
mod hash_value_v5;
mod language_storage_v5;
mod move_resource_v5;
mod safe_serialize_v5;
