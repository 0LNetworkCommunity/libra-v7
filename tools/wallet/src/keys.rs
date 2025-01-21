//! Generate keys for V7 forward with vendor specific keygen

// In libra we have a very specific key generation process that is not compatible with BIP-44. It's a similar HKDF. Any wallet will need to implement
// our key gen process, which is quite simple if you are already using BIP-44.
// Different from vendor, we prioritize making the mnemonic seed known to all users, and then derive all possible keys from there. Currently this applies to ed25519 keys. Vendor's keygen also includes BLS keys, which are used specifically for consensus. As such those are not relevant to end-user account holders.

use crate::{
    account_keys::{
        get_keys_from_mnem, get_keys_from_prompt, get_ol_legacy_address, legacy_keygen, KeyChain,
    },
    utils::{
        check_if_file_exists, create_dir_if_not_exist, dir_default_to_current, prompt_yes, to_yaml,
        write_to_user_only_file,
    },
};

use serde::Serialize;

use anyhow::anyhow;
use diem_config::{config::IdentityBlob, keys::ConfigKey};
use diem_crypto::{bls12381, ed25519::Ed25519PrivateKey, traits::PrivateKey, x25519};
use diem_genesis::keys::{PrivateIdentity, PublicIdentity};
use std::path::{Path, PathBuf};

// These are consistent with Vendor
const PRIVATE_KEYS_FILE: &str = "private-keys.yaml";
pub const PUBLIC_KEYS_FILE: &str = "public-keys.yaml";
pub const VALIDATOR_FILE: &str = "validator-identity.yaml";
const VFN_FILE: &str = "validator-full-node-identity.yaml";
// This is Libra specific
const USER_FILE: &str = "danger-user-private-keys.yaml";

// Generate new keys for user
pub fn user_keygen(output_opt: Option<PathBuf>) -> anyhow::Result<()> {
    let user_keys = legacy_keygen(true)?;

    if let Some(dir) = output_opt {
        if prompt_yes("Saving keys locally is VERY DANGEROUS, do you know what you are doing?") {
            write_key_file(&dir, USER_FILE, user_keys)?;
        }
    }
    Ok(())
}

// NOTE: Devs: this is copied from diem_genesis::keys::generate_key_objects()  and modified to use our legacy keygen process.
pub fn validator_keygen(
    output_opt: Option<PathBuf>,
) -> anyhow::Result<(IdentityBlob, IdentityBlob, PrivateIdentity, PublicIdentity)> {
    // this is the only moment the validators will see the mnemonic
    let legacy_keys = legacy_keygen(true)?;

    let (validator_blob, vfn_blob, private_identity, public_identity) =
        generate_key_objects_from_legacy(&legacy_keys)?;

    save_val_files(
        output_opt,
        &validator_blob,
        &vfn_blob,
        &private_identity,
        &public_identity,
    )?;

    Ok((validator_blob, vfn_blob, private_identity, public_identity))
}

/// A user with their mnemonic may want to refresh and overwrite files.
pub fn refresh_validator_files(
    mnem: Option<String>,
    output_opt: Option<PathBuf>,
    keep_legacy_addr: bool,
) -> anyhow::Result<(
    IdentityBlob,
    IdentityBlob,
    PrivateIdentity,
    PublicIdentity,
    KeyChain,
)> {
    let (validator_blob, vfn_blob, private_identity, public_identity, legacy_keys) =
        make_validator_keys(mnem, keep_legacy_addr)?;

    save_val_files(
        output_opt,
        &validator_blob,
        &vfn_blob,
        &private_identity,
        &public_identity,
    )?;

    Ok((
        validator_blob,
        vfn_blob,
        private_identity,
        public_identity,
        legacy_keys,
    ))
}

/// create all the validator key structs from mnemonic
pub fn make_validator_keys(
    mnem: Option<String>,
    keep_legacy_addr: bool,
) -> anyhow::Result<(
    IdentityBlob,
    IdentityBlob,
    PrivateIdentity,
    PublicIdentity,
    KeyChain,
)> {
    let mut legacy_keys = if let Some(m) = mnem {
        get_keys_from_mnem(m)?
    } else {
        get_keys_from_prompt()?
    };

    if keep_legacy_addr {
        let legacy_format = get_ol_legacy_address(legacy_keys.child_0_owner.account)?;
        legacy_keys.child_0_owner.account = legacy_format;
    }

    let (validator_blob, vfn_blob, private_identity, public_identity) =
        generate_key_objects_from_legacy(&legacy_keys)?;

    Ok((
        validator_blob,
        vfn_blob,
        private_identity,
        public_identity,
        legacy_keys,
    ))
}

fn write_key_file<T: Serialize>(output_dir: &Path, filename: &str, data: T) -> anyhow::Result<()> {
    let file = output_dir.join(filename);
    check_if_file_exists(file.as_path())?;
    write_to_user_only_file(
        file.as_path(),
        PRIVATE_KEYS_FILE,
        to_yaml(&data)?.as_bytes(),
    )?;
    Ok(())
}

fn save_val_files(
    output_opt: Option<PathBuf>,
    validator_blob: &IdentityBlob,
    vfn_blob: &IdentityBlob,
    private_identity: &PrivateIdentity,
    public_identity: &PublicIdentity,
) -> anyhow::Result<()> {
    let output_dir = dir_default_to_current(&output_opt)?;
    create_dir_if_not_exist(output_dir.as_path())?;

    write_key_file(&output_dir, PRIVATE_KEYS_FILE, private_identity)?;
    write_key_file(&output_dir, PUBLIC_KEYS_FILE, public_identity)?;
    write_key_file(&output_dir, VALIDATOR_FILE, validator_blob)?;
    write_key_file(&output_dir, VFN_FILE, vfn_blob)?;

    Ok(())
}

/// Generates objects used for a user in genesis
pub fn generate_key_objects_from_legacy(
    legacy_keys: &KeyChain,
) -> anyhow::Result<(IdentityBlob, IdentityBlob, PrivateIdentity, PublicIdentity)> {
    let account_key: ConfigKey<Ed25519PrivateKey> =
        ConfigKey::new(legacy_keys.child_0_owner.pri_key.to_owned());

    // consensus key needs to be generated anew as it is not part of the legacy keys
    let consensus_key = ConfigKey::new(bls_generate_key(&legacy_keys.seed)?);

    let vnk = network_keys_x25519_from_ed25519(legacy_keys.child_2_val_network.pri_key.to_owned())?;
    let validator_network_key = ConfigKey::new(vnk);

    let fnk =
        network_keys_x25519_from_ed25519(legacy_keys.child_3_fullnode_network.pri_key.to_owned())?;

    let full_node_network_key = ConfigKey::new(fnk);

    let account_address = legacy_keys.child_0_owner.account; // don't use the derived account. Since legacy account addresses will no longer map to the legacy authkey derived address.

    // Build these for use later as node identity
    let validator_blob = IdentityBlob {
        account_address: Some(account_address),
        account_private_key: Some(account_key.private_key()),
        consensus_private_key: Some(consensus_key.private_key()),
        network_private_key: validator_network_key.private_key(),
    };
    let vfn_blob = IdentityBlob {
        // the VFN needs a different address than the validator
        // otherwise it will think it is dialing itself, and
        // will show a "self dial" error on the validator logs
        account_address: Some(full_node_network_key.public_key().to_string().parse()?),
        account_private_key: None,
        consensus_private_key: None,
        network_private_key: full_node_network_key.private_key(),
    };

    let private_identity = PrivateIdentity {
        account_address,
        account_private_key: account_key.private_key(),
        consensus_private_key: consensus_key.private_key(),
        full_node_network_private_key: full_node_network_key.private_key(),
        validator_network_private_key: validator_network_key.private_key(),
    };

    let public_identity = PublicIdentity {
        account_address,
        account_public_key: account_key.public_key(),
        consensus_public_key: Some(private_identity.consensus_private_key.public_key()),
        consensus_proof_of_possession: Some(bls12381::ProofOfPossession::create(
            &private_identity.consensus_private_key,
        )),
        full_node_network_public_key: Some(full_node_network_key.public_key()),
        validator_network_public_key: Some(validator_network_key.public_key()),
    };

    // todo!("legacy keys");
    Ok((validator_blob, vfn_blob, private_identity, public_identity))
}

/// Testing deterministic hkdf for bls
fn bls_generate_key(ikm: &[u8]) -> anyhow::Result<bls12381::PrivateKey> {
    let priv_key = blst::min_pk::SecretKey::key_gen(ikm, &[])
        .map_err(|e| anyhow!("blst key gen failed: {:?}", e))?;

    let serialized: &[u8] = &priv_key.to_bytes();

    Ok(bls12381::PrivateKey::try_from(serialized)?)
    // .map_err(|e| anyhow!("bls private key from bytes failed: {:?}", e))
}

/// get a network key in x25519 format from a ed25519 key
pub fn network_keys_x25519_from_ed25519(
    pri_key: Ed25519PrivateKey,
) -> anyhow::Result<x25519::PrivateKey> {
    let pri_key_bytes = pri_key.to_bytes();
    let key = x25519::PrivateKey::from_ed25519_private_bytes(&pri_key_bytes)?;
    Ok(key)
}

#[test]
// checks we can get deterministic bls keys from the seed from mnemonic.
fn deterministic_bls_from_seed() {
    use crate::{account_keys::get_keys_from_mnem, load_keys::get_account_from_mnem};
    use diem_crypto::ValidCryptoMaterialStringExt;

    let alice_mnem = "talent sunset lizard pill fame nuclear spy noodle basket okay critic grow sleep legend hurry pitch blanket clerk impose rough degree sock insane purse";
    let (_auth_key, _account, wallet) = get_account_from_mnem(alice_mnem.to_owned()).unwrap();

    let seed = wallet.get_key_factory().main();
    let l = get_keys_from_mnem(alice_mnem.to_string()).unwrap();
    assert_eq!(seed, l.seed);

    let prk1 = bls_generate_key(seed).unwrap();
    let prk2 = bls_generate_key(seed).unwrap();
    let prk3 = bls_generate_key(seed).unwrap();
    assert_eq!(
        prk1.to_encoded_string().unwrap(),
        prk2.to_encoded_string().unwrap()
    );
    assert_eq!(
        prk2.to_encoded_string().unwrap(),
        prk3.to_encoded_string().unwrap()
    );
}
