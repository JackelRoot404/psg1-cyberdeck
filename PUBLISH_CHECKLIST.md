# Publication checklist

Steps to safely publish this repo to GitHub. Run through them in order; don't skip the eyeball checks even if it feels redundant.

## 1. Clone to a clean directory (don't init in the workspace)

```sh
# DO NOT run `git init` inside /tmp/psg1 — there's 1.5 GB of firmware in there.
# Copy only the publish/ subtree into a fresh location.
mkdir -p ~/code/psg1-cyberdeck
cp -R /tmp/psg1/publish/. ~/code/psg1-cyberdeck/
cd ~/code/psg1-cyberdeck
ls -A
```

You should see exactly:
```
.gitignore
LICENSE
PSG1_CYBERDECK_OPS.md
PSG1_NOTES.md
PUBLISH_CHECKLIST.md   ← delete this before publishing, or keep as an example
README.md
psg1_keepalive.sh
psg1_termux_setup.sh
```

Nothing else. If you see APKs, firmware, decompiled trees, or `.local.md` files — stop and clean up.

## 2. Eyeball the markdown for personal info one more time

```sh
grep -rni -E 'your-actual-email|your-actual-ip|your-serial-number|your-username' .
```

Substitute with whatever your real identifiers are. The redacted versions should hit zero matches. If anything pops up, fix it.

Also worth scanning by eye:
```sh
grep -nE '(192\.168|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.6[4-9]\.|100\.[7-9][0-9]\.|100\.1[01][0-9]\.|100\.12[0-7]\.)' *.md *.sh
```
This catches IPv4 private + Tailscale CGNAT ranges. Anything that's a literal IP and not a placeholder needs to be redacted.

```sh
grep -nE 'ssh-(rsa|ed25519|ecdsa) AAAA' *.sh *.md
```
This catches embedded SSH public keys. The setup script should only have a placeholder.

## 3. Eyeball the scripts

```sh
less psg1_termux_setup.sh
less psg1_keepalive.sh
```

In `psg1_termux_setup.sh`, line 14 should be the placeholder `AAAA<REPLACE_WITH_YOUR_PUBKEY>` — NOT your actual key.

In `psg1_keepalive.sh`, there should be no absolute paths to your home directory and no IP addresses.

## 4. Init git and double-check what's about to commit

```sh
git init
git add -A
git status
```

Read the entire `git status` output. If you see anything outside the 7-file list from step 1, stop and figure out why.

```sh
# What's the diff actually going to contain?
git diff --cached | wc -l    # quick sanity check on size
git diff --cached | grep -nE 'AAAA[A-Za-z0-9+/]+=|@gmail\.com|@outlook\.com|@yahoo\.com'    # email or key-like strings
```

## 5. First commit

```sh
git commit -m "Initial commit: PSG1 cyberdeck writeup and tooling"
```

## 6. Push to GitHub

Create the repo as **PUBLIC** on github.com first (so you can `git remote add` to it):

```sh
git remote add origin git@github.com:<your-username>/psg1-cyberdeck.git
git branch -M main
git push -u origin main
```

## 7. After publishing — final eyeball

Open the repo on github.com in a browser and read each file as a stranger would. If anything jumps out as "wait, that's my…" — make the repo private immediately, fix it, force-push, re-publicize.

## Things to consider AFTER publishing

- **Don't accept PRs that add binaries** — the gitignore catches most, but a determined contributor could commit one with `-f`. Code-review every PR.
- **If you ever post the GitHub URL on the PSG1 itself or in PlaySolana's forums**, consider that PlaySolana may take notice. The DMCA exemptions cited in the README are real but won't stop a takedown notice from being filed; they'd just be a defense if you contested.
- **The kernel attack-surface and Echos-spoof sections are the spicy parts.** If you get a takedown, those are likely targets. Have a backup of the repo and your own notes about why each section is documenting shipped behavior on a device you own.

## What I deliberately did NOT publish

For my own records (so I don't accidentally include them later):

- Device serial number
- LAN IPs (jumpbox, PSG1)
- Tailscale IPs
- SSH pubkey contents (mine + jumpbox's)
- SSH key email comments (contain real email)
- Exact MaskROM test-pad positions (described abstractly; reproducible by anyone willing to open the device)
- The Ubuntu jumpbox username
- Any decompiled bytecode from PlaySolana proprietary code
- Third-party APK binaries (Claude, Lawnchair, Termux, Shizuku, etc.)
- Firmware partitions (`framework.jar`, `services.jar`, `Settings.apk`, `boot.img`, `ota_signed.zip`, `resources.arsc`)
