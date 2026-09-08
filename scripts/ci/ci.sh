#!/usr/bin/env bash
set -Eeuo pipefail

readonly PROJECT_NAME="sccache-ng"
readonly UPSTREAM_REPOSITORY="mozilla/sccache"
readonly UPSTREAM_URL="https://github.com/mozilla/sccache.git"
readonly NIGHTLY_RELEASE="sccache-ng-nightly"
readonly FAILURE_LABEL_NIGHTLY="Nightly"
readonly FAILURE_LABEL_CI="CI-Failure"
readonly FAILURE_MARKER="<!-- sccache-ng-nightly-failure -->"
readonly ALPINE_IMAGE="alpine:3.24"
readonly RUST_BUILDER_IMAGE="rust:alpine3.24"
readonly RETENTION_KEEP="7"
readonly RETENTION_DAYS="14"
readonly CARGO_FLAGS="--locked --release --all-features --bins"
readonly OPT_LEVEL="3"
readonly LTO_MODE="fat"
readonly DEPS_BRANCH="ci/centralized_versions"
readonly ACTIONS_CHECKOUT_REF="refs/tags/v4"
readonly ACTIONS_CACHE_REF="refs/tags/v4"
readonly ACTIONS_UPLOAD_ARTIFACT_REF="refs/tags/v4"
readonly ACTIONS_DOWNLOAD_ARTIFACT_REF="refs/tags/v4"
readonly ACTIONS_ATTEST_PROVENANCE_REF="refs/tags/v1"
readonly ACTIONS_ATTEST_SBOM_REF="refs/tags/v1"
readonly BANNED_ACTION_RUNTIME="node${BANNED_NODE_MAJOR:-20}"

MODE="${MODE:-${1:-nightly}}"
ARCH="${ARCH:-all}"
REQUESTED_MODE="${REQUESTED_MODE:-$MODE}"
REQUESTED_ARCH="${REQUESTED_ARCH:-$ARCH}"
FORCE="${FORCE:-false}"
PUBLISH="${PUBLISH:-true}"
UPSTREAM_REF="${UPSTREAM_REF:-main}"
CLEANUP="${CLEANUP:-true}"
DEBUG="${DEBUG:-false}"

if [ "$DEBUG" = "true" ]; then
  set -x
fi

if [ -n "${PROJECT_AUTOMATION_PAT:-}" ]; then
  export GH_TOKEN="$PROJECT_AUTOMATION_PAT"
  export GITHUB_TOKEN="$PROJECT_AUTOMATION_PAT"
elif [ -n "${GITHUB_TOKEN:-}" ]; then
  export GH_TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}"
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && { pwd -W 2>/dev/null || pwd; })"
WORK_DIR="${RUNNER_TEMP:-$ROOT_DIR/.tmp}/sccache-ng-ci"
UPSTREAM_DIR="$WORK_DIR/upstream"
OUT_DIR="$ROOT_DIR/dist/sccache-ng"
META_DIR="$OUT_DIR/metadata"

log() {
  printf '%s\n' "$*" >&2
}

die() {
  log "error: $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

repo_owner() {
  printf '%s\n' "${GITHUB_REPOSITORY_OWNER:-${GITHUB_REPOSITORY%%/*}}"
}

image_name() {
  printf 'ghcr.io/%s/%s\n' "$(repo_owner)" "$PROJECT_NAME"
}

builder_image_name() {
  printf 'ghcr.io/%s/%s-builder\n' "$(repo_owner)" "$PROJECT_NAME"
}

platform_for_arch() {
  case "$1" in
    amd64) printf 'linux/amd64\n' ;;
    arm64) printf 'linux/arm64\n' ;;
    *) die "unsupported arch: $1" ;;
  esac
}

debian_arch() {
  case "$1" in
    amd64) printf 'amd64\n' ;;
    arm64) printf 'arm64\n' ;;
    *) die "unsupported arch: $1" ;;
  esac
}

alpine_arch() {
  case "$1" in
    amd64) printf 'x86_64\n' ;;
    arm64) printf 'aarch64\n' ;;
    *) die "unsupported arch: $1" ;;
  esac
}

selected_arches() {
  case "$REQUESTED_ARCH" in
    all) printf '%s\n' amd64 arm64 ;;
    amd64|arm64) printf '%s\n' "$REQUESTED_ARCH" ;;
    *) die "unsupported REQUESTED_ARCH: $REQUESTED_ARCH" ;;
  esac
}

arch_requested() {
  [ "$REQUESTED_ARCH" = "all" ] || [ "$REQUESTED_ARCH" = "$1" ]
}

native_arch() {
  case "$(uname -m)" in
    x86_64) printf 'amd64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    *) die "unsupported native machine: $(uname -m)" ;;
  esac
}

ensure_dirs() {
  mkdir -p "$WORK_DIR" "$OUT_DIR" "$META_DIR"
}

require_base_tools() {
  require_cmd git
  require_cmd gh
  require_cmd jq
  require_cmd tar
  require_cmd gzip
  require_cmd sha256sum
}

require_docker_tools() {
  require_cmd docker
  docker buildx version >/dev/null
}

require_rust_tools() {
  require_cmd cargo
  require_cmd rustc
}

gh_repo() {
  printf '%s\n' "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
}

resolve_upstream() {
  ensure_dirs
  rm -rf "$UPSTREAM_DIR"
  git clone --no-tags --filter=blob:none "$UPSTREAM_URL" "$UPSTREAM_DIR"
  git -C "$UPSTREAM_DIR" fetch --depth=1 origin "$UPSTREAM_REF"
  git -C "$UPSTREAM_DIR" checkout --detach FETCH_HEAD
}

upstream_sha() {
  git -C "$UPSTREAM_DIR" rev-parse HEAD
}

upstream_version() {
  sed -n 's/^version = "\(.*\)"/\1/p' "$UPSTREAM_DIR/Cargo.toml" | head -n1
}

ci_identity() {
  git -C "$ROOT_DIR" hash-object scripts/ci/ci.sh
}

identity_json() {
  jq -n \
    --arg project "$PROJECT_NAME" \
    --arg upstream_repository "$UPSTREAM_REPOSITORY" \
    --arg upstream_sha "$(upstream_sha)" \
    --arg upstream_version "$(upstream_version)" \
    --arg ci_identity "$(ci_identity)" \
    --arg alpine_image "$ALPINE_IMAGE" \
    --arg rust_builder_image "$RUST_BUILDER_IMAGE" \
    --arg cargo_flags "$CARGO_FLAGS" \
    --arg opt_level "$OPT_LEVEL" \
    --arg lto "$LTO_MODE" \
    '{project:$project,upstream_repository:$upstream_repository,upstream_sha:$upstream_sha,upstream_version:$upstream_version,ci_identity:$ci_identity,alpine_image:$alpine_image,rust_builder_image:$rust_builder_image,cargo_flags:$cargo_flags,opt_level:$opt_level,lto:$lto}'
}

metadata_path() {
  printf '%s/build-metadata.json\n' "$META_DIR"
}

sbom_path() {
  printf '%s/sbom.spdx.json\n' "$OUT_DIR"
}

write_identity_metadata() {
  identity_json > "$(metadata_path)"
}

builder_image_available() {
  require_docker_tools
  docker_login
  docker manifest inspect "$(builder_image_name):nightly" >/dev/null 2>&1
}

is_berlin_weekly_window() {
  [ "$(TZ=Europe/Berlin date +%u)" = "7" ] || return 1
  [ "$(TZ=Europe/Berlin date +%H)" = "04" ] || return 1
}

download_current_metadata() {
  local dest_dir="$WORK_DIR/current-release"
  local dest="$dest_dir/build-metadata.json"
  rm -rf "$dest_dir"
  mkdir -p "$dest_dir"
  rm -f "$dest"
  gh release download "$NIGHTLY_RELEASE" \
    --repo "$(gh_repo)" \
    --pattern build-metadata.json \
    --dir "$dest_dir" >/dev/null 2>&1 || return 1
  [ -s "$dest" ] || return 1
  printf '%s\n' "$dest"
}

admission_needed() {
  [ "$FORCE" = "true" ] && return 0
  local current
  current="$(download_current_metadata)" || return 0
  cmp -s "$(metadata_path)" "$current" && return 1
  return 0
}

emit_output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

admission() {
  require_base_tools
  resolve_upstream
  write_identity_metadata
  local sha
  local run_builder="false"
  local builder_exists="false"
  sha="$(upstream_sha)"
  emit_output upstream_sha "$sha"
  emit_output image "$(image_name)"
  emit_output builder_image "$(builder_image_name)"
  emit_output version "$(upstream_version)"
  if builder_image_available; then
    builder_exists="true"
  fi
  if [ "$REQUESTED_MODE" = "builder" ] || is_berlin_weekly_window || [ "$builder_exists" != "true" ]; then
    run_builder="true"
  fi
  emit_output run_builder "$run_builder"
  log "run_builder=$run_builder builder_image_exists=$builder_exists"
  if admission_needed; then
    emit_output decision build
    log "decision=build"
  else
    emit_output decision noop
    log "decision=noop"
  fi
}

docker_login() {
  [ "$PUBLISH" = "true" ] || return 0
  printf '%s' "${GH_TOKEN:?PROJECT_AUTOMATION_PAT or GITHUB_TOKEN is required}" \
    | docker login ghcr.io -u "${GITHUB_ACTOR:?GITHUB_ACTOR is required}" --password-stdin
}

build_output() {
  local image="$1"
  local name="$2"
  if [ "$PUBLISH" = "true" ]; then
    printf 'type=image,name=%s,push-by-digest=true,name-canonical=true,push=true\n' "$image"
  else
    printf 'type=docker,dest=%s/%s.tar\n' "$META_DIR" "$name"
  fi
}

builder_containerfile() {
  local file="$WORK_DIR/Containerfile.builder"
  cat > "$file" <<EOF
FROM ${RUST_BUILDER_IMAGE}
RUN apk add --no-cache bash build-base ca-certificates coreutils git jq musl-dev openssl-dev perl pkgconf tar xz zstd
EOF
  printf '%s\n' "$file"
}

build_builder() {
  require_base_tools
  require_docker_tools
  docker_login
  local file image output
  arch_requested "$(native_arch)" || return 0
  ensure_dirs
  file="$(builder_containerfile)"
  image="$(builder_image_name)"
  output="$(build_output "$image" "builder-$(native_arch)")"
  docker buildx build \
    --pull \
    --platform "$(platform_for_arch "$(native_arch)")" \
    --cache-from "type=gha,scope=${PROJECT_NAME}-builder-$(native_arch)" \
    --cache-to "type=gha,mode=max,scope=${PROJECT_NAME}-builder-$(native_arch)" \
    --label "org.opencontainers.image.source=https://github.com/$(gh_repo)" \
    --label "org.opencontainers.image.created=$(date -u +%FT%TZ)" \
    --label "org.opencontainers.image.revision=${GITHUB_SHA:-local}" \
    --metadata-file "$META_DIR/builder-image.json" \
    --output "$output" \
    -f "$file" "$WORK_DIR"
  if [ "$PUBLISH" = "true" ]; then
    jq -r '."containerimage.digest"' "$META_DIR/builder-image.json" > "$META_DIR/builder.digest"
  fi
}

prepare_source() {
  require_base_tools
  resolve_upstream
  write_identity_metadata
}

build_binaries() {
  require_docker_tools
  local arch jobs target_dir builder
  arch="$(native_arch)"
  arch_requested "$arch" || return 0
  jobs="$(nproc)"
  target_dir="$UPSTREAM_DIR/target/nightly-${arch}"
  builder="$(builder_image_name):nightly"
  docker_login
  docker pull "$builder"
  docker run --rm \
    -e CARGO_BUILD_JOBS="$jobs" \
    -e CARGO_INCREMENTAL=0 \
    -e CARGO_PROFILE_RELEASE_OPT_LEVEL="$OPT_LEVEL" \
    -e CARGO_PROFILE_RELEASE_LTO="$LTO_MODE" \
    -e CARGO_PROFILE_RELEASE_CODEGEN_UNITS="$jobs" \
    -e CARGO_TARGET_DIR="/src/target/nightly-${arch}" \
    -v "$UPSTREAM_DIR:/src" \
    -w /src \
    "$builder" \
    cargo build $CARGO_FLAGS
  mkdir -p "$OUT_DIR/bin/$arch"
  cp "$target_dir/release/sccache" "$OUT_DIR/bin/$arch/sccache"
  cp "$target_dir/release/sccache-dist" "$OUT_DIR/bin/$arch/sccache-dist"
  chmod 0755 "$OUT_DIR/bin/$arch/sccache" "$OUT_DIR/bin/$arch/sccache-dist"
}

smoke_test() {
  local arch tmp cc
  arch="$(native_arch)"
  tmp="$WORK_DIR/smoke-$arch"
  mkdir -p "$tmp"
  cat > "$tmp/main.c" <<'EOF'
int main(void) { return 0; }
EOF
  cc="$(command -v cc || true)"
  [ -n "$cc" ] || die "cc is required for smoke test"
  SCCACHE_DIR="$tmp/cache" "$OUT_DIR/bin/$arch/sccache" "$cc" -c "$tmp/main.c" -o "$tmp/main.o"
  test -s "$tmp/main.o"
  "$OUT_DIR/bin/$arch/sccache" --version
  "$OUT_DIR/bin/$arch/sccache-dist" --help >/dev/null
}

archive_name() {
  printf '%s-%s-%s-%s\n' "$PROJECT_NAME" "$(upstream_version)" "$(upstream_sha)" "$1"
}

build_tarball() {
  local arch name root
  arch="$(native_arch)"
  name="$(archive_name "$arch")"
  root="$WORK_DIR/$name"
  rm -rf "$root"
  mkdir -p "$root/bin"
  cp "$OUT_DIR/bin/$arch/sccache" "$root/bin/"
  cp "$OUT_DIR/bin/$arch/sccache-dist" "$root/bin/"
  cp "$UPSTREAM_DIR/LICENSE" "$root/"
  cp "$UPSTREAM_DIR/README.md" "$root/"
  tar -C "$WORK_DIR" -czf "$OUT_DIR/$name.tar.gz" "$name"
}

build_deb() {
  local arch pkg version root control data control_tar data_tar deb binary_arch
  arch="$(native_arch)"
  binary_arch="$(debian_arch "$arch")"
  version="$(upstream_version)+$(upstream_sha)"
  pkg="${PROJECT_NAME}_${version}_${binary_arch}"
  root="$WORK_DIR/deb-$arch"
  rm -rf "$root"
  mkdir -p "$root/DEBIAN" "$root/usr/bin" "$root/usr/share/doc/$PROJECT_NAME"
  cp "$OUT_DIR/bin/$arch/sccache" "$root/usr/bin/"
  cp "$OUT_DIR/bin/$arch/sccache-dist" "$root/usr/bin/"
  gzip -cn "$UPSTREAM_DIR/README.md" > "$root/usr/share/doc/$PROJECT_NAME/README.md.gz"
  control="$root/DEBIAN/control"
  cat > "$control" <<EOF
Package: ${PROJECT_NAME}
Version: ${version}
Section: devel
Priority: optional
Architecture: ${binary_arch}
Maintainer: ${GITHUB_REPOSITORY_OWNER:-sccache-ng} <noreply@github.com>
Description: Shared compilation cache binaries
EOF
  data_tar="$WORK_DIR/data.tar.gz"
  control_tar="$WORK_DIR/control.tar.gz"
  tar -C "$root/DEBIAN" -czf "$control_tar" control
  tar -C "$root" --exclude=DEBIAN -czf "$data_tar" .
  printf '2.0\n' > "$WORK_DIR/debian-binary"
  deb="$OUT_DIR/$pkg.deb"
  rm -f "$deb"
  ar rcs "$deb" "$WORK_DIR/debian-binary" "$control_tar" "$data_tar"
}

build_apk() {
  local arch apk_arch version pkg root pkginfo
  arch="$(native_arch)"
  apk_arch="$(alpine_arch "$arch")"
  version="$(upstream_version).git$(upstream_sha)"
  pkg="${PROJECT_NAME}-${version}-${apk_arch}"
  root="$WORK_DIR/apk-$arch"
  rm -rf "$root"
  mkdir -p "$root/usr/bin"
  cp "$OUT_DIR/bin/$arch/sccache" "$root/usr/bin/"
  cp "$OUT_DIR/bin/$arch/sccache-dist" "$root/usr/bin/"
  pkginfo="$root/.PKGINFO"
  cat > "$pkginfo" <<EOF
pkgname = ${PROJECT_NAME}
pkgver = ${version}
pkgdesc = Shared compilation cache binaries
url = https://github.com/${GITHUB_REPOSITORY:-wiki-mod/sccache-ng}
builddate = $(date -u +%s)
packager = ${GITHUB_REPOSITORY_OWNER:-sccache-ng}
size = $(du -ks "$root" | awk '{print $1 * 1024}')
arch = ${apk_arch}
license = Apache-2.0
EOF
  tar -C "$root" -czf "$OUT_DIR/$pkg.apk" .
}

write_checksums() {
  (cd "$OUT_DIR" && sha256sum ./*.tar.gz ./*.deb ./*.apk > SHA256SUMS)
}

write_sbom() {
  local arch
  arch="$(native_arch)"
  jq -n \
    --arg name "$PROJECT_NAME" \
    --arg upstream "$UPSTREAM_REPOSITORY" \
    --arg sha "$(upstream_sha)" \
    --arg version "$(upstream_version)" \
    --arg arch "$arch" \
    '{spdxVersion:"SPDX-2.3",dataLicense:"CC0-1.0",SPDXID:"SPDXRef-DOCUMENT",name:$name,documentNamespace:("https://github.com/" + $upstream + "/nightly/" + $sha + "/" + $arch),creationInfo:{created:(now | todate),creators:["Tool: scripts/ci/ci.sh"]},packages:[{name:$name,SPDXID:"SPDXRef-Package-sccache-ng",versionInfo:$version,downloadLocation:"NOASSERTION",filesAnalyzed:false,externalRefs:[{referenceCategory:"PACKAGE-MANAGER",referenceType:"purl",referenceLocator:("pkg:github/" + $upstream + "@" + $sha)}]}]}' \
    > "$(sbom_path)"
}

build_runtime_image() {
  require_docker_tools
  docker_login
  local arch file rootfs image output
  arch="$(native_arch)"
  rootfs="$WORK_DIR/image-root-$arch"
  rm -rf "$rootfs"
  mkdir -p "$rootfs"
  cp "$OUT_DIR/bin/$arch/sccache" "$rootfs/sccache"
  cp "$OUT_DIR/bin/$arch/sccache-dist" "$rootfs/sccache-dist"
  file="$WORK_DIR/Containerfile.runtime"
  cat > "$file" <<EOF
FROM ${ALPINE_IMAGE}
LABEL org.opencontainers.image.title="${PROJECT_NAME}"
LABEL org.opencontainers.image.source="https://github.com/${GITHUB_REPOSITORY:-wiki-mod/sccache-ng}"
LABEL org.opencontainers.image.revision="$(upstream_sha)"
LABEL org.opencontainers.image.version="$(upstream_version)"
LABEL org.opencontainers.image.created="$(date -u +%FT%TZ)"
RUN apk add --no-cache ca-certificates
COPY sccache /usr/local/bin/sccache
COPY sccache-dist /usr/local/bin/sccache-dist
WORKDIR /work
ENTRYPOINT ["sccache"]
EOF
  image="$(image_name)"
  output="$(build_output "$image" "runtime-$arch")"
  docker buildx build \
    --pull \
    --platform "$(platform_for_arch "$arch")" \
    --cache-from "type=gha,scope=${PROJECT_NAME}-runtime-${arch}" \
    --cache-to "type=gha,mode=max,scope=${PROJECT_NAME}-runtime-${arch}" \
    --attest type=provenance,mode=max \
    --attest type=sbom \
    --metadata-file "$META_DIR/runtime-$arch.json" \
    --output "$output" \
    -f "$file" "$rootfs"
  if [ "$PUBLISH" = "true" ]; then
    jq -r '."containerimage.digest"' "$META_DIR/runtime-$arch.json" > "$META_DIR/runtime-$arch.digest"
  fi
}

build_packages() {
  prepare_source
  build_binaries
  smoke_test
  build_tarball
  build_deb
  build_apk
  write_checksums
  write_sbom
  build_runtime_image
}

promote_builder() {
  require_base_tools
  require_docker_tools
  [ "$PUBLISH" = "true" ] || return 0
  docker_login
  local image refs=()
  image="$(builder_image_name)"
  while IFS= read -r digest; do
    refs+=("${image}@${digest}")
  done < <(find "$META_DIR" -name 'builder.digest' -type f -exec cat {} \;)
  [ "${#refs[@]}" -gt 0 ] || die "no builder digests found"
  docker buildx imagetools create \
    -t "${image}:nightly" \
    -t "${image}:latest" \
    -t "${image}:${GITHUB_SHA:-$(git -C "$ROOT_DIR" rev-parse HEAD)}" \
    "${refs[@]}"
}

promote_runtime() {
  require_base_tools
  require_docker_tools
  [ "$PUBLISH" = "true" ] || return 0
  docker_login
  prepare_source
  local image sha refs=()
  image="$(image_name)"
  sha="$(upstream_sha)"
  while IFS= read -r digest; do
    refs+=("${image}@${digest}")
  done < <(find "$META_DIR" -name 'runtime-*.digest' -type f -exec cat {} \;)
  [ "${#refs[@]}" -gt 0 ] || die "no runtime digests found"
  docker buildx imagetools create \
    -t "${image}:latest" \
    -t "${image}:nightly" \
    -t "${image}:${sha}" \
    "${refs[@]}"
}

publish_release() {
  require_base_tools
  [ "$PUBLISH" = "true" ] || return 0
  prepare_source
  local notes
  notes="$WORK_DIR/release-notes.md"
  {
    printf 'sccache-ng nightly\n\n'
    printf 'Upstream: %s\n' "$UPSTREAM_REPOSITORY"
    printf 'SHA: %s\n' "$(upstream_sha)"
    printf 'Version: %s\n' "$(upstream_version)"
  } > "$notes"
  write_checksums
  gh release view "$NIGHTLY_RELEASE" --repo "$(gh_repo)" >/dev/null 2>&1 \
    || gh release create "$NIGHTLY_RELEASE" --repo "$(gh_repo)" --title "$NIGHTLY_RELEASE" --notes-file "$notes" --prerelease
  gh release edit "$NIGHTLY_RELEASE" --repo "$(gh_repo)" --title "$NIGHTLY_RELEASE" --notes-file "$notes" --prerelease
  find "$OUT_DIR" -maxdepth 1 -type f -print0 \
    | xargs -0 gh release upload "$NIGHTLY_RELEASE" --repo "$(gh_repo)" --clobber
}

failure_issue_number() {
  gh issue list \
    --repo "$(gh_repo)" \
    --label "$FAILURE_LABEL_NIGHTLY" \
    --label "$FAILURE_LABEL_CI" \
    --state open \
    --json number,body \
    --jq ".[] | select(.body | contains(\"$FAILURE_MARKER\")) | .number" \
    | head -n1
}

report_failure() {
  require_base_tools
  [ "$PUBLISH" = "true" ] || return 0
  ensure_dirs
  local number body title
  title="sccache-ng nightly failed"
  body="$WORK_DIR/failure.md"
  {
    printf '%s\n\n' "$FAILURE_MARKER"
    printf 'Nightly failed.\n\n'
    printf 'Run: %s\n' "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
  } > "$body"
  gh label create "$FAILURE_LABEL_NIGHTLY" --repo "$(gh_repo)" --force >/dev/null 2>&1 || true
  gh label create "$FAILURE_LABEL_CI" --repo "$(gh_repo)" --force >/dev/null 2>&1 || true
  number="$(failure_issue_number || true)"
  if [ -n "$number" ]; then
    gh issue comment "$number" --repo "$(gh_repo)" --body-file "$body"
  else
    gh issue create --repo "$(gh_repo)" --title "$title" --body-file "$body" --label "$FAILURE_LABEL_NIGHTLY,$FAILURE_LABEL_CI" >/dev/null
  fi
}

close_failure_issue() {
  require_base_tools
  [ "$PUBLISH" = "true" ] || return 0
  ensure_dirs
  local number body
  number="$(failure_issue_number || true)"
  [ -n "$number" ] || return 0
  body="$WORK_DIR/recovered.md"
  printf 'Nightly recovered in %s\n' "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}" > "$body"
  gh issue comment "$number" --repo "$(gh_repo)" --body-file "$body"
  gh issue close "$number" --repo "$(gh_repo)" --reason completed
}

gc_images() {
  require_base_tools
  [ "$PUBLISH" = "true" ] || return 0
  [ "$CLEANUP" = "true" ] || return 0
  local owner package cutoff protected base
  owner="$(repo_owner)"
  package="$PROJECT_NAME"
  base="/orgs/${owner}/packages/container/${package}/versions"
  gh api "$base" --paginate >/dev/null 2>&1 || base="/users/${owner}/packages/container/${package}/versions"
  cutoff="$(date -u -d "${RETENTION_DAYS} days ago" +%s)"
  protected="$(mktemp)"
  gh api "$base" --paginate \
    --jq '.[] | select(.metadata.container.tags[]? == "latest" or .metadata.container.tags[]? == "nightly") | .id' > "$protected" || true
  gh api "$base" --paginate \
    --jq '.[] | [.id, .created_at, (.metadata.container.tags | join(","))] | @tsv' \
    | sort -k2r \
    | awk -F '\t' -v keep="$RETENTION_KEEP" -v cutoff="$cutoff" -v protected="$protected" '
        BEGIN {
          while ((getline line < protected) > 0) safe[line]=1
        }
        {
          id=$1
          created=$2
          tags=$3
          cmd="date -u -d \"" created "\" +%s"
          cmd | getline ts
          close(cmd)
          if (safe[id]) next
          if (tags !~ /(^|,)[0-9a-f]{40}(,|$)/) next
          seen++
          if (seen > keep || ts < cutoff) print id
        }' \
    | while IFS= read -r id; do
        gh api -X DELETE "${base}/${id}"
      done
}

verify() {
  require_base_tools
  require_docker_tools
  selected_arches >/dev/null
  verify_action_refs
  log "verify=ok"
}

action_registry() {
  cat <<EOF
actions/checkout actions/checkout ${ACTIONS_CHECKOUT_REF} action.yml
actions/cache actions/cache ${ACTIONS_CACHE_REF} action.yml
actions/upload-artifact actions/upload-artifact ${ACTIONS_UPLOAD_ARTIFACT_REF} action.yml
actions/download-artifact actions/download-artifact ${ACTIONS_DOWNLOAD_ARTIFACT_REF} action.yml
actions/attest-build-provenance actions/attest-build-provenance ${ACTIONS_ATTEST_PROVENANCE_REF} action.yml
actions/attest-sbom actions/attest-sbom ${ACTIONS_ATTEST_SBOM_REF} action.yml
EOF
}

action_display_ref() {
  local ref="$1"
  case "$ref" in
    refs/tags/*) printf '%s\n' "${ref#refs/tags/}" ;;
    refs/heads/*) printf '%s\n' "${ref#refs/heads/}" ;;
    *) printf '%s\n' "$ref" ;;
  esac
}

action_use_ref() {
  local use_repo="$1"
  local ref="$2"
  printf '%s@%s\n' "$use_repo" "$(action_display_ref "$ref")"
}

action_latest_sha() {
  local repo="$1"
  local ref="$2"
  local tag object_type object_sha
  if [[ "$ref" == refs/tags/* ]]; then
    tag="${ref#refs/tags/}"
    object_type="$(gh api "repos/${repo}/git/ref/tags/${tag}" --jq .object.type)"
    object_sha="$(gh api "repos/${repo}/git/ref/tags/${tag}" --jq .object.sha)"
    if [ "$object_type" = "tag" ]; then
      gh api "repos/${repo}/git/tags/${object_sha}" --jq .object.sha
    else
      printf '%s\n' "$object_sha"
    fi
    return 0
  fi
  git ls-remote "https://github.com/${repo}.git" "$ref" | awk '{print $1}'
}

verify_action_runtime() {
  local repo="$1"
  local expected="$2"
  local path="$3"
  local yaml
  yaml="$(curl -fsSL "https://raw.githubusercontent.com/${repo}/${expected}/${path}")"
  if grep -q "$BANNED_ACTION_RUNTIME" <<<"$yaml"; then
    die "${repo}@${expected} uses $BANNED_ACTION_RUNTIME"
  fi
}

verify_action_refs() {
  require_cmd gh
  require_cmd curl
  local repo use_repo ref path actual unmanaged used registered expected_use
  registered="$(mktemp)"
  while read -r repo use_repo ref path; do
    expected_use="$(action_use_ref "$use_repo" "$ref")"
    printf '%s\n' "$expected_use" >> "$registered"
    actual="$(action_latest_sha "$repo" "$ref")"
    [ -n "$actual" ] || die "cannot resolve $repo $ref"
    verify_action_runtime "$repo" "$actual" "$path"
    grep -R -F "${expected_use}" "$ROOT_DIR/.github" >/dev/null || die "$expected_use pin unused"
  done < <(action_registry)
  unmanaged="$(grep -RhoE 'uses:[[:space:]]+[^[:space:]]+@[^[:space:]]+' "$ROOT_DIR/.github" \
    | awk '{print $2}' \
    | grep -v '^./' || true)"
  [ -z "$unmanaged" ] || die "unmanaged action refs: $unmanaged"
  used="$(grep -RhoE 'uses:[[:space:]]+[^[:space:]]+@[^[:space:]]+' "$ROOT_DIR/.github" \
    | awk '{print $2}' \
    | grep -v '^./' \
    | sort -u || true)"
  while IFS= read -r used_ref; do
    [ -z "$used_ref" ] && continue
    grep -qx "$used_ref" "$registered" || die "unregistered action ref: $used_ref"
  done <<<"$used"
}

replace_all() {
  local repo="$1"
  local to="$2"
  git -C "$ROOT_DIR" grep -l "${repo}@" -- .github scripts docs \
    | while IFS= read -r file; do
        perl -0pi -e "s|\\Q${repo}\\E@[^[:space:]\"']+|${to}|g" "$ROOT_DIR/$file"
      done
}

sync_action_refs() {
  require_cmd gh
  require_cmd curl
  local repo use_repo ref path actual expected_use
  while read -r repo use_repo ref path; do
    actual="$(action_latest_sha "$repo" "$ref")"
    [ -n "$actual" ] || die "cannot resolve $repo $ref"
    verify_action_runtime "$repo" "$actual" "$path"
    expected_use="$(action_use_ref "$use_repo" "$ref")"
    replace_all "$use_repo" "$expected_use"
  done < <(action_registry)
}

install_cargo_edit() {
  cargo install cargo-edit --locked
}

update_rust_deps() {
  require_rust_tools
  install_cargo_edit
  cargo upgrade --workspace --incompatible
  cargo update
}

verify_rust_deps() {
  require_rust_tools
  cargo fmt -- --check
  cargo clippy --locked --all-targets -- -D warnings -A unknown-lints -A clippy::type_complexity -A clippy::new-without-default
  cargo test --locked --lib --bins --tests
}

git_setup_bot() {
  git -C "$ROOT_DIR" config user.name "${GIT_AUTHOR_NAME:-github-actions[bot]}"
  git -C "$ROOT_DIR" config user.email "${GIT_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
}

git_has_changes() {
  ! git -C "$ROOT_DIR" diff --quiet
}

deps_stage_branch() {
  require_base_tools
  git_setup_bot
  git -C "$ROOT_DIR" fetch origin main
  git -C "$ROOT_DIR" switch -C "$DEPS_BRANCH" origin/main
}

deps_update() {
  deps_stage_branch
  sync_action_refs
  update_rust_deps
  if git_has_changes; then
    emit_output decision build
    log "decision=build"
  else
    emit_output decision noop
    log "decision=noop"
  fi
}

deps_commit_and_push() {
  [ "$PUBLISH" = "true" ] || return 0
  git_has_changes || return 0
  git -C "$ROOT_DIR" add Cargo.toml Cargo.lock scripts/ci/ci.sh .github docs/NightlyBuilds.md
  git -C "$ROOT_DIR" commit -m "ci: update centralized dependencies"
  git -C "$ROOT_DIR" push --force-with-lease origin "HEAD:refs/heads/${DEPS_BRANCH}"
  git -C "$ROOT_DIR" push origin "HEAD:refs/heads/main"
}

deps_verify_all() {
  verify_action_refs
  verify_rust_deps
}

deps_weekly() {
  deps_update
  git_has_changes || return 0
  MODE=deps-verify bash "$ROOT_DIR/scripts/ci/ci.sh"
  deps_commit_and_push
  close_failure_issue
}

usage() {
  cat <<EOF
usage: ci.sh <admission|build-builder|promote-builder|build-packages|promote|publish-release|gc|report-failure|close-failure|verify|deps-update|deps-actions-verify|deps-verify|deps-weekly>
EOF
}

main() {
  case "$MODE" in
    admission) admission ;;
    build-builder) build_builder ;;
    promote-builder) promote_builder ;;
    build-packages) build_packages ;;
    promote) promote_runtime ;;
    publish-release) publish_release ;;
    gc) gc_images ;;
    report-failure) report_failure ;;
    close-failure) close_failure_issue ;;
    verify) verify ;;
    deps-update) deps_update ;;
    deps-actions-verify) verify_action_refs ;;
    deps-verify) deps_verify_all ;;
    deps-weekly) deps_weekly ;;
    nightly|packages) build_packages ;;
    builder) build_builder ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
