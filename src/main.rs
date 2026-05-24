use std::{
  collections::HashMap,
  process::ExitCode,
};

use anyhow::Result;
use clap::Parser;

mod branches;
mod github;

use branches::BranchPlan;
use github::{
  BranchReachability,
  BranchReachabilityRequest,
  BranchReachabilityStatus,
  GhCliStatus,
  GitHubAuth,
  GitHubClient,
  PullRequest,
  PullRequestState,
};

const RESET: &str = "\x1b[0m";
const BOLD: &str = "\x1b[1m";
const DIM: &str = "\x1b[2m";
const RED: &str = "\x1b[31m";
const GREEN: &str = "\x1b[32m";
const YELLOW: &str = "\x1b[33m";
const BLUE: &str = "\x1b[34m";
const CYAN: &str = "\x1b[36m";
const BRIGHT_GREEN: &str = "\x1b[92m";

#[derive(Debug, Parser)]
#[command(
  name = "npr",
  about = "Search for recent NixOS PRs affecting a package and show which \
           branches they've reached."
)]
struct Options {
  /// Search PRs from last n days.
  #[arg(short, long, default_value_t = 15, value_parser = clap::value_parser!(u32).range(1..))]
  days: u32,

  /// Package name to search for.
  package_name: String,
}

fn main() -> ExitCode {
  match run() {
    Ok(()) => ExitCode::SUCCESS,
    Err(err) => {
      eprintln!("Error: {err:#}");
      ExitCode::FAILURE
    },
  }
}

fn run() -> Result<()> {
  let options = Options::parse();
  let client = GitHubClient::new(select_github_auth()?)?;

  println!("Searching for {}...", options.package_name);

  let prs =
    client.search_prs_by_changed_files(&options.package_name, options.days)?;
  if prs.is_empty() {
    eprintln!(
      "No PRs found for '{}' in the last {} days.",
      options.package_name, options.days
    );
    return Ok(());
  }

  let plans = prs
    .iter()
    .map(|pr| BranchPlan::from_base_branch(&pr.base_branch))
    .collect::<Vec<_>>();
  let reachability_by_pr = probe_reachability_by_pr(&client, &prs, &plans);

  for ((pr, plan), reachability) in
    prs.iter().zip(&plans).zip(&reachability_by_pr)
  {
    println!(
      "{}",
      render_simple_output(pr, reachability, plan.summary_targets())
    );
  }

  Ok(())
}

fn select_github_auth() -> Result<GitHubAuth> {
  match github::gh_cli_status() {
    GhCliStatus::Available => Ok(GitHubAuth::GhCli),
    GhCliStatus::Unavailable => {
      Ok(GitHubAuth::Token(github::load_token_after_unavailable_gh()?))
    },
    GhCliStatus::Unauthenticated => {
      Ok(GitHubAuth::Token(
        github::load_token_after_unauthenticated_gh()?,
      ))
    },
  }
}

fn probe_reachability_by_pr(
  client: &GitHubClient,
  prs: &[PullRequest],
  plans: &[BranchPlan],
) -> Vec<Vec<BranchReachability>> {
  let mut pr_indexes = Vec::new();
  let mut requests = Vec::new();

  for (pr_index, (pr, plan)) in prs.iter().zip(plans).enumerate() {
    if let Some(sha) = pr.state.merge_commit_sha() {
      for branch in plan.probe_targets() {
        pr_indexes.push(pr_index);
        requests.push(BranchReachabilityRequest {
          branch:     branch.clone(),
          commit_sha: sha.to_string(),
        });
      }
    }
  }

  let mut reachability_by_pr = vec![Vec::new(); prs.len()];
  for (pr_index, reachability) in pr_indexes
    .into_iter()
    .zip(client.probe_branch_reachability(&requests))
  {
    reachability_by_pr[pr_index].push(reachability);
  }

  reachability_by_pr
}

fn render_simple_output(
  pr: &PullRequest,
  reachability: &[BranchReachability],
  summary_targets: &[String],
) -> String {
  let pr_number = linked_pr_number(pr);
  let mut lines = vec![format!(
    "{BOLD}PR:{RESET} {CYAN}{}{RESET} ({status}) {DIM}{pr_number}{RESET}",
    pr.title,
    status = colored_status(&pr.state),
  )];

  if pr.state.merge_commit_sha().is_some() {
    lines.push(render_reachable_branches(reachability, summary_targets));
  }

  lines.join("\n")
}

fn colored_status(state: &PullRequestState) -> String {
  match state {
    PullRequestState::Open => format!("{BLUE}open{RESET}"),
    PullRequestState::Closed => format!("{RED}closed{RESET}"),
    PullRequestState::Merged { .. } => format!("{GREEN}merged{RESET}"),
  }
}

fn render_reachable_branches(
  reachability: &[BranchReachability],
  summary_targets: &[String],
) -> String {
  let reachability_by_branch = reachability
    .iter()
    .map(|branch| (branch.branch.as_str(), branch))
    .collect::<HashMap<_, _>>();
  let summary_reachability = summary_targets
    .iter()
    .filter_map(|branch| reachability_by_branch.get(branch.as_str()).copied())
    .collect::<Vec<_>>();

  let reached = summary_reachability
    .iter()
    .filter(|branch| branch.status == BranchReachabilityStatus::Contains)
    .map(|branch| branch.branch.as_str())
    .collect::<Vec<_>>();
  let unknown = summary_reachability
    .iter()
    .filter(|branch| {
      matches!(branch.status, BranchReachabilityStatus::Unknown(_))
    })
    .collect::<Vec<_>>();

  let mut lines = Vec::new();

  if reached.is_empty() && !unknown.is_empty() {
    lines.push(format!(
      "   {DIM}└─{RESET} Reachable in: {YELLOW}Unknown{RESET}"
    ));
  } else if reached.is_empty() {
    lines.push(format!(
      "   {DIM}└─{RESET} Reachable in: {YELLOW}None{RESET} {DIM}(pending \
       Hydra/Mirror){RESET}"
    ));
  } else {
    let separator = format!("{DIM},{RESET} ");
    let branches = reached
      .iter()
      .map(|branch| format!("{BRIGHT_GREEN}{branch}{RESET}"))
      .collect::<Vec<_>>()
      .join(&separator);

    lines.push(format!("   {DIM}└─{RESET} Reachable in: {branches}"));
  }

  if !unknown.is_empty() {
    let separator = format!("{DIM},{RESET} ");
    let branches = unknown
      .iter()
      .map(|branch| format_unknown_check(branch))
      .collect::<Vec<_>>()
      .join(&separator);

    lines.push(format!("   {DIM}└─{RESET} Unknown checks: {branches}"));
  }

  lines.join("\n")
}

fn format_unknown_check(branch: &BranchReachability) -> String {
  let error = match &branch.status {
    BranchReachabilityStatus::Unknown(error) => error,
    BranchReachabilityStatus::Contains | BranchReachabilityStatus::Missing => {
      return format!("{YELLOW}{}{RESET}", branch.branch);
    },
  };
  let error = error.lines().next().unwrap_or("unknown error");
  let mut chars = error.chars();
  let truncated = chars.by_ref().take(96).collect::<String>();
  let error = if chars.next().is_some() {
    format!("{truncated}...")
  } else {
    truncated
  };

  format!("{YELLOW}{}{RESET} {DIM}({error}){RESET}", branch.branch)
}

fn linked_pr_number(pr: &PullRequest) -> String {
  format!("\x1b]8;;{}\x1b\\#{}\x1b]8;;\x1b\\", pr.url(), pr.number)
}

#[cfg(test)]
mod tests {
  use super::*;

  fn pr(state: PullRequestState) -> PullRequest {
    PullRequest {
      number: 42,
      title: "package: 1.0 -> 1.1".to_string(),
      state,
      base_branch: "master".to_string(),
    }
  }

  fn merged_pr() -> PullRequest {
    pr(PullRequestState::Merged {
      merge_commit_sha: "abc123".to_string(),
    })
  }

  fn reachability(
    branch: &str,
    status: BranchReachabilityStatus,
  ) -> BranchReachability {
    BranchReachability {
      branch: branch.to_string(),
      status,
    }
  }

  fn targets(branches: &[&str]) -> Vec<String> {
    branches
      .iter()
      .map(|branch| (*branch).to_string())
      .collect()
  }

  #[test]
  fn renders_simple_merged_output_with_reachable_branches() {
    let output = render_simple_output(
      &merged_pr(),
      &[
        reachability("master", BranchReachabilityStatus::Missing),
        reachability("nixpkgs-unstable", BranchReachabilityStatus::Contains),
        reachability(
          "nixos-unstable-small",
          BranchReachabilityStatus::Contains,
        ),
        reachability("nixos-unstable", BranchReachabilityStatus::Missing),
      ],
      &targets(&["nixpkgs-unstable", "nixos-unstable-small", "nixos-unstable"]),
    );

    assert!(output.contains("PR:"));
    assert!(output.contains("package: 1.0 -> 1.1"));
    assert!(output.contains("merged"));
    assert!(output.contains("#42"));
    assert!(output.contains("https://github.com/NixOS/nixpkgs/pull/42"));
    assert!(output.contains("nixpkgs-unstable"));
    assert!(output.contains("nixos-unstable-small"));
  }

  #[test]
  fn renders_unknown_checks_instead_of_hiding_them_as_missing() {
    let output = render_simple_output(
      &merged_pr(),
      &[reachability(
        "nixpkgs-unstable",
        BranchReachabilityStatus::Unknown("rate limited".to_string()),
      )],
      &targets(&["nixpkgs-unstable"]),
    );

    assert!(output.contains("Reachable in:"));
    assert!(output.contains("Unknown"));
    assert!(output.contains("Unknown checks:"));
    assert!(output.contains("nixpkgs-unstable"));
    assert!(!output.contains("pending Hydra/Mirror"));
  }
}
