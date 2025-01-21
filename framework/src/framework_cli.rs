//! framework cli entry points

use crate::{
    builder::framework_generate_upgrade_proposal::{
        init_move_dir_wrapper, libra_compile_script, make_framework_upgrade_artifacts, save_build,
    },
    release::ReleaseTarget,
};

use anyhow::Context;
use clap::Parser;
use std::path::{Path, PathBuf};

#[derive(Parser)]
#[clap(name = "libra-framework", author, version, propagate_version = true)]
/// Libra framework compiler.
pub enum FrameworkCli {
    /// Creates a .mrb move framework release
    Release(GenesisRelease),
    /// Creates the script payload for a governance script
    Governance(GovernanceScript),
    /// Creates all artifacts for a network governance upgrade
    Upgrade(FrameworkUpgrade),
}

impl FrameworkCli {
    pub fn execute(&self) -> anyhow::Result<()> {
        match self {
            FrameworkCli::Release(tool) => tool.execute(),
            FrameworkCli::Governance(tool) => tool.execute(),
            FrameworkCli::Upgrade(tool) => tool.execute(),
        }
    }
}

#[derive(Debug, Parser)]
/// Creates a framework release used for test genesis (as well as production genesis).
pub struct GenesisRelease {
    /// The release target. One of head, devnet, testnet, or mainnet. Notice the type
    /// of target determines what packages are included in the release. For example,
    /// some packages may be available in testnet, but aren't in mainnet.
    #[clap(long, default_value = "head")]
    pub target: ReleaseTarget,

    /// Default is to create a bloated dev compile, with options: dev, sources, with_source_maps, etc.
    /// set -p to create a "skinny" version to publish on chain.
    #[clap(short, long)]
    pub production: bool,
}

impl GenesisRelease {
    pub fn execute(&self) -> anyhow::Result<()> {
        self.target.create_release(!self.production, None)
    }
}

/// Creates all artifacts for a framework governance upgrade.
/// This is for all or any code deployed at the system 0x1 address.
#[derive(Debug, Parser)]
pub struct FrameworkUpgrade {
    /// dir to save all the artifacts for the release.
    #[clap(short, long)]
    pub output_dir: PathBuf,

    /// directory of the framework source code. Usually `./framework/lbra-framework`
    #[clap(short, long)]
    pub framework_local_dir: PathBuf,

    /// optional, list of core module directory names to compile. It will default to this order: move-stdlib, vendor-stdlib, libra-framework
    #[clap(long)]
    pub core_modules: Option<Vec<String>>,

    /// optional, DANGER: force the upgrade, and ignore all compatibility checks
    /// I hope to god you know what you are doing.
    #[clap(long)]
    pub danger_force_upgrade: bool,
}

impl FrameworkUpgrade {
    pub fn execute(&self) -> anyhow::Result<()> {
        // let release_cfg = libra_release_cfg_default();
        if !self.output_dir.exists() {
            println!(
                "creating output dir at {}",
                self.output_dir.to_str().unwrap()
            );
            std::fs::create_dir_all(&self.output_dir)?;
        }

        make_framework_upgrade_artifacts(
            &self.output_dir,
            &self.framework_local_dir,
            &self.core_modules,
            self.danger_force_upgrade,
        )?;

        Ok(())
    }
}

/// Builds artifacts for any governance proposal that requires human written scripts.
/// Also creates a template for a libra governance script
#[derive(Debug, Parser)]
pub struct GovernanceScript {
    /// dir to save all the artifacts for the release.
    #[clap(short, long)]
    pub script_dir: PathBuf,

    /// directory of the framework source code. Usually `./framework/lbra-framework`
    #[clap(short, long)]
    pub framework_local_dir: PathBuf,

    #[clap(long)]
    /// option to only make a template governance script
    pub only_make_template: bool,
}

impl GovernanceScript {
    pub fn execute(&self) -> anyhow::Result<()> {
        // TODO: glob search for a .move file
        if !&self.script_dir.exists() || self.only_make_template {
            if !self.only_make_template {
                println!("ERROR: nothing to compile.")
            }
            println!("A governance script dir does not exist here.");
            if dialoguer::Confirm::new()
                .with_prompt(format!(
                    "create a script template at {:?}",
                    &self.script_dir.display()
                ))
                .interact()?
            {
                let script_name = "governance_script_template";
                let package_dir = self.script_dir.join(script_name);
                make_template_files(&package_dir, &self.framework_local_dir, script_name, None)?;
            }
            return Ok(());
        }

        let (bytes, hash) = libra_compile_script(&self.script_dir, false)?;
        save_build(self.script_dir.to_owned(), &bytes, &hash)?;

        Ok(())
    }
}

/// make governance script template package
pub fn make_template_files(
    package_dir: &Path,
    framework_local_dir: &Path,
    script_name: &str,
    script_source: Option<String>,
) -> anyhow::Result<()> {
    std::fs::create_dir_all(package_dir)
        .context("could not create the output directory {new_path:?}")?;
    // TODO: rename this. init_move_package_with_local_framework
    init_move_dir_wrapper(
        package_dir.to_owned(),
        script_name,
        framework_local_dir.to_owned(),
    )?;

    let t = r#"
script {
  // THIS IS A TEMPLATE GOVERNANCE SCRIPT
  // you can generate this file with commandline tools: `libra-framework governance --output-dir --framework-local-dir`
  use diem_framework::diem_governance;
  use std::vector;

  fun main(proposal_id: u64){
      let next_hash = vector::empty();
      let _framework_signer = diem_governance::resolve_multi_step_proposal(proposal_id, @0000000000000000000000000000000000000000000000000000000000000001, next_hash);
  }
}
"#;

    let filename = package_dir
        // .join(script_name)
        .join("sources")
        .join(format!("{}.move", script_name));

    std::fs::write(filename, script_source.unwrap_or(t.to_string()))?;
    println!("success: governance template created");

    println!("\nBefore submitting the governance action you must compile the script. Simply run this command again.");

    Ok(())
}
