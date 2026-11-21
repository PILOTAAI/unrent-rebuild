# unrent-rebuild

The second signature on every [Unrent](https://unrent.dev) agent release.

Unrent agents install an update only if **two independent keyless Sigstore signatures** verify over the tarball's
exact SHA-256 (2-of-2, no long-lived key anywhere):

| | Repository | Workflow | Signs when |
|---|---|---|---|
| 1 | `PILOTAAI/unrent` | `.github/workflows/agent-release.yml` @ `refs/tags/agent-v<version>` | it built the release |
| 2 | **this repository** | `.github/workflows/rebuild.yml` @ `refs/tags/agent-v<version>` | it rebuilt the same tag **byte for byte** |

The agent checks both certificates (subject = the workflow at the tag, issuer GitHub Actions, source repository,
ref, owner id, GitHub-hosted runner), both Rekor inclusion proofs and an SCT each, offline, against the Sigstore
public-good trusted root compiled into it. One compromised pipeline cannot ship an agent alone.

## How it works

1. `watch.yml` (every 15 minutes) lists `agent-v*` tags of PILOTAAI/unrent (read-only deploy key) and, for a release
   that get.unrent.dev publishes with only the first signature (`"sigstore": "1-of-2"`):
   - first dispatches `rebuild-check.yml` on `main`: the same checkout, signature-1 check and byte-for-byte rebuild as
     `rebuild.yml`, with no token, tag, signature or release;
   - only once that dry run passed for the version at the same commit of `main`, creates the same tag in this
     repository and dispatches `rebuild.yml` at it. The tag can never move or be deleted (ruleset), so a workflow that
     cannot run must not be tagged: agent-v0.4.1 was tagged on such a commit (the script lacked its executable bit
     through the sync) and stays at one signature; 0.5.2 is the first release through the dry run (2026-11-21: rebuilt byte for byte
     and countersigned; `agent-v0.5.0` and `agent-v0.5.1` were tagged but never released, see docs/release-signing.md). A tag whose
     `rebuild.yml` failed 3 times is no longer retried (the workflow at a tag never changes); a person can still
     dispatch it.
2. `rebuild.yml` (environment `rebuild`, tags `agent-v*` only):
   - checks signature 1 with cosign v3.1.4 and with the agent's own verifier;
   - `scripts/rebuild.sh`: the tag must be on PILOTAAI/unrent's `main`; downloads the published tarballs; takes the
     image lock from them; rebuilds with the tag's own `agent/packaging/release.sh` (Go toolchain from `go.mod`,
     `-trimpath`, `-buildvcs=false`, `SOURCE_DATE_EPOCH` = commit time, deterministic archive); every tarball must
     have exactly the published SHA-256;
   - only then `cosign sign-blob` keylessly (signing config `signing-config.json`: Fulcio, Rekor v1 at
     rekor.sigstore.dev, the Sigstore TSA) and publishes `<tarball>.rebuild.sigstore.json` as this repository's
     release `agent-v<version>`.
3. Unrent's `deploy.yml` (started by its hourly `release-watch.yml`) copies the bundles to get.unrent.dev, verifies
   both with the agent's code, and marks the release `"sigstore": "2-of-2"`. Servers can now update.

A mismatch fails the run and shows which files differ; nothing is signed and no server updates.

## What this protects against, and what not

It catches a release whose bytes do not come from the tagged source on main: a compromised release run, runner,
action, cache or release token, or a tag on an unreviewed commit. It does not catch malicious source merged to
PILOTAAI/unrent's main (both workflows build it faithfully), and both repositories are managed by Unrent's OpenTofu
(`infra/github` in PILOTAAI/unrent): the GitHub token of that pipeline and GitHub itself remain trusted.
Every signature is public in Rekor; Unrent's `release-watch.yml` alerts and halts releases if either identity ever
signs something that is not a published release.

## Repository settings

Created and kept in shape by OpenTofu in PILOTAAI/unrent (`infra/github`, docs/release-signing.md): public, this
content on `main`, environment `rebuild` limited to `agent-v*` tags, tag ruleset (`agent-v*` tags cannot be moved or
deleted), branch ruleset on `main`, and the Actions secret `UNRENT_SOURCE_DEPLOY_KEY` (the private half of a
read-only deploy key on PILOTAAI/unrent). Change these files in PILOTAAI/unrent (`release-rebuild/`), not here.
