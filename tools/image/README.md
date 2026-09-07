# Building the distributable image from a working board

These four scripts are exactly what produced the v1.2 image. They implement the
contract in [SECURITY.md](../../SECURITY.md): everything personal is removed by
glob and by content, the build refuses to continue if any check fails, and the
result is verified a second time with `debugfs`, without root and without
mounting.

Run them in order, from a PC with the board's microSD card attached (here as
`/dev/sdc`; adjust the device and output paths at the top of each script):

| Step | Script | Needs root | What it does |
|---|---|---|---|
| 1 | `10-extract-from-sd.sh` | yes (reads the card) | 32 MiB boot area verbatim, then `e2image -ra` copies only the used blocks of the ext4 partition into a sparse image |
| 2 | `20-sanitize-and-shrink.sh <img>` | yes (loop mount) | Removes the SECURITY.md list, checks the `orangepi` password hash and `lastchg`, scans for keys/tokens, asserts, then `resize2fs -M` + 512 MiB and fixes the partition table |
| 3 | `30-verify.sh <img>` | no | Independent read-only audit of the result with `debugfs` |
| 4 | `40-compress-and-split.sh` | no | `xz -9`, split into < 2 GB parts under the generic names the README uses, SHA-256 for both forms |

Never point step 2 at the card itself. It modifies what it is given.
