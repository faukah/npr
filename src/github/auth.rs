use std::{
  env,
  fs,
  io::{
    self,
    IsTerminal,
    Write,
  },
  os::unix::fs::{
    DirBuilderExt,
    OpenOptionsExt,
    PermissionsExt,
  },
  path::{
    Path,
    PathBuf,
  },
  process,
};

use anyhow::{
  Context,
  Result,
  bail,
};

const TOKEN_FILE_ENV: &str = "NPR_GITHUB_TOKEN_FILE";
const TOKEN_ENV_VARS: &[&str] =
  &["NPR_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"];
const TOKEN_CREATION_URL: &str =
  "https://github.com/settings/personal-access-tokens/new";

#[derive(Clone, Copy)]
pub enum TokenFallbackReason {
  GhUnavailable,
  GhUnauthenticated,
}

impl TokenFallbackReason {
  fn unavailable_error(self) -> String {
    match self {
      Self::GhUnavailable => {
        format!(
          "GitHub CLI is not available, and no GitHub token is available. Set \
           NPR_GITHUB_TOKEN, GH_TOKEN, or GITHUB_TOKEN, or run npr \
           interactively to store one. Create one at {}. The token does not \
           need any permissions; it is only used for authenticated GitHub API \
           requests.",
          token_creation_link()
        )
      },
      Self::GhUnauthenticated => {
        format!(
          "GitHub CLI is installed but not authenticated, and no GitHub token \
           is available. Run `gh auth login`, set NPR_GITHUB_TOKEN, GH_TOKEN, \
           or GITHUB_TOKEN, or run npr interactively to store one. Create one \
           at {}. The token does not need any permissions; it is only used \
           for authenticated GitHub API requests.",
          token_creation_link()
        )
      },
    }
  }

  fn token_creation_note(self) -> String {
    match self {
      Self::GhUnavailable => {
        format!(
          "GitHub CLI is not available; npr will call GitHub \
           directly.\nCreate a GitHub token at {} if you do not already have \
           one.",
          token_creation_link()
        )
      },
      Self::GhUnauthenticated => {
        format!(
          "GitHub CLI is installed but not authenticated; npr will call \
           GitHub directly.\nCreate a GitHub token at {}, or run `gh auth \
           login`.",
          token_creation_link()
        )
      },
    }
  }
}

fn token_creation_link() -> String {
  terminal_hyperlink(TOKEN_CREATION_URL, TOKEN_CREATION_URL)
}

fn terminal_hyperlink(label: &str, url: &str) -> String {
  format!("\x1b]8;;{url}\x1b\\{label}\x1b]8;;\x1b\\")
}

pub fn load_token(fallback_reason: TokenFallbackReason) -> Result<String> {
  if let Some(token) = load_env_token() {
    return Ok(token);
  }

  let path = token_file_path()?;
  if let Some(token) = read_stored_token(&path)? {
    return Ok(token);
  }

  if !io::stdin().is_terminal() {
    bail!("{}", fallback_reason.unavailable_error());
  }

  eprintln!("{}", fallback_reason.token_creation_note());
  eprintln!(
    "No token permissions are needed; npr only uses it so GitHub treats \
     requests as authenticated."
  );
  eprintln!(
    "Paste the token below. It will be saved at {} with user-only permissions.",
    path.display()
  );

  let token = prompt_token()?.trim().to_string();

  if token.is_empty() {
    bail!("empty GitHub token");
  }

  store_token(&path, &token)?;
  Ok(token)
}

fn prompt_token() -> Result<String> {
  eprint!("GitHub token: ");
  io::stderr()
    .flush()
    .context("failed to flush token prompt")?;

  let mut token = String::new();
  io::stdin()
    .read_line(&mut token)
    .context("failed to read GitHub token")?;
  Ok(token)
}

fn load_env_token() -> Option<String> {
  TOKEN_ENV_VARS.iter().find_map(|name| {
    let token = env::var(name).ok()?;
    let token = token.trim();
    (!token.is_empty()).then(|| token.to_string())
  })
}

fn token_file_path() -> Result<PathBuf> {
  if let Some(path) = env::var_os(TOKEN_FILE_ENV) {
    return Ok(PathBuf::from(path));
  }

  if let Some(config_home) = env::var_os("XDG_CONFIG_HOME") {
    return Ok(PathBuf::from(config_home).join("npr").join("github-token"));
  }

  if let Some(home) = env::var_os("HOME").or_else(|| env::var_os("USERPROFILE"))
  {
    return Ok(
      PathBuf::from(home)
        .join(".config")
        .join("npr")
        .join("github-token"),
    );
  }

  bail!(
    "could not determine token storage path; set {TOKEN_FILE_ENV} or provide \
     NPR_GITHUB_TOKEN"
  );
}

fn read_stored_token(path: &Path) -> Result<Option<String>> {
  match fs::symlink_metadata(path) {
    Ok(metadata) => ensure_token_file_is_private(path, &metadata)?,
    Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(None),
    Err(err) => {
      return Err(err)
        .with_context(|| format!("failed to inspect {}", path.display()));
    },
  }

  let token = fs::read_to_string(path).with_context(|| {
    format!("failed to read GitHub token from {}", path.display())
  })?;
  let token = token.trim();

  Ok((!token.is_empty()).then(|| token.to_string()))
}

fn store_token(path: &Path, token: &str) -> Result<()> {
  if let Some(parent) = path.parent() {
    create_token_dir(parent)?;
  }

  match fs::symlink_metadata(path) {
    Ok(metadata) if metadata.file_type().is_symlink() => {
      bail!("refusing to replace symlink {}", path.display());
    },
    Ok(_) => {},
    Err(err) if err.kind() == io::ErrorKind::NotFound => {},
    Err(err) => {
      return Err(err)
        .with_context(|| format!("failed to inspect {}", path.display()));
    },
  }

  let temp_path = write_private_temp_file(path, token)?;
  fs::rename(&temp_path, path).with_context(|| {
    let _ = fs::remove_file(&temp_path);
    format!("failed to atomically install token file {}", path.display())
  })?;

  set_user_only_file(path)?;
  eprintln!("Saved GitHub token to {}.", path.display());
  Ok(())
}

fn write_private_temp_file(path: &Path, token: &str) -> Result<PathBuf> {
  let parent = path.parent().unwrap_or_else(|| Path::new("."));
  let name = path
    .file_name()
    .and_then(|name| name.to_str())
    .unwrap_or("github-token");

  for attempt in 0..100 {
    let temp_path =
      parent.join(format!(".{name}.{}.{}.tmp", process::id(), attempt));
    let mut options = fs::OpenOptions::new();
    options.create_new(true).write(true).mode(0o600);

    let mut file = match options.open(&temp_path) {
      Ok(file) => file,
      Err(err) if err.kind() == io::ErrorKind::AlreadyExists => continue,
      Err(err) => {
        return Err(err).with_context(|| {
          format!("failed to create {}", temp_path.display())
        });
      },
    };

    if let Err(err) = writeln!(file, "{token}") {
      let _ = fs::remove_file(&temp_path);
      return Err(err).with_context(|| {
        format!("failed to write token file {}", temp_path.display())
      });
    }

    if let Err(err) = file.sync_all() {
      let _ = fs::remove_file(&temp_path);
      return Err(err).with_context(|| {
        format!("failed to sync token file {}", temp_path.display())
      });
    }

    return Ok(temp_path);
  }

  bail!(
    "failed to create a unique temporary token file for {}",
    path.display()
  );
}

fn create_token_dir(path: &Path) -> Result<()> {
  let mut builder = fs::DirBuilder::new();
  builder.recursive(true).mode(0o700);
  builder.create(path).with_context(|| {
    format!("failed to create token directory {}", path.display())
  })
}

fn ensure_token_file_is_private(
  path: &Path,
  metadata: &fs::Metadata,
) -> Result<()> {
  if metadata.file_type().is_symlink() {
    bail!("refusing to read token through symlink {}", path.display());
  }

  let mode = metadata.permissions().mode();
  if mode & 0o077 != 0 {
    bail!(
      "refusing to read {} because it is group/world accessible; run `chmod \
       600 {}`",
      path.display(),
      path.display()
    );
  }

  Ok(())
}

fn set_user_only_file(path: &Path) -> Result<()> {
  fs::set_permissions(path, fs::Permissions::from_mode(0o600)).with_context(
    || format!("failed to set private permissions on {}", path.display()),
  )
}
