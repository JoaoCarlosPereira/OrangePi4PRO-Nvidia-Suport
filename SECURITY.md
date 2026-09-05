# What is in the published image, and what was removed

The image in the releases is built from a **real working system**, not from a
clean vendor image. That makes it useful — everything is already configured — but
it also means it started out full of personal data. This page documents exactly
what was stripped, so you can judge whether to trust it, and so anyone rebuilding
an image from their own board knows what to look for.

## Removed before publication

| Removed | Why it mattered |
|---|---|
| `~/.config/google-chrome` **and 7 crash-recovery backups** | `Cookies`, `Login Data`, `Web Data` — saved passwords and live sessions. The backups were 540 MB each and were nearly missed. |
| `~/.codex`, `~/.claude`, `~/.claude.json` | AI CLI session transcripts and credentials |
| `~/.ssh`, `/root/.ssh` | Private keys and `authorized_keys` |
| `~/.bash_history`, `/root/.bash_history` | Commands, sometimes with secrets inline |
| `~/.gnupg`, `~/.local/share/keyrings` | Keys and stored secrets |
| `/etc/ssh/ssh_host_*` | Host identity — regenerated on first boot |
| `/etc/machine-id`, `/var/lib/dbus/machine-id` | Unique machine identity |
| `/etc/NetworkManager/system-connections/*`, `/var/lib/NetworkManager` | Saved Wi-Fi networks and PSKs |
| `/etc/shadow-`, `/etc/gshadow-`, `/etc/passwd-`, `/etc/group-` | Backup copies of the account databases |
| `/var/lib/AccountsService` | Account metadata |
| `/var/log/*` | Truncated |
| `~/.cache`, `~/.Xauthority`, `~/.xsession-errors`, trash, recent files | Assorted traces |

Passwords for `root` and `orangepi` are **expired** (`lastchg=0`), so the first
login forces a change. The Orange Pi first-run configuration is re-armed.

## Verification performed

After cleaning, the build asserts that none of the above paths exist, that
`/etc/machine-id` is empty, that no SSH host keys remain, and that the account
passwords are expired. It **refuses to produce an image** if any check fails.

A recursive scan for private-key headers and API-token patterns is also run. The
only hits are inside `egpu-linux/tools/testing/selftests/sgx/sign_key.pem`, which
is an upstream Linux kernel test fixture, not a credential.

## What deliberately stayed

- The patched NVIDIA modules and the full driver + kernel source trees. These are
  the point of the image.
- `/root/egpu-backup/` — the module tarball and config backup used by
  `egpu-health --repair`.
- The `egpu-*` tooling and all its configuration.
- The engineering journal at `~/egpu-progress.md`.

## If you build your own image from a working board

Do not assume a short deny-list is enough. The two things that nearly leaked here
were both **backup copies** rather than the originals:

- Chrome writes `google-chrome-backup-crashrecovery-*` directories alongside the
  profile. Glob for `google-chrome*`, not the exact name.
- `/etc/shadow-` (trailing dash) holds the previous password database.

Also note that resetting the account password with `chroot` **fails silently on a
cross-architecture host** — an x86_64 machine cannot execute the aarch64
`chpasswd`. Edit `/etc/shadow` directly instead, or verify the change actually
took effect.

## Reporting a problem

If you find something in the image that should not be there, please open an issue.
Do not post the contents.
