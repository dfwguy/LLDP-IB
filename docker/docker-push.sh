#!/bin/bash
# LLDPq-IB Docker Registry Push Script (Phase 6 helper).
#
# Companion to docker/docker-build.sh. After a successful build, this script
# tags the local image with two registry-qualified tags (one for the current
# VERSION, one for `latest`) and pushes both to the registry the operator
# specifies via the LLDPQ_REGISTRY env var.
#
# Usage:
#   LLDPQ_REGISTRY=registry.example.com/lldpq          ./docker/docker-push.sh
#   LLDPQ_REGISTRY=registry.example.com/lldpq \
#       LLDPQ_PUSH_LATEST=false                        ./docker/docker-push.sh
#   LLDPQ_REGISTRY=docker.io/myorg ./docker/docker-push.sh
#
# Pre-requisites:
#   - docker login <registry-host>     (executed once, manually, by the operator)
#   - docker/docker-build.sh ran successfully and produced lldpq-ib:latest
#
# Safety:
#   - Refuses to push without LLDPQ_REGISTRY (so accidental runs don't push
#     to docker.io/library).
#   - Refuses to overwrite a tag whose digest is already on the registry
#     unless LLDPQ_PUSH_FORCE=true (best-effort check via `docker manifest
#     inspect` -- only meaningful when the registry supports it).
#
# Copyright (c) 2024-2026 LLDPq Project - Licensed under MIT License

set -e

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

IMAGE_NAME="lldpq-ib"
IMAGE_TAG="latest"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION=$(cat "$REPO_ROOT/VERSION" 2>/dev/null || echo "dev")

if [[ -z "${LLDPQ_REGISTRY:-}" ]]; then
    echo -e "${RED}LLDPQ_REGISTRY is not set.${NC}"
    echo "Example:"
    echo "  LLDPQ_REGISTRY=registry.example.com/lldpq $0"
    echo "  LLDPQ_REGISTRY=docker.io/myorg          $0"
    exit 1
fi

PUSH_LATEST="${LLDPQ_PUSH_LATEST:-true}"
PUSH_FORCE="${LLDPQ_PUSH_FORCE:-false}"

VERSION_REF="${LLDPQ_REGISTRY}/${IMAGE_NAME}:${VERSION}"
LATEST_REF="${LLDPQ_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"

echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   LLDPq-IB Docker Push v${VERSION}        ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
echo ""
echo -e "Registry: ${CYAN}${LLDPQ_REGISTRY}${NC}"
echo -e "Tags:     ${CYAN}${VERSION_REF}${NC}"
[[ "$PUSH_LATEST" == "true" ]] && echo -e "          ${CYAN}${LATEST_REF}${NC}"
echo ""

# ---- Sanity: local image exists ----
if ! sudo docker image inspect "${IMAGE_NAME}:${IMAGE_TAG}" >/dev/null 2>&1; then
    echo -e "${RED}Local image ${IMAGE_NAME}:${IMAGE_TAG} not found.${NC}"
    echo "Run docker/docker-build.sh first."
    exit 1
fi

# ---- Sanity: docker login ----
if ! sudo docker info 2>/dev/null | grep -qi 'username\|registry'; then
    REG_HOST="${LLDPQ_REGISTRY%%/*}"
    echo -e "${YELLOW}Warning:${NC} no detectable docker login for ${REG_HOST}."
    echo "If push fails with 'unauthorized', run:"
    echo "  docker login ${REG_HOST}"
    echo ""
fi

# ---- Optional best-effort 'already pushed' check ----
if [[ "$PUSH_FORCE" != "true" ]]; then
    if sudo docker manifest inspect "${VERSION_REF}" >/dev/null 2>&1; then
        echo -e "${YELLOW}Manifest for ${VERSION_REF} already exists on the registry.${NC}"
        echo "Re-tagging will create a new digest. Set LLDPQ_PUSH_FORCE=true to override,"
        echo "or bump the VERSION file before pushing."
        exit 1
    fi
fi

# ---- Tag ----
echo -e "${YELLOW}[1/3]${NC} Tagging..."
sudo docker tag "${IMAGE_NAME}:${IMAGE_TAG}" "${VERSION_REF}"
if [[ "$PUSH_LATEST" == "true" ]]; then
    sudo docker tag "${IMAGE_NAME}:${IMAGE_TAG}" "${LATEST_REF}"
fi
echo -e "${GREEN}  ✓ Tagged${NC}"
echo ""

# ---- Push version ----
echo -e "${YELLOW}[2/3]${NC} Pushing ${VERSION_REF}..."
sudo docker push "${VERSION_REF}"
echo -e "${GREEN}  ✓ Pushed${NC}"
echo ""

# ---- Push latest ----
if [[ "$PUSH_LATEST" == "true" ]]; then
    echo -e "${YELLOW}[3/3]${NC} Pushing ${LATEST_REF}..."
    sudo docker push "${LATEST_REF}"
    echo -e "${GREEN}  ✓ Pushed${NC}"
else
    echo -e "${YELLOW}[3/3]${NC} Skipped :latest push (LLDPQ_PUSH_LATEST=false)"
fi
echo ""

echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
echo -e "${GREEN}║    Push Complete!                    ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
echo ""
echo -e "Pull on the deployment host:"
echo -e "  ${YELLOW}docker pull ${VERSION_REF}${NC}"
[[ "$PUSH_LATEST" == "true" ]] && \
    echo -e "  ${YELLOW}docker pull ${LATEST_REF}${NC}"
