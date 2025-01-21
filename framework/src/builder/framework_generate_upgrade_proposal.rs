//! generate framework upgrade proposal scripts
//! see vendor diem-move/framework/src/release_bundle.rs

use crate::{builder::framework_release_bundle::libra_author_script_file, BYTECODE_VERSION};
use anyhow::{ensure, Context, Result};
use diem_crypto::HashValue;
use diem_framework::{BuildOptions, BuiltPackage, ReleasePackage};
use diem_types::account_address::AccountAddress;
use std::path::{Path, PathBuf};

/// Core modules address to deploy to
// NOTE: we are always usin 0x1 here. So if that ever changes in the future then this can't be hard coded.
const CORE_MODULE_ADDRESS: &str = "0x1";

// we need to collect a list of the core modules and their paths
// when an upgrade transaction is formed we need to do them in
// a sequence.

fn default_core_modules() -> Vec<String> {
    vec![
        "move-stdlib".to_string(),
        "vendor-stdlib".to_string(),
        "libra-framework".to_string(),
    ]
}

pub fn make_framework_upgrade_artifacts(
    proposal_move_package_dir: &Path,
    framework_local_dir: &Path,
    core_modules: &Option<Vec<String>>,
    force_incompatible_upgrade: bool,
) -> Result<Vec<(String, String)>> {
    let framework_git_hash =
        &get_framework_git_head(framework_local_dir).unwrap_or("none".to_owned());

    let deploy_to_account = AccountAddress::from_hex_literal(CORE_MODULE_ADDRESS)?;

    let mut next_execution_hash = vec![];

    let mut core_modules = core_modules.to_owned().unwrap_or_else(default_core_modules);

    // TODO: we are not using these formatted files now that we are saving them directly
    let mut formatted_scripts: Vec<(String, String)> = vec![];

    // For generating multi-step proposal files, we need to generate them in the reverse order since
    // we need the hash of the next script.
    // We will reverse the order back when writing the files into a directory.
    core_modules.reverse();

    let len = core_modules.len();
    for (idx, core_module_name) in core_modules.iter().enumerate() {
        let deploy_order = len - idx; // we are compiling the last module to deploy first. This is because we need to know it's hash, ahead of the earlier modules. That is LibraFramework will compile first, although it will be 3rd to deploy. We need its execution hash known when we deploy the 2nd package: VendorStdlib, which needs that has IN THE GOVERNANCE SCRIPT.

        // the core module we are upgrading e.g. LibraFramework
        let mut core_module_dir = framework_local_dir.to_owned().canonicalize()?;
        core_module_dir.push(core_module_name);

        // We first need to compile and build each CORE MODULE we are upgrading (e.g. MoveStdlib, LibraFramework)

        let options = BuildOptions {
            with_srcs: false, // this will store the source bytes on chain, as in genesis
            with_abis: false,
            with_source_maps: false,
            with_error_map: true,
            skip_fetch_latest_git_deps: true,
            bytecode_version: Some(BYTECODE_VERSION),
            ..BuildOptions::default()
        };

        ensure!(
            core_module_dir.exists(),
            "package path does not exist at {}",
            core_module_dir.to_str().unwrap()
        );

        let compiled_core_module_pack = BuiltPackage::build(core_module_dir.clone(), options)?;
        let mut release = ReleasePackage::new(compiled_core_module_pack)?;

        // DANGER: if 0x1 needs to force an incompatible upgrade
        if force_incompatible_upgrade {
            release.metadata.upgrade_policy.policy = 0;
        }

        // Each GOVERNANCE SCRIPT needs its own Move module directory even if temporarily, to compile the code for later submission (and getting the transaction hash, more below).

        let ordered_display_name = format!("{}-{}", &deploy_order.to_string(), core_module_name);
        let temp_gov_module = proposal_move_package_dir.join(&ordered_display_name);

        init_move_dir_wrapper(
            temp_gov_module.clone(),
            "upgrade_scripts",
            framework_local_dir
                .join("libra-framework")
                .to_path_buf()
                .clone(), // NOTE: this is the path for LibraFramework where all the governance *.move contracts exist.
        )?;

        // give the transaction script a name
        let mut this_mod_gov_script_path =
            temp_gov_module.join("sources").join(&ordered_display_name);
        this_mod_gov_script_path.set_extension("move");

        // useing the bytes from the release code, we create the
        // governance transaction script. It's just a collection of vec<u8> arrays in move, which get reassembled by the code publisher on move side. It also contains authorization logic to allow the code to deploy.
        libra_author_script_file(
            &release,
            deploy_to_account,
            this_mod_gov_script_path.clone(),
            next_execution_hash,
            framework_git_hash,
        )?;

        // We need transaction execution hashes OF THE GOVERNANCE SCRIPT for the governance ceremony.
        // This means we have another compilation step but for the .move script we just created in the step above.
        // we are interested in two outputs: the actual compiled binary, which the next step will save to `script.mv` in the module upgrade proposal dir.
        // and also the `hash` of the script bytes. We use this in different places, but mainly the proposer needs to know this hash so that in the proposal step of the governance ceremony, we can list this as an authrorized script for execution if the proposal passses the vote.
        let (_, hash) = libra_compile_script(&temp_gov_module, false)?;

        next_execution_hash = hash.to_vec();

        let mut script = format!(
            "// This script source hash (used for tx authorization): {}\n",
            hash.to_hex_literal()
        );

        script.push_str(&std::fs::read_to_string(this_mod_gov_script_path)?);

        formatted_scripts.push((core_module_name.to_owned(), script));
    }

    Ok(formatted_scripts)
}

pub fn write_to_file(result: Vec<(String, String)>, proposal_dir: PathBuf) -> anyhow::Result<()> {
    println!("writing upgrade scripts to folder");

    for (idx, (script_name, script)) in result.into_iter().enumerate() {
        let mut script_path = proposal_dir.clone();
        let proposal_name = format!("{}-{}", idx, script_name);
        script_path.push(&proposal_name);
        script_path.set_extension("move");

        // let execution_hash = append_script_hash(script, script_path.clone(), framework_local_dir.clone())?;
        std::fs::write(&script_path, script.as_bytes())?;
    }
    Ok(())
}
/// Need to create a dummy package so that we can build the script into bytecode
/// so that:
/// * we can then get the hash of the script.
/// * then submit it as part of a proposal framework/libra-framework/sources/modified_source/diem_governance.move
/// * then the VM doesn't complain about its size /diem-move/diem-vm/src/diem_vm_impl.rs
/// * and so that when the proposal is approved a third party can execute the source upgrade.
pub fn init_move_dir_wrapper(
    package_dir: PathBuf,
    script_name: &str,
    framework_local_dir: PathBuf,
) -> anyhow::Result<()> {
    println!("creating package directory for .move scripts");
    diem::move_tool::init_move_dir_generic(
        &package_dir,
        script_name,
        "LibraFramework".to_string(),
        std::fs::canonicalize(framework_local_dir)?,
    )?;
    Ok(())
}

pub fn libra_compile_script(
    script_package_dir: &Path,
    _is_module: bool,
) -> Result<(Vec<u8>, HashValue)> {
    println!("compiling governance script...");
    // these are the options only for the upgrade SCRIPT
    // the payload needs to be small, because even approved TX scripts have
    // an upperbound in the transaction admission.
    let build_options = BuildOptions {
        with_srcs: false,
        with_abis: false,
        with_source_maps: false,
        with_error_map: false,
        skip_fetch_latest_git_deps: true,
        bytecode_version: Some(BYTECODE_VERSION),

        ..BuildOptions::default()
    };

    let pack = BuiltPackage::build(script_package_dir.to_path_buf(), build_options)?;

    let scripts_count = pack.script_count();

    if scripts_count != 1 {
        println!(
            "WARN: more than one script being compiled, count: {}",
            scripts_count
        );
    }

    let mut code = pack.extract_script_code();
    let bytes = code
        .pop()
        .context("could not find any code in BuiltPackage")?;

    let hash = HashValue::sha3_256_of(bytes.as_slice());

    save_build(script_package_dir.to_path_buf(), &bytes, &hash)?;

    Ok((bytes, hash))
}

pub fn save_build(
    script_package_dir: PathBuf,
    bytes: &[u8],
    hash: &HashValue,
) -> anyhow::Result<()> {
    std::fs::write(script_package_dir.join("script.mv"), bytes)?;
    std::fs::write(script_package_dir.join("script_sha3"), hash.to_hex())?;

    println!(
        "success: governance script built at: {:?}",
        script_package_dir
    );
    println!("tx script hash: {:?}", hash.to_hex_literal());
    Ok(())
}

fn get_framework_git_head(path: &Path) -> anyhow::Result<String> {
    let r = git2::Repository::discover(path).unwrap();
    let id = r.head()?.peel_to_commit()?.id();

    Ok(id.to_string())
}
