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
| `~/.codex`, `~/.claude`, `~/.claude.json`, `~/.gemini` | AI CLI session state: transcripts, conversation databases, history |
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

## Credentials in the published image

The image logs in automatically as **`orangepi`** with password **`orangepi`**,
and **`root` is locked** (`!` prefix on the hash) as on a normal Ubuntu. Change
the password before exposing the board:

```bash
passwd
```

An earlier build tried to be stricter and set `lastchg=0` on both accounts, which
marks the password "must be changed at next login". That was a mistake, twice
over:

- It **breaks lightdm autologin** — the greeter refuses to log in an account whose
  password must be changed, so the image booted to a password prompt instead of a
  desktop.
- The account's hash and the documented password had **drifted apart** between
  rebuilds, so the prompt could not be satisfied at all. The only way in was
  `root`, which was still reachable because `PermitRootLogin yes` is the vendor
  default.

If you rebuild an image, **verify the hash actually matches the password you
intend to document.** Note that `python3 -c "import crypt"` no longer works on
current systems — the module was removed. `perl` still exposes the system
`libcrypt`:

```bash
H=$(sudo awk -F: '$1=="orangepi"{print $2}' /etc/shadow)
perl -e 'my($p,$h)=@ARGV; print crypt($p,$h) eq $h ? "matches\n" : "DOES NOT MATCH\n"' \
     orangepi "$H"
```

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

Do not assume a short deny-list is enough. **A deny-list by exact name failed
twice on this project**, and in both cases the miss was found only on a second
audit:

- Chrome writes `google-chrome-backup-crashrecovery-*` directories alongside the
  profile — 540 MB each, each with `Cookies` and `Login Data`. Glob for
  `google-chrome*`, not the exact name.
- `/etc/shadow-` (trailing dash) holds the previous password database.
- A later rebuild picked up `~/.gemini`, an AI CLI's state directory holding
  conversation databases and transcripts. The list had `~/.codex`, `~/.claude`
  and `~/.claude.json` on it, so it *looked* covered. It was not — a tool that
  had not been used when the list was written had since been used.

The lesson generalises: **audit by pattern and by content, not by a list of names
you happen to remember.** Names go stale the moment the machine is used for
something new. What worked:

```bash
# any AI/agent state directory, whatever it is called
find /home /root -maxdepth 2 -type d \
     \( -iname '.*claude*' -o -iname '.*gemini*' -o -iname '.*codex*' \
        -o -iname '.*copilot*' -o -iname '.*cursor*' -o -iname '.*openai*' \
        -o -iname '.*anthropic*' \)

# any browser profile, whatever it is called
find /home /root -maxdepth 4 -type d \
     \( -iname '*chrome*' -o -iname '*chromium*' -o -iname '*firefox*' \)

# and then by content, not by name
grep -rlIE 'BEGIN (RSA|OPENSSH|EC|DSA|PGP) PRIVATE KEY' /home /root /etc
grep -rlIE '(sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,})' \
     /home /root /etc
```

Also note that resetting the account password with `chroot` **fails silently on a
cross-architecture host** — an x86_64 machine cannot execute the aarch64
`chpasswd`. Edit `/etc/shadow` directly instead, or verify the change actually
took effect.

## Reporting a problem

If you find something in the image that should not be there, please open an issue.
Do not post the contents.
