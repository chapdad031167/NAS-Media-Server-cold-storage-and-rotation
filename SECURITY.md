# Security

This is a home-lab project under the MIT license, provided **as is, with no
warranty**. It moves and deletes real data — read the dry-run report before
every `--run` and keep backups of anything irreplaceable.

## Reporting a vulnerability

Please **do not** open a public issue for a security problem. Use GitHub's
**[Report a vulnerability](https://github.com/chapdad031167/NAS-Media-Server-cold-storage-and-rotation/security/advisories/new)**
(private security advisory) instead, and allow a reasonable window to address
it before any public disclosure.

## Security model

- **Dry-run by default.** Every destructive script is report-only unless
  invoked with an explicit `--run`. Scans and the doctor never modify data.
- **Kids-content hard exclusion** runs before any other rule; nothing under
  the `/kids/` or `/kidstv/` roots is ever archived.
- **Verified moves.** Cold storage uses rsync copy → checksum verify → delete
  source; a failed verify keeps the source untouched.
- **Secrets stay out of argv.** API keys are passed to helper processes via
  the environment, and webhook URLs (themselves credentials) reach curl via
  `--config` on stdin — never as command-line arguments (argv is
  world-readable through `/proc/<pid>/cmdline`; environ and stdin are not).
- **Locks live in a user-owned directory** (`.locks/` in the install), not
  world-writable `/tmp`, so another local user can't squat the lock names
  and deny your cron runs.
- **`config.env` is protected.** The installer creates it mode `600`. Because
  the scripts `source` it, they refuse to run if it is group- or
  other-writable (which would allow code injection), and `install.sh
  --doctor` warns if its permissions are loose.
- **No third-party runtime dependencies.** Python is standard-library only;
  the shell scripts use common coreutils. Smaller supply-chain surface.
- **CI secret scan.** `tests/secret_scan.sh` runs on every push/PR and fails
  the build if a real-looking API key or private IP lands in a tracked file.
- **One-tap approval is disarmed by default and token-gated.** The optional
  remote-approval flow (`approval_poll.sh`) does nothing unless
  `REMOTE_APPROVE=true` *and* both `APPROVE_URL` and `APPROVE_TOKEN` are
  configured. Execution requires a message carrying the exact secret token
  on a private ntfy topic; non-matching messages are logged and skipped, a
  message-id state file makes approvals replay-proof, at most one cycle runs
  per poll, and the triggered run keeps every cold_storage_cycle.sh guard
  (candidate staleness, size re-verify, free-space preflight, verified
  moves). Both ntfy topic URLs and the token are **credentials**: anyone
  holding them can read scan reports or attempt approvals. Pick unguessable
  topic names, generate the token randomly (`openssl rand -base64 24` — no
  commas), and rotate all three if exposed. Like the webhook URLs, they
  reach curl via `--config` on stdin, never argv.

## Your responsibilities

- Keep `config.env` at mode `600` and owned by the account that runs the
  scripts (`chmod 600 config.env`).
- Run the scripts as a **low-privilege user** that owns the media — not root.
- Ensure the archive drive's permissions are sane (the scripts can only be as
  safe as the mount they write to).
- **Rotate any API key** that may have been exposed (e.g. pasted into an
  issue). The scripts never print keys, but be careful what you share.

## Tracked hardening follow-ups

Deferred, non-blocking improvements are tracked as GitHub issues labelled
`security` / `enhancement`:

- Adopt **gitleaks** for full git-history, entropy-based secret scanning
  (the current `secret_scan.sh` is a deterministic, dependency-free safety
  net, chosen because the build environment can't fetch the gitleaks binary).
- **Archive integrity / scrub mode:** store a per-item checksum in the
  manifest at archive time and add a `--verify` pass so bit-rot on the shelf
  is detected before you rely on a restore.
- **HTTPS Radarr/Sonarr** support with proper certificate handling.
- Minor robustness: NUL-delimited candidate parsing, and passing the
  candidate-file path to embedded Python via argv rather than string
  interpolation.
