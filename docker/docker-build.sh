#!/bin/bash
# LLDPq-IB Docker Build Script
# Builds the LLDPq-IB Docker image and exports as ~/lldpq-ib.tar.gz
#
# Usage: ./docker/docker-build.sh
# Run from repo root directory, on a machine with Docker installed.
# AMD64 only -- no multi-arch build.
#
# Output: ~/lldpq-ib.tar.gz

set -e

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

IMAGE_NAME="lldpq-ib"
IMAGE_TAG="latest"
OUTPUT_FILE="$HOME/lldpq-ib.tar.gz"

# Refuse to build on non-amd64 hosts (we only ship one arch for IB)
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ;;
    *)
        echo -e "${RED}LLDPq-IB is built for amd64 only. Detected host arch: ${ARCH}${NC}"
        echo "Run this script on an amd64 build host (e.g. 'next')."
        exit 1
        ;;
esac

# Find repo root (script is in docker/ subfolder)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION=$(cat "$REPO_ROOT/VERSION" 2>/dev/null || echo "dev")

echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   LLDPq-IB Docker Build v${VERSION}       ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
echo ""

# Check Docker
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: Docker not installed${NC}"
    exit 1
fi

echo -e "${YELLOW}[1/4]${NC} Building Docker image (amd64)..."
cd "$REPO_ROOT"
sudo docker build -f docker/Dockerfile --build-arg TARGETARCH=amd64 \
    -t ${IMAGE_NAME}:${IMAGE_TAG} -t ${IMAGE_NAME}:${VERSION} . 2>&1 | tail -5
echo -e "${GREEN}  ✓ Built${NC}"
echo ""

echo -e "${YELLOW}[2/4]${NC} Image info:"
sudo docker images ${IMAGE_NAME} --format '  {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}'
echo ""

echo -e "${YELLOW}[3/4]${NC} Exporting to ${OUTPUT_FILE}..."
sudo docker save ${IMAGE_NAME}:${IMAGE_TAG} | gzip > "${OUTPUT_FILE}"
sudo chown "$(whoami):$(id -gn)" "${OUTPUT_FILE}" 2>/dev/null || true
chmod 644 "${OUTPUT_FILE}"
SIZE=$(ls -lh "${OUTPUT_FILE}" | awk '{print $5}')
echo -e "${GREEN}  ✓ Exported (${SIZE})${NC}"
echo ""

echo -e "${YELLOW}[4/4]${NC} Cleaning up old test containers..."
sudo docker rm -f lldpq-ib-test 2>/dev/null || true
echo -e "${GREEN}  ✓ Clean${NC}"
echo ""

echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
echo -e "${GREEN}║    Build Complete!                   ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
echo ""
echo -e "Image:  ${CYAN}${IMAGE_NAME}:${VERSION}${NC} (${SIZE})"
echo -e "Arch:   ${CYAN}amd64${NC}"
echo -e "File:   ${CYAN}${OUTPUT_FILE}${NC}"
echo ""
echo -e "Run:    ${YELLOW}docker run -d --network host --privileged ${IMAGE_NAME}:latest${NC}"
echo -e "Upload: ${YELLOW}scp ${OUTPUT_FILE} user@host:~/${NC}"
echo -e "Load:   ${YELLOW}docker load < lldpq-ib.tar.gz${NC}"
