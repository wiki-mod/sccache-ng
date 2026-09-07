# sccache-ng nightly builds

This repository publishes nightly sccache-ng artifacts from the read-only
upstream source repository `mozilla/sccache`.

## Outputs

Each accepted nightly build publishes:

- `ghcr.io/<owner>/sccache-ng:latest`
- `ghcr.io/<owner>/sccache-ng:nightly`
- `ghcr.io/<owner>/sccache-ng:<full upstream sha>`
- `.tar.gz` archives for `amd64` and `arm64`
- `.deb` packages for `amd64` and `arm64`
- `.apk` packages for `amd64` and `arm64`

The container is Alpine based and contains both `sccache` and `sccache-dist`.
The Debian and Alpine outputs are packages, not separate container variants.

## Sources

The upstream source of truth is `https://github.com/mozilla/sccache`.
The upstream repository is read-only for this workflow. The current repository
owns only the CI, package, image and release logic.

## Build identity

The build identity contains:

- full upstream Git SHA
- upstream `Cargo.toml` version
- current repository CI implementation SHA
- image base inputs
- Rust build flags
- target architecture

The default admission result is `NOOP`. A build starts only when the script can
prove that the requested identity is not already accepted.

## Promotion

`latest` and `nightly` are moved only after all required architecture builds
finish, packages are assembled, compile smoke tests pass, release assets are
published, and attestations are created.

If a newer build fails, the previous accepted `latest` and `nightly` remain in
place.

## Retention

Garbage collection deletes old SHA-addressed package versions after promotion.
The currently promoted `latest`, `nightly`, and their full-SHA target are never
deleted. Retention keeps at most seven old accepted builds and no build older
than fourteen days.

## Failure issue

Failed nightly runs use one issue in this repository. The issue has labels
`Nightly` and `CI-Failure`. A failing run opens the issue or appends a comment.
The next successful promoted run comments and closes it.

## Manual runs

The workflow supports `workflow_dispatch` with these controls:

- `mode`: `nightly`, `builder`, `packages`, `gc`, or `verify`
- `force`: bypass accepted-state `NOOP`
- `publish`: publish or only verify locally inside the run
- `upstream_ref`: upstream branch, tag, or SHA
- `arch`: `amd64`, `arm64`, or `all`
- `cleanup`: run garbage collection
- `debug`: enable verbose shell output

Single-architecture manual runs build and test that architecture only. They do
not promote `latest` or `nightly`, because those tags must remain multi-arch.

Workflow YAML is orchestration only. Implementation and policy live in
`scripts/ci/ci.sh`.

## Centralized dependencies

The `centralized dependencies` workflow keeps dependency inputs current without
opening pull requests. It runs on the staging branch
`ci/centralized_versions`, updates all managed inputs, runs verification, and
pushes the exact checked commit to `main` only after verification succeeds.

Managed dependency classes include:

- direct Rust dependencies in `Cargo.toml`
- resolved Rust dependencies in `Cargo.lock`
- external GitHub Action SHAs used by these workflows
- external Action runtime checks, including the Node 20 ban
- floating base images consumed by the central build script

The staging branch is not a second source of truth. It exists only so a failed
weekly update has a readable branch without moving `main`.
