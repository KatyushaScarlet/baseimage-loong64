#!/usr/bin/env bash

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/libs/common.sh"

BUILDTAGS=""
LOONG64TAGS=""
MANIFESTTAGS=""
REGISTRIES="docker.io ghcr.io"
REPOSITORY="authelia/baseimage"
TAGS=""

if [[ "${BUILDKITE_BRANCH}" != "master" ]] && [[ ! "${BUILDKITE_BRANCH}" =~ .*:.* ]]; then
  TAGS=$(sanitize_tag "${BUILDKITE_BRANCH}")
elif [[ "${BUILDKITE_BRANCH}" != "master" ]] && [[ "${BUILDKITE_BRANCH}" =~ .*:.* ]]; then
  TAGS="PR${BUILDKITE_PULL_REQUEST}"
elif [[ "${BUILDKITE_BRANCH}" == "master" ]] && [[ "${BUILDKITE_PULL_REQUEST}" == "false" ]]; then
  TAGS="latest"
fi

[[ ${BUILDKITE_BUILD_NUMBER} != "" ]] && TAGS+=" BK${BUILDKITE_BUILD_NUMBER}"
[[ ${AUTHELIA_RELEASE} != "" ]] && TAGS+=" ${AUTHELIA_RELEASE}"

for REGISTRY in ${REGISTRIES}; do for TAG in ${TAGS}; do BUILDTAGS+="-t ${REGISTRY}/${REPOSITORY//image}:${TAG} "; done; done

# The linux/loong64 variant is assembled by Dockerfile.loong64 from the Debian archive instead of the Ubuntu archive
# the other three platforms are assembled from, so the platform is built on its own, pushed under an interim tag and
# then appended to the manifest list the build of the other platforms published.
for REGISTRY in ${REGISTRIES}; do for TAG in ${TAGS}; do LOONG64TAGS+="-t ${REGISTRY}/${REPOSITORY//image}:${TAG}-loong64 "; MANIFESTTAGS+="${REGISTRY}/${REPOSITORY//image}:${TAG} "; done; done

cat << EOF
steps:
  - label: ":docker: Build and Deploy"
    command: "docker build ${BUILDTAGS::-1} --label org.opencontainers.image.source=https://github.com/${REPOSITORY} --platform linux/amd64,linux/arm/v7,linux/arm64 --provenance mode=max,reproducible=true --sbom true --builder buildx --progress plain --pull --push ."
EOF
if [[ "${BUILDKITE_BRANCH}" == "master" ]]; then
cat << EOF
    concurrency: 1
    concurrency_group: "baseimage-deployments"
EOF
fi
cat << EOF
    agents:
      upload: "fast"
    key: "build-docker-linux"

  - label: ":docker: Build and Deploy (loong64)"
    command: "docker build ${LOONG64TAGS::-1} --file Dockerfile.loong64 --label org.opencontainers.image.source=https://github.com/${REPOSITORY} --platform linux/loong64 --provenance mode=max,reproducible=true --sbom true --builder buildx --progress plain --pull --push ."
    depends_on:
      - "build-docker-linux"
    agents:
      upload: "fast"

  - label: ":docker: Publish Manifest Lists"
    command: "for MANIFEST in ${MANIFESTTAGS}; do docker buildx imagetools create --append -t \"\${MANIFEST}\" \"\${MANIFEST}-loong64\"; done"
    depends_on:
      - "build-docker-linux-loong64"
    agents:
      upload: "fast"
    key: "publish-manifest"

  - label: ":grype: Vulnerability Scanning"
    command: "grype -f low --only-fixed registry:${REPOSITORY//image}:${TAGS%% *}"
    depends_on:
      - "publish-manifest"

  - label: ":docker: Update README.md"
    command: "curl \"https://ci.nerv.com.au/readmesync/update?github_repo=${REPOSITORY}&dockerhub_repo=${REPOSITORY//image}\""
    depends_on:
      - "publish-manifest"
    agents:
      upload: "fast"
    if: build.branch == "master"
EOF