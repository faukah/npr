use std::thread;

use anyhow::{
  Context,
  Result,
  bail,
};
use chrono::{
  Duration,
  SecondsFormat,
  Utc,
};
use serde::{
  Deserialize,
  de::DeserializeOwned,
};

mod auth;
mod transport;

pub use transport::GhCliStatus;
use transport::Transport;

const MAX_PARALLEL_REQUESTS: usize = 8;
const PULL_REQUEST_URL_BASE: &str = "https://github.com/NixOS/nixpkgs/pull";

#[derive(Debug, Clone, Eq, PartialEq)]
pub enum PullRequestState {
  Open,
  Closed,
  Merged { merge_commit_sha: String },
}

impl PullRequestState {
  pub fn merge_commit_sha(&self) -> Option<&str> {
    match self {
      Self::Merged { merge_commit_sha } => Some(merge_commit_sha),
      Self::Open | Self::Closed => None,
    }
  }
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct PullRequest {
  pub number:      i64,
  pub title:       String,
  pub state:       PullRequestState,
  pub base_branch: String,
}

impl PullRequest {
  pub fn url(&self) -> String {
    format!("{PULL_REQUEST_URL_BASE}/{}", self.number)
  }
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct BranchReachability {
  pub branch: String,
  pub status: BranchReachabilityStatus,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct BranchReachabilityRequest {
  pub branch:     String,
  pub commit_sha: String,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub enum BranchReachabilityStatus {
  Contains,
  Missing,
  Unknown(String),
}

pub struct GitHubClient {
  transport: Transport,
}

pub enum GitHubAuth {
  GhCli,
  Token(String),
}

#[derive(Deserialize)]
struct SearchResponse {
  items: Vec<SearchItem>,
}

#[derive(Deserialize)]
struct SearchItem {
  number: i64,
}

#[derive(Deserialize)]
struct CompareResponse {
  status: String,
}

#[derive(Deserialize)]
struct PullResponse {
  number:           i64,
  title:            String,
  state:            String,
  merged:           bool,
  merge_commit_sha: Option<String>,
  base:             PullBase,
}

#[derive(Deserialize)]
struct PullBase {
  #[serde(rename = "ref")]
  ref_name: String,
}

pub fn gh_cli_status() -> GhCliStatus {
  transport::gh_cli_status()
}

pub fn load_token_after_unavailable_gh() -> Result<String> {
  auth::load_token(auth::TokenFallbackReason::GhUnavailable)
}

pub fn load_token_after_unauthenticated_gh() -> Result<String> {
  auth::load_token(auth::TokenFallbackReason::GhUnauthenticated)
}

impl GitHubClient {
  pub fn new(auth: GitHubAuth) -> Result<Self> {
    Ok(Self {
      transport: Transport::new(auth)?,
    })
  }

  pub fn search_prs_by_changed_files(
    &self,
    package_name: &str,
    days: u32,
  ) -> Result<Vec<PullRequest>> {
    let date = (Utc::now() - Duration::days(i64::from(days)))
      .to_rfc3339_opts(SecondsFormat::Secs, true);
    let query =
      format!("repo:NixOS/nixpkgs {package_name} type:pr created:>{date}");
    let endpoint = format!(
      "/search/issues?q={}&per_page=100&sort=created&order=desc",
      url_encode(&query)
    );

    let response: SearchResponse = self.get_json(&endpoint)?;
    let numbers = response
      .items
      .into_iter()
      .map(|item| item.number)
      .collect::<Vec<_>>();

    self.get_pr_details_parallel(&numbers)
  }

  pub fn probe_branch_reachability(
    &self,
    requests: &[BranchReachabilityRequest],
  ) -> Vec<BranchReachability> {
    bounded_parallel_map(requests, |request| {
      let status = match self
        .check_commit_in_branch(&request.commit_sha, &request.branch)
      {
        Ok(true) => BranchReachabilityStatus::Contains,
        Ok(false) => BranchReachabilityStatus::Missing,
        Err(err) => BranchReachabilityStatus::Unknown(err.to_string()),
      };

      BranchReachability {
        branch: request.branch.clone(),
        status,
      }
    })
  }

  fn get_pr_details_parallel(
    &self,
    numbers: &[i64],
  ) -> Result<Vec<PullRequest>> {
    bounded_parallel_map(numbers, |number| self.get_pr_details(*number))
      .into_iter()
      .collect()
  }

  fn check_commit_in_branch(
    &self,
    commit_sha: &str,
    branch: &str,
  ) -> Result<bool> {
    let endpoint =
      format!("/repos/NixOS/nixpkgs/compare/{commit_sha}...{branch}");
    let response: CompareResponse = self.get_json(&endpoint)?;

    Ok(response.status == "ahead" || response.status == "identical")
  }

  fn get_pr_details(&self, pr_number: i64) -> Result<PullRequest> {
    let endpoint = format!("/repos/NixOS/nixpkgs/pulls/{pr_number}");
    let pr: PullResponse = self.get_json(&endpoint)?;
    let state = pull_request_state(&pr)
      .with_context(|| format!("invalid GitHub PR payload for #{pr_number}"))?;

    Ok(PullRequest {
      number: pr.number,
      title: pr.title,
      state,
      base_branch: pr.base.ref_name,
    })
  }

  fn get_json<T>(&self, endpoint: &str) -> Result<T>
  where
    T: DeserializeOwned,
  {
    let body = self.transport.make_request(endpoint)?;
    serde_json::from_str(&body).with_context(|| {
      format!("failed to parse GitHub response from {endpoint}")
    })
  }
}

fn pull_request_state(pr: &PullResponse) -> Result<PullRequestState> {
  if pr.merged {
    let merge_commit_sha = pr
      .merge_commit_sha
      .clone()
      .context("merged PR has no merge_commit_sha")?;

    return Ok(PullRequestState::Merged { merge_commit_sha });
  }

  if pr.state == "open" {
    Ok(PullRequestState::Open)
  } else if pr.state == "closed" {
    Ok(PullRequestState::Closed)
  } else {
    bail!("unknown PR state {}", pr.state)
  }
}

fn url_encode(input: &str) -> String {
  const HEX: &[u8; 16] = b"0123456789ABCDEF";
  let mut encoded = String::with_capacity(input.len());

  for byte in input.bytes() {
    if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'~')
    {
      encoded.push(char::from(byte));
    } else if byte == b' ' {
      encoded.push('+');
    } else {
      encoded.push('%');
      encoded.push(char::from(HEX[(byte >> 4) as usize]));
      encoded.push(char::from(HEX[(byte & 0x0F) as usize]));
    }
  }

  encoded
}

fn bounded_parallel_map<T, R, F>(items: &[T], f: F) -> Vec<R>
where
  T: Sync,
  R: Send,
  F: Fn(&T) -> R + Sync,
{
  let mut results = Vec::with_capacity(items.len());
  let f = &f;

  for chunk in items.chunks(MAX_PARALLEL_REQUESTS) {
    let mut chunk_results = thread::scope(|scope| {
      let mut handles = Vec::with_capacity(chunk.len());
      for item in chunk {
        handles.push(scope.spawn(move || f(item)));
      }

      handles
        .into_iter()
        .map(|handle| {
          handle.join().unwrap_or_else(|payload| {
            std::panic::resume_unwind(payload);
          })
        })
        .collect::<Vec<_>>()
    });

    results.append(&mut chunk_results);
  }

  results
}

#[cfg(test)]
mod tests {
  use super::{
    PullBase,
    PullRequestState,
    PullResponse,
    pull_request_state,
    url_encode,
  };

  #[test]
  fn encodes_github_search_query_like_gh_endpoint() {
    assert_eq!(
      "repo%3ANixOS%2Fnixpkgs+zig+type%3Apr+created%3A%3E2026-01-01T00%3A00%\
       3A00Z",
      url_encode(
        "repo:NixOS/nixpkgs zig type:pr created:>2026-01-01T00:00:00Z"
      )
    );
  }

  #[test]
  fn merged_pr_state_requires_a_merge_commit_sha() {
    let response = pull_response(true, "closed", None);

    assert!(pull_request_state(&response).is_err());
  }

  #[test]
  fn merged_pr_state_owns_the_merge_commit_sha() {
    let response = pull_response(true, "closed", Some("abc123"));

    assert_eq!(
      Some(PullRequestState::Merged {
        merge_commit_sha: "abc123".to_string(),
      }),
      pull_request_state(&response).ok()
    );
  }

  fn pull_response(
    merged: bool,
    state: &str,
    merge_commit_sha: Option<&str>,
  ) -> PullResponse {
    PullResponse {
      number: 1,
      title: "title".to_string(),
      state: state.to_string(),
      merged,
      merge_commit_sha: merge_commit_sha.map(str::to_string),
      base: PullBase {
        ref_name: "master".to_string(),
      },
    }
  }
}
