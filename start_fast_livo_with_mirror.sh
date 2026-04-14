#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
START_SCRIPT="${SCRIPT_DIR}/start_fast_livo_docker.sh"

DOCKER_REGISTRY_MIRRORS="${DOCKER_REGISTRY_MIRRORS:-https://docker.m.daocloud.io,https://docker.mirrors.ustc.edu.cn}"
UBUNTU_APT_MIRROR="${UBUNTU_APT_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/ubuntu/}"
ROS_APT_MIRROR="${ROS_APT_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/ros2/ubuntu/}"
HOST_ARCH="$(uname -m 2>/dev/null || echo unknown)"
case "${HOST_ARCH}" in
  x86_64|amd64)
    HOST_PLATFORM="linux/amd64"
    ;;
  aarch64|arm64)
    HOST_PLATFORM="linux/arm64"
    ;;
  *)
    HOST_PLATFORM="linux/amd64"
    ;;
esac
TARGET_PLATFORM="${TARGET_PLATFORM:-${HOST_PLATFORM}}"
TARGET_ARCH="${TARGET_PLATFORM##*/}"
case "${TARGET_ARCH}" in
  amd64)
    BASE_IMAGE_DEFAULT="osrf/ros:humble-desktop"
    ;;
  arm64)
    BASE_IMAGE_DEFAULT="arm64v8/ros:humble-ros-base"
    ;;
  *)
    BASE_IMAGE_DEFAULT="osrf/ros:humble-desktop"
    ;;
esac
BASE_IMAGE="${BASE_IMAGE:-${BASE_IMAGE_DEFAULT}}"
BASE_IMAGE_CANDIDATES="${BASE_IMAGE_CANDIDATES:-}"
USE_BUILDX="${USE_BUILDX:-auto}"
LOG_DIR="${SCRIPT_DIR}/tmp"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/start_fast_livo_mirror_$(date +%Y%m%d_%H%M%S).log}"

usage() {
  cat <<'EOF'
Usage:
  ./start_fast_livo_with_mirror.sh [run|build|buildall|build-all|shell|stop|logs]

This script configures Docker registry mirrors first, then delegates to
start_fast_livo_docker.sh.

Environment overrides:
  DOCKER_REGISTRY_MIRRORS
  UBUNTU_APT_MIRROR
  ROS_APT_MIRROR
  BASE_IMAGE
  BASE_IMAGE_CANDIDATES
  TARGET_PLATFORM
  USE_BUILDX
EOF
}

log() {
  printf '[%s] %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$*"
}

prepare_logging() {
  mkdir -p "${LOG_DIR}"
  touch "${LOG_FILE}"
  exec > >(tee -a "${LOG_FILE}") 2>&1
}

configure_docker_mirror() {
  if ! command -v docker >/dev/null 2>&1; then
    log "docker not found; skipping Docker daemon mirror configuration."
    return
  fi

  local json_path="/etc/docker/daemon.json"
  local backup_path="/etc/docker/daemon.json.bak.$(date +%Y%m%d_%H%M%S)"

  log "检查 Docker registry mirror 配置"
  log "镜像源列表: ${DOCKER_REGISTRY_MIRRORS}"

  if [ "$(id -u)" -ne 0 ] && [ ! -w "$(dirname "${json_path}")" ] && ! command -v sudo >/dev/null 2>&1; then
    log "no permission to update ${json_path} and sudo is unavailable; skipping Docker mirror config."
    return
  fi

  local python_runner=(python3)
  if [ "$(id -u)" -ne 0 ] && [ ! -w "${json_path}" ] 2>/dev/null; then
    python_runner=(sudo python3)
  fi

  "${python_runner[@]}" - "${json_path}" "${backup_path}" "${DOCKER_REGISTRY_MIRRORS}" <<'PY'
import json
import pathlib
import shutil
import sys

json_path = pathlib.Path(sys.argv[1])
backup_path = pathlib.Path(sys.argv[2])
mirrors = [item.strip() for item in sys.argv[3].split(",") if item.strip()]

data = {}
if json_path.exists():
    try:
        data = json.loads(json_path.read_text())
    except Exception:
        data = {}
    shutil.copy2(json_path, backup_path)

data["registry-mirrors"] = mirrors
json_path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
PY

  if [ "$(id -u)" -eq 0 ]; then
    if command -v systemctl >/dev/null 2>&1; then
      if systemctl is-active docker >/dev/null 2>&1; then
        systemctl restart docker
      else
        systemctl start docker
      fi
    elif command -v service >/dev/null 2>&1; then
      service docker restart || service docker start
    fi
  else
    if command -v systemctl >/dev/null 2>&1; then
      sudo systemctl restart docker
    elif command -v service >/dev/null 2>&1; then
      sudo service docker restart || sudo service docker start
    fi
  fi

  log "Docker registry mirror 配置完成"
}

main() {
  prepare_logging

  log "脚本启动"
  log "运行日志: ${LOG_FILE}"
  log "宿主机架构: ${HOST_ARCH}"
  log "宿主机平台: ${HOST_PLATFORM}"
  log "目标平台: ${TARGET_PLATFORM}"
  log "架构默认基础镜像: ${BASE_IMAGE_DEFAULT}"
  log "基础镜像默认值: ${BASE_IMAGE}"
  log "基础镜像候选: ${BASE_IMAGE_CANDIDATES:-<auto>}"

  case "${1:-run}" in
    -h|--help|help)
      usage
      exit 0
      ;;
  esac

  configure_docker_mirror
  log "准备把镜像源参数传递给构建脚本"
  export BASE_IMAGE
  export BASE_IMAGE_CANDIDATES
  export DOCKER_REGISTRY_MIRRORS
  export UBUNTU_APT_MIRROR
  export ROS_APT_MIRROR
  export TARGET_PLATFORM
  export USE_BUILDX
  exec "${START_SCRIPT}" "$@"
}

main "$@"
