#!/usr/bin/env bash
set -euo pipefail

pushd() {
  builtin pushd "$@" > /dev/null
}

popd() {
  builtin popd > /dev/null
}

pkg_json_version() {
  jq -r .version package.json
}

vscode_version() {
  jq -r .version vendor/modules/code-oss-dev/package.json
}

os() {
  local os
  os=$(uname | tr '[:upper:]' '[:lower:]')
  if [[ $os == "linux" ]]; then
    # Alpine's ldd doesn't have a version flag but if you use an invalid flag
    # (like --version) it outputs the version to stderr and exits with 1.
    local ldd_output
    ldd_output=$(ldd --version 2>&1 || true)
    if echo "$ldd_output" | grep -iq musl; then
      os="alpine"
    fi
  elif [[ $os == "darwin" ]]; then
    os="macos"
  fi
  echo "$os"
}

arch() {
  cpu="$(uname -m)"
  case "$cpu" in
    aarch64)
      echo arm64
      ;;
    x86_64 | amd64)
      echo amd64
      ;;
    *)
      echo "$cpu"
      ;;
  esac
}

# A helper function to get the artifacts url
# Takes 1 argument:
# $1 = environment {string} "staging" | "development" | "production" - which environment this is called in
# Notes:
# Grabs the most recent ci.yaml github workflow run that was triggered from the
# pull request of the release branch for this version (regardless of whether
# that run succeeded or failed). The release branch name must be in semver
# format with a v prepended.
# This will contain the artifacts we want.
# https://developer.github.com/v3/actions/workflow-runs/#list-workflow-runs
get_artifacts_url() {
  local environment="$1"
  local branch="$2"
  local artifacts_url
  local event

  case $environment in
    production)
      # This assumes you're releasing code-server using a branch named `v$VERSION` i.e. `v4.0.1`
      # If you don't, this will fail.
      branch="v$VERSION"
      event="pull_request"
      ;;
    staging)
      branch="main"
      event="push"
      ;;
    development)
      # Use $branch value passed in in this case
      event="pull_request"
      ;;
    *)
      # Assume production for default
      branch="v$VERSION"
      event="pull_request"
      ;;
  esac

  local workflow_runs_url="repos/:owner/:repo/actions/workflows/ci.yaml/runs?event=$event&branch=$branch"
  artifacts_url=$(gh api "$workflow_runs_url" | jq -r ".workflow_runs[] | select(.head_branch == \"$branch\") | .artifacts_url" | head -n 1)

  if [[ -z "$artifacts_url" ]]; then
    echo >&2 "ERROR: artifacts_url came back empty"
    echo >&2 "We looked for a successful run triggered by a pull_request with for code-server version: $VERSION and a branch named $branch"
    echo >&2 "URL used for gh API call: $workflow_runs_url"
    exit 1
  fi

  echo >&2 "Using this artifacts url: $artifacts_url"

  echo "$artifacts_url"
}

# A helper function to grab the artifact's download url
# Takes 2 arguments:
# $1 = artifact_name {string} - the name of the artifact to download (i.e. "npm-package")
# $2 = environment {string} "staging" | "development" | "production" - which environment this is called in
# $3 = branch {string} - the branch name
# See: https://developer.github.com/v3/actions/artifacts/#list-workflow-run-artifacts
get_artifact_url() {
  local artifact_name="$1"
  local environment="$2"
  local branch="$3"
  gh api "$(get_artifacts_url "$environment" "$branch")" | jq -r ".artifacts[] | select(.name == \"$artifact_name\") | .archive_download_url" | head -n 1
}

# A helper function to download the an artifact into a directory
# Takes 3 arguments:
# $1 = artifact_name {string} - the name of the artifact to download (i.e. "npm-package")
# $2 = destination {string} - where to download the artifact
# $3 = environment {string} "staging" | "development" | "production" - which environment this is called in
# $4 = branch {string} - the name of the branch to use when looking for artifacts
download_artifact() {
  local artifact_name="$1"
  local dst="$2"
  # We assume production values unless specified
  local environment="${3-production}"
  local branch="${4-v$VERSION}"
  local artifacts_url
  artifacts_url="$(get_artifact_url "$artifact_name" "$environment" "$branch")"

  echo "Inside download_artifact"
  echo "Using the following values:"
  echo "-artifact_name: $artifact_name"
  echo "-dst: $dst"
  echo "-environment: $environment"
  echo "-branch: $branch"
  echo "-artifacts_url: $artifacts_url"

  local tmp_file
  tmp_file="$(mktemp)"

  gh api "$artifacts_url" > "$tmp_file"
  unzip -q -o "$tmp_file" -d "$dst"
  rm "$tmp_file"
}

rsync() {
  command rsync -a --del "$@"
}

VERSION="$(pkg_json_version)"
export VERSION
ARCH="$(arch)"
export ARCH
OS=$(os)
export OS

# RELEASE_PATH is the destination directory for the release from the root.
# Defaults to release
RELEASE_PATH="${RELEASE_PATH-release}"

# VS Code bundles some modules into an asar which is an archive format that
# works like tar. It then seems to get unpacked into node_modules.asar.
#
# I don't know why they do this but all the dependencies they bundle already
# exist in node_modules so just symlink it. We have to do this since not only VS
# Code itself but also extensions will look specifically in this directory for
# files (like the ripgrep binary or the oniguruma wasm).
symlink_asar() {
  rm -rf node_modules.asar
  if [ "${WINDIR-}" ]; then
    # mklink takes the link name first.
    mklink /J node_modules.asar node_modules
  else
    # ln takes the link name second.
    ln -s node_modules node_modules.asar
  fi
}
