#!/usr/bin/env bash
# Rebuilds a published Unrent agent release and checks it byte for byte (README.md). It does NOT sign: the workflow
# (.github/workflows/rebuild.yml) signs the rebuilt tarballs keylessly only after this script succeeded.
#
#   scripts/rebuild.sh <version> <unrent-checkout-at-agent-v<version>> <out-dir>
#
# 1. The checkout is PILOTAAI/unrent at the tag, and the tagged commit is on its main branch.
# 2. Downloads the published release from get.unrent.dev (manifest, SHA256SUMS, tarballs, the release workflow's
#    bundles) and checks SHA256SUMS against the manifest.
# 3. Verifies signature 1 (PILOTAAI/unrent agent-release.yml at refs/tags/agent-v<version>) on every tarball with the
#    agent's own verifier (agent/tools/release-tool verify -only release). The workflow checks it with cosign too.
# 4. Takes the image lock from the published tarball (both tarballs must carry the same lock), but does not trust it:
#    the lock is an output of the release run, so this pipeline resolves every image tag of the tag's source itself
#    (the tag's release-tool pin-images) and requires the identical lock, and every first-party image
#    (ghcr.io/pilotaai/*) must carry a build-provenance attestation by its own workflow on PILOTAAI/unrent main.
#    Then it rebuilds with the checkout's agent/packaging/release.sh (reproducible build).
# 5. Every rebuilt tarball must have exactly the published SHA-256. Otherwise it fails and shows which files differ.
#
# Environment: RELEASES_BASE (default https://get.unrent.dev), REBUILD_ARCHES (default "amd64 arm64"),
# TRUSTED_ROOT (tests only: a Sigstore trusted_root.json instead of the one compiled into the agent),
# IMAGE_LOCK_RESOLVE=placeholder (tests only, offline: re-derive the lock with pin-images -placeholder, whose digests
# no registry serves, so there are no attestations to check either). The workflows never set either.
set -euo pipefail
V=${1:?version} SRC=$(cd "${2:?unrent checkout}" && pwd) OUT=${3:?out dir}
BASE=${RELEASES_BASE:-https://get.unrent.dev}
ARCHES=${REBUILD_ARCHES:-amd64 arm64}
printf '%s\n' "$V" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' || { echo "rebuild: bad version '$V'" >&2; exit 2; }
TAG="agent-v$V"
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
PUB="$OUT/published"
rm -rf "$PUB" "$OUT/rebuilt"
mkdir -p "$PUB"

echo "== source: $TAG"
commit=$(git -C "$SRC" rev-parse "refs/tags/$TAG^{commit}")
[ "$(git -C "$SRC" rev-parse HEAD)" = "$commit" ] || { echo "rebuild: the checkout is not at $TAG ($commit)" >&2; exit 1; }
main=$(git -C "$SRC" rev-parse --verify --quiet refs/remotes/origin/main || git -C "$SRC" rev-parse --verify refs/heads/main)
git -C "$SRC" merge-base --is-ancestor "$commit" "$main" || { echo "rebuild: $TAG ($commit) is not on main" >&2; exit 1; }
echo "$TAG = $commit (on main)"

echo "== published release ($BASE)"
curl -fsS --retry 3 -o "$PUB/manifest.json" "$BASE/releases/$V/manifest.json"
curl -fsS --retry 3 -o "$PUB/SHA256SUMS" "$BASE/releases/$V/SHA256SUMS"
[ "$(jq -r .version "$PUB/manifest.json")" = "$V" ] || { echo "rebuild: the manifest is not for $V" >&2; exit 1; }
for arch in $ARCHES; do
  f="unrent-$V-linux-$arch.tar.gz"
  curl -fsS --retry 3 -o "$PUB/$f" "$BASE/releases/$V/$f"
  curl -fsS --retry 3 -o "$PUB/$f.release.sigstore.json" "$BASE/releases/$V/$f.release.sigstore.json"
  want=$(jq -r --arg k "linux-$arch" '.files[$k].sha256' "$PUB/manifest.json")
  got=$(sha256sum "$PUB/$f" | cut -d' ' -f1)
  [ "$want" = "$got" ] || { echo "rebuild: $f is $got, the manifest says $want" >&2; exit 1; }
  grep -q "^$got  $f\$" "$PUB/SHA256SUMS" || { echo "rebuild: $f is not in SHA256SUMS" >&2; exit 1; }
done

echo "== signature 1: the release workflow"
( cd "$SRC/agent" && go build -o "$OUT/release-tool" ./tools/release-tool )
for arch in $ARCHES; do
  f="unrent-$V-linux-$arch.tar.gz"
  "$OUT/release-tool" verify -only release -version "$V" -file "$PUB/$f" -release "$PUB/$f.release.sigstore.json" ${TRUSTED_ROOT:+-trusted-root "$TRUSTED_ROOT"}
done

echo "== image lock from the published release"
LOCK="$OUT/images.lock.json"
first=''
for arch in $ARCHES; do
  f="unrent-$V-linux-$arch.tar.gz"
  tar -xzOf "$PUB/$f" "unrent-$V-linux-$arch/images.lock.json" > "$OUT/lock-$arch.json"
  if [ -z "$first" ]; then first=$arch; cp "$OUT/lock-$arch.json" "$LOCK"; else cmp -s "$LOCK" "$OUT/lock-$arch.json" || { echo "rebuild: the tarballs carry different image locks" >&2; exit 1; }; fi
done
jq -r '.images | to_entries[] | "  \(.key) \(.value.ref)@\(.value.digest)"' "$LOCK"

echo "== image lock re-derived here, not taken from the release run"
RESOLVE=${IMAGE_LOCK_RESOLVE:-registry}
case $RESOLVE in
  registry) "$OUT/release-tool" pin-images -out "$OUT/images.lock.rederived.json" >/dev/null ;;
  placeholder) "$OUT/release-tool" pin-images -placeholder -out "$OUT/images.lock.rederived.json" >/dev/null ;;
  *) echo "rebuild: IMAGE_LOCK_RESOLVE is registry or placeholder (tests), not '$RESOLVE'" >&2; exit 2 ;;
esac
if ! cmp -s <(jq -S . "$LOCK") <(jq -S . "$OUT/images.lock.rederived.json"); then
  diff <(jq -S . "$LOCK") <(jq -S . "$OUT/images.lock.rederived.json") >&2 || true
  echo "rebuild: the published image lock is not what $TAG's image tags resolve to here; not signing" >&2
  exit 1
fi
echo "every digest is what $TAG's tags resolve to"
# First-party images: the digest must have been built and attested by its own workflow on PILOTAAI/unrent main (a
# tag of these repositories is pushed by a workflow, which is not proof it ran on main). The attestation is read from
# the registry (attest-build-provenance pushes it there), so this needs no access to PILOTAAI/unrent's API.
first_party_workflow() {
  case $1 in
    ghcr.io/pilotaai/unrent-postgres) echo postgres-image.yml ;;
    ghcr.io/pilotaai/unrent-postgres-ha) echo postgres-ha-image.yml ;;
    ghcr.io/pilotaai/unrent-postgres-documentdb) echo postgres-documentdb-image.yml ;;
    ghcr.io/pilotaai/unrent-caddy) echo caddy-image.yml ;;
    ghcr.io/pilotaai/unrent-pbm) echo pbm-image.yml ;;
    *) return 1 ;;
  esac
}
while read -r name ref digest; do
  repo=${ref%@*}
  case ${repo##*/} in *:*) repo=${repo%:*} ;; esac
  case $repo in ghcr.io/pilotaai/*) ;; *) continue ;; esac
  wf=$(first_party_workflow "$repo") || { echo "rebuild: $name ($repo) is a first-party image with no known producing workflow; not signing" >&2; exit 1; }
  if [ "$RESOLVE" = placeholder ]; then echo "  $name: attestation not checked (placeholder lock, tests)"; continue; fi
  gh attestation verify "oci://$repo@$digest" --bundle-from-oci --repo PILOTAAI/unrent \
    --signer-workflow "PILOTAAI/unrent/.github/workflows/$wf" --source-ref refs/heads/main --deny-self-hosted-runners >/dev/null \
    || { echo "rebuild: $name ($repo@$digest) has no build-provenance attestation by $wf on PILOTAAI/unrent main; not signing" >&2; exit 1; }
  echo "  $name: attested by $wf on main"
done < <(jq -r '.images | to_entries[] | "\(.key) \(.value.ref) \(.value.digest)"' "$LOCK")

echo "== rebuild (reproducible: agent/packaging/release.sh of the tag)"
# shellcheck disable=SC2086 # ARCHES is a word list
SOURCE_DATE_EPOCH=$(git -C "$SRC" log -1 --format=%ct "$commit") RELEASE_IMAGES_LOCK="$LOCK" \
  "$SRC/agent/packaging/release.sh" "$V" "$OUT/rebuilt" $ARCHES >/dev/null

echo "== compare"
ok=true
for arch in $ARCHES; do
  f="unrent-$V-linux-$arch.tar.gz"
  a=$(sha256sum "$PUB/$f" | cut -d' ' -f1) b=$(sha256sum "$OUT/rebuilt/$f" | cut -d' ' -f1)
  if [ "$a" = "$b" ]; then
    echo "identical: $f $a"
  else
    ok=false
    echo "DIFFERENT: $f published $a, rebuilt $b"
    mkdir -p "$OUT/x/pub" "$OUT/x/reb"
    tar -xzf "$PUB/$f" -C "$OUT/x/pub" && tar -xzf "$OUT/rebuilt/$f" -C "$OUT/x/reb"
    (cd "$OUT/x/pub" && find . -type f | sort | while read -r p; do cmp -s "$p" "$OUT/x/reb/$p" || echo "  differs: $p"; done)
  fi
done
$ok || { echo "rebuild: the release is not reproducible from $TAG; not signing" >&2; exit 1; }
echo "PASS: $TAG rebuilt byte for byte; ready to sign $OUT/rebuilt/*.tar.gz"
