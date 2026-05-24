use std::{
  env,
  process::{
    Command,
    Stdio,
  },
};

use anyhow::{
  Context,
  Result,
  bail,
};
use reqwest::blocking::Client;

use super::GitHubAuth;

const API_BASE: &str = "https://api.github.com";

pub enum Transport {
  Gh(GhTransport),
  Native(NativeTransport),
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum GhCliStatus {
  Available,
  Unavailable,
  Unauthenticated,
}

impl Transport {
  pub(super) fn new(auth: GitHubAuth) -> Result<Self> {
    match auth {
      GitHubAuth::GhCli => Ok(Self::Gh(GhTransport)),
      GitHubAuth::Token(token) => {
        Ok(Self::Native(NativeTransport::new(token)?))
      },
    }
  }

  pub(super) fn make_request(&self, endpoint: &str) -> Result<String> {
    match self {
      Self::Gh(_) => GhTransport::make_request(endpoint),
      Self::Native(transport) => transport.make_request(endpoint),
    }
  }
}

pub struct GhTransport;

pub struct NativeTransport {
  client: Client,
  token:  String,
}

pub(super) fn gh_cli_status() -> GhCliStatus {
  if !GhTransport::is_installed() {
    GhCliStatus::Unavailable
  } else if GhTransport::is_authenticated() {
    GhCliStatus::Available
  } else {
    GhCliStatus::Unauthenticated
  }
}

impl GhTransport {
  fn is_installed() -> bool {
    command_succeeds(&["--version"])
  }

  fn is_authenticated() -> bool {
    command_succeeds(&["auth", "status"])
  }

  fn make_request(endpoint: &str) -> Result<String> {
    let mut command = gh_command();
    command.args([
      "api",
      "-H",
      "Accept: application/vnd.github+json",
      "-H",
      "X-GitHub-Api-Version: 2022-11-28",
    ]);
    command.arg(endpoint);

    let output = command.output().context("failed to run gh api")?;
    if !output.status.success() {
      bail!(
        "GitHub CLI request failed: {}",
        String::from_utf8_lossy(&output.stderr).trim()
      );
    }

    String::from_utf8(output.stdout).context("gh api returned non-UTF-8 output")
  }
}

impl NativeTransport {
  fn new(token: String) -> Result<Self> {
    let client = Client::builder()
      .user_agent(format!("npr/{}", env!("CARGO_PKG_VERSION")))
      .build()
      .context("failed to create GitHub HTTP client")?;

    Ok(Self { client, token })
  }

  fn make_request(&self, endpoint: &str) -> Result<String> {
    let url = format!("{API_BASE}{endpoint}");
    let response = self
      .client
      .get(&url)
      .bearer_auth(&self.token)
      .header("Accept", "application/vnd.github+json")
      .header("X-GitHub-Api-Version", "2022-11-28")
      .send()
      .with_context(|| {
        format!("failed to send GitHub API request to {endpoint}")
      })?;

    let status = response.status();
    let body = response.text().with_context(|| {
      format!("failed to read GitHub API response from {endpoint}")
    })?;

    if !status.is_success() {
      bail!("GitHub API request failed ({status}): {body}");
    }

    Ok(body)
  }
}

fn command_succeeds(args: &[&str]) -> bool {
  let mut command = gh_command();
  command.args(args);
  command.stdout(Stdio::null());
  command.stderr(Stdio::null());
  command.status().is_ok_and(|status| status.success())
}

fn gh_command() -> Command {
  let mut command = Command::new("gh");
  command.env_remove("GH_FORCE_TTY");
  command.env_remove("FORCE_COLOR");
  command.env("NO_COLOR", "1");
  command.env("CLICOLOR", "0");
  command.env("CLICOLOR_FORCE", "0");
  command.env("GH_NO_UPDATE_NOTIFIER", "1");
  command.env("GH_PAGER", "cat");
  command
}
