#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="${IMAGE_NAME:-fast_livo:humble}"
CONTAINER_NAME="${CONTAINER_NAME:-fast_livo_humble}"
ROS_DOMAIN_ID_VALUE="${ROS_DOMAIN_ID:-0}"
RMW_IMPLEMENTATION_VALUE="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}"
CONTAINER_RUNTIME=()
UBUNTU_APT_MIRROR="${UBUNTU_APT_MIRROR:-}"
ROS_APT_MIRROR="${ROS_APT_MIRROR:-}"
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
DOCKER_REGISTRY_MIRRORS="${DOCKER_REGISTRY_MIRRORS:-https://docker.m.daocloud.io,https://mirror.baidubce.com,https://docker.mirrors.ustc.edu.cn,https://hub-mirror.c.163.com}"
LOG_DIR="${SCRIPT_DIR}/tmp"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/start_fast_livo_$(date +%Y%m%d_%H%M%S).log}"
GC_ENABLE="${GC_ENABLE:-true}"
GC_LOG_RETENTION_DAYS="${GC_LOG_RETENTION_DAYS:-14}"
GC_LOG_KEEP_COUNT="${GC_LOG_KEEP_COUNT:-30}"
GC_DOCKER_PRUNE="${GC_DOCKER_PRUNE:-true}"
GC_DISK_THRESHOLD_PERCENT="${GC_DISK_THRESHOLD_PERCENT:-80}"
GC_ROS_EMPTY_LOGS="${GC_ROS_EMPTY_LOGS:-true}"
PULL_TIMEOUT_SEC="${PULL_TIMEOUT_SEC:-120}"
FORCE_BUILD="${FORCE_BUILD:-false}"mv buildx-v0.15.0.linux-amd64 ~/.docker/cli-plugins/docker-buildx
ALL_TARGET_PLATFORMS="${ALL_TARGET_PLATFORMS:-linux/amd64,linux/arm64}"

usage() {
  cat <<'EOF'
Usage:
  ./start_fast_livo_docker.sh [build|buildall|build-all|run|shell|stop|logs|gc|rebuild] [--rebuild|-r] [--gc|--no-gc]

Actions:
  build  Build the Docker image only.
  buildall, build-all  Build all target platforms and push to registry, then publish multi-arch manifest.
  run    Build if needed, then start the container and execute /workspace/run.sh.
  shell  Build if needed, then open an interactive shell inside the container.
  rebuild Force rebuild the Docker image only.
  stop   Stop and remove the named container if it exists.
  logs   Follow the named container logs.
  gc     Run garbage collection only.

Flags:
  --rebuild, -r  Force rebuild image before run/shell/build flow.
  --gc           Force run GC before selected action.
  --no-gc        Skip GC for current invocation.

Environment overrides:
  IMAGE_NAME, CONTAINER_NAME, ROS_DOMAIN_ID, RMW_IMPLEMENTATION, UBUNTU_APT_MIRROR, ROS_APT_MIRROR, BASE_IMAGE, BASE_IMAGE_CANDIDATES, DOCKER_REGISTRY_MIRRORS,
  GC_ENABLE, GC_LOG_RETENTION_DAYS, GC_LOG_KEEP_COUNT, GC_DOCKER_PRUNE, GC_DISK_THRESHOLD_PERCENT, GC_ROS_EMPTY_LOGS,
  TARGET_PLATFORM, USE_BUILDX, ALL_TARGET_PLATFORMS, PULL_TIMEOUT_SEC, FORCE_BUILD
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

current_disk_usage_percent() {
  df -P "${SCRIPT_DIR}" | awk 'NR==2 {gsub("%", "", $5); print $5}'
}

gc_logs() {
  local patterns=(
    "${LOG_DIR}/start_fast_livo_*.log"
    "${LOG_DIR}/start_fast_livo_mirror_*.log"
    "${LOG_DIR}/fast_livo_*.log"
  )

  log "GC: 开始清理日志文件"

  if [ "${GC_LOG_RETENTION_DAYS}" -ge 0 ] 2>/dev/null; then
    find "${LOG_DIR}" -maxdepth 1 -type f \( -name 'start_fast_livo_*.log' -o -name 'start_fast_livo_mirror_*.log' -o -name 'fast_livo_*.log' \) \
      -mtime "+${GC_LOG_RETENTION_DAYS}" -print -delete || true
  fi

  if [ "${GC_LOG_KEEP_COUNT}" -gt 0 ] 2>/dev/null; then
    local all_logs
    all_logs="$(find "${LOG_DIR}" -maxdepth 1 -type f \( -name 'start_fast_livo_*.log' -o -name 'start_fast_livo_mirror_*.log' -o -name 'fast_livo_*.log' \) -printf '%T@ %p\n' | sort -nr | awk '{print $2}')"
    if [ -n "${all_logs}" ]; then
      printf '%s\n' "${all_logs}" | awk "NR>${GC_LOG_KEEP_COUNT}" | while IFS= read -r f; do
        [ -n "${f}" ] || continue
        [ "${f}" = "${LOG_FILE}" ] && continue
        rm -f "${f}" || true
      done
    fi
  fi

  if [ "${GC_ROS_EMPTY_LOGS}" = "true" ] && [ -d "${LOG_DIR}/ros_logs" ]; then
    log "GC: 清理 ROS 空日志文件"
    find "${LOG_DIR}/ros_logs" -type f -size 0c -print -delete || true
    find "${LOG_DIR}/ros_logs" -type d -empty -delete || true
  fi

  log "GC: 日志清理完成"
}

gc_container_cache() {
  if [ "${GC_DOCKER_PRUNE}" != "true" ]; then
    log "GC: 已禁用容器缓存清理"
    return
  fi

  local usage
  usage="$(current_disk_usage_percent)"
  log "GC: 当前磁盘占用 ${usage}% (阈值 ${GC_DISK_THRESHOLD_PERCENT}%)"

  if [ "${usage}" -lt "${GC_DISK_THRESHOLD_PERCENT}" ]; then
    log "GC: 未达到阈值，跳过容器缓存清理"
    return
  fi

  log "GC: 达到阈值，开始容器缓存清理"

  if [ "${CONTAINER_RUNTIME[${#CONTAINER_RUNTIME[@]}-1]}" = "docker" ]; then
    "${CONTAINER_RUNTIME[@]}" container prune -f || true
    # Keep tagged base images (e.g., ROS) by pruning dangling images only.
    "${CONTAINER_RUNTIME[@]}" image prune -af || true
    "${CONTAINER_RUNTIME[@]}" builder prune -af || true
    "${CONTAINER_RUNTIME[@]}" volume prune -f || true
  else
    "${CONTAINER_RUNTIME[@]}" container prune -f || true
    # Keep tagged base images (e.g., ROS) by pruning dangling images only.
    "${CONTAINER_RUNTIME[@]}" image prune -af || true
    "${CONTAINER_RUNTIME[@]}" volume prune -f || true
  fi

  usage="$(current_disk_usage_percent)"
  log "GC: 清理后磁盘占用 ${usage}%"
}

run_gc() {
  if [ "${GC_ENABLE}" != "true" ]; then
    log "GC: 已禁用"
    return
  fi

  gc_logs
  gc_container_cache
}

candidate_base_images() {
  if [ -n "${BASE_IMAGE_CANDIDATES}" ]; then
    printf '%s\n' "${BASE_IMAGE_CANDIDATES}" | tr ',' '\n' | sed '/^[[:space:]]*$/d'
    return
  fi

  printf '%s\n' "${BASE_IMAGE}"

  local mirror
  local IFS=','
  for mirror in ${DOCKER_REGISTRY_MIRRORS}; do
    mirror="$(printf '%s' "${mirror}" | sed -e 's#^https://##' -e 's#^http://##' -e 's#/*$##')"
    if [ -n "${mirror}" ]; then
      printf '%s\n' "${mirror}/${BASE_IMAGE_DEFAULT}"
    fi
  done
}

resolve_base_image() {
  local candidate
  while IFS= read -r candidate; do
    [ -n "${candidate}" ] || continue
    log "试探基础镜像: ${candidate}" >&2

    local rc=0
    if command -v timeout >/dev/null 2>&1 && [ "${PULL_TIMEOUT_SEC}" -gt 0 ] 2>/dev/null; then
      timeout "${PULL_TIMEOUT_SEC}" "${CONTAINER_RUNTIME[@]}" pull "${candidate}" >/dev/null
      rc=$?
    else
      "${CONTAINER_RUNTIME[@]}" pull "${candidate}" >/dev/null
      rc=$?
    fi

    if [ "${rc}" -eq 0 ]; then
      log "基础镜像可用: ${candidate}" >&2
      echo "${candidate}"
      return 0
    elif [ "${rc}" -eq 124 ]; then
      log "基础镜像拉取超时(${PULL_TIMEOUT_SEC}s): ${candidate}" >&2
    else
      log "基础镜像不可用(rc=${rc}): ${candidate}" >&2
    fi
  done < <(candidate_base_images)

  return 1
}

ensure_runtime() {
  if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
      CONTAINER_RUNTIME=(docker)
      return
    fi

    if command -v sudo >/dev/null 2>&1; then
      # First try passwordless sudo to avoid hidden prompt hangs.
      if sudo -n docker info >/dev/null 2>&1; then
        CONTAINER_RUNTIME=(sudo -n docker)
        return
      fi

      log "检测到需要 sudo 权限访问 Docker，正在请求授权..."
      if sudo -v; then
        CONTAINER_RUNTIME=(sudo docker)
        return
      fi

      cat >&2 <<'EOF'
[ERROR] sudo 授权失败，无法访问 Docker。
请重新运行并输入正确密码，或把当前用户加入 docker 组。
EOF
      exit 1
      return
    fi

    cat >&2 <<'EOF'
[ERROR] docker is installed, but the current user cannot access /var/run/docker.sock.
Add your user to the docker group, or rerun this script with sudo.

Examples:
  sudo usermod -aG docker $USER
  newgrp docker

Or:
  sudo ./start_fast_livo_docker.sh run
EOF
    exit 1
  fi

  if command -v podman >/dev/null 2>&1; then
    CONTAINER_RUNTIME=(podman)
    return
  fi

  cat >&2 <<'EOF'
[ERROR] Neither docker nor podman is installed or available in PATH.
Install one of them and rerun this script.

Ubuntu/Debian examples:
  sudo apt update
  sudo apt install docker.io

Or with Podman:
  sudo apt update
  sudo apt install podman
EOF
  exit 1
}

build_image() {
  local build_args=()
  local resolved_base_image=""
  local use_buildx="false"

  log "开始准备镜像构建"
  log "日志文件: ${LOG_FILE}"
  log "工作目录: ${SCRIPT_DIR}"
  log "环境变量: IMAGE_NAME=${IMAGE_NAME}, BASE_IMAGE=${BASE_IMAGE}, ROS_DOMAIN_ID=${ROS_DOMAIN_ID_VALUE}, RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION_VALUE}"
  log "构建平台: HOST_PLATFORM=${HOST_PLATFORM}, TARGET_PLATFORM=${TARGET_PLATFORM}, USE_BUILDX=${USE_BUILDX}"
  log "APT 镜像: UBUNTU_APT_MIRROR=${UBUNTU_APT_MIRROR:-<empty>}, ROS_APT_MIRROR=${ROS_APT_MIRROR:-<empty>}"

  resolved_base_image="$(resolve_base_image)" || {
    cat >&2 <<EOF
[ERROR] Unable to pull any candidate base image.
Tried: $(candidate_base_images | tr '\n' ' ')
EOF
    exit 1
  }

  build_args+=(--build-arg "BASE_IMAGE=${resolved_base_image}")

  if [ -n "${UBUNTU_APT_MIRROR}" ]; then
    build_args+=(--build-arg "UBUNTU_APT_MIRROR=${UBUNTU_APT_MIRROR}")
  fi

  if [ -n "${ROS_APT_MIRROR}" ]; then
    build_args+=(--build-arg "ROS_APT_MIRROR=${ROS_APT_MIRROR}")
  fi

  if [ "${TARGET_PLATFORM}" != "${HOST_PLATFORM}" ]; then
    log "检测到跨架构构建: ${HOST_PLATFORM} -> ${TARGET_PLATFORM}"
  fi

  if [ "${CONTAINER_RUNTIME[${#CONTAINER_RUNTIME[@]}-1]}" = "docker" ]; then
    case "${USE_BUILDX}" in
      true)
        use_buildx="true"
        ;;
      auto)
        if [ "${TARGET_PLATFORM}" != "${HOST_PLATFORM}" ]; then
          use_buildx="true"
        fi
        ;;
      false)
        use_buildx="false"
        ;;
      *)
        log "[WARN] USE_BUILDX=${USE_BUILDX} 非法，回退到 auto"
        if [ "${TARGET_PLATFORM}" != "${HOST_PLATFORM}" ]; then
          use_buildx="true"
        fi
        ;;
    esac
  fi

  log "开始 Docker 构建: ${IMAGE_NAME}"
  if [ "${use_buildx}" = "true" ]; then
    if ! "${CONTAINER_RUNTIME[@]}" buildx version >/dev/null 2>&1; then
      cat >&2 <<'EOF'
[ERROR] 当前 Docker 环境不可用 buildx，无法跨架构构建。
请安装/启用 docker buildx，或设置 USE_BUILDX=false 走普通构建。
EOF
      exit 1
    fi

    DOCKER_BUILDKIT=1 BUILDKIT_PROGRESS=plain "${CONTAINER_RUNTIME[@]}" buildx build \
      --platform "${TARGET_PLATFORM}" \
      --load \
      "${build_args[@]}" \
      -f "${SCRIPT_DIR}/Dockerfile.fast_livo" \
      -t "${IMAGE_NAME}" \
      "${SCRIPT_DIR}"
  else
    DOCKER_BUILDKIT=1 BUILDKIT_PROGRESS=plain "${CONTAINER_RUNTIME[@]}" build \
      --platform "${TARGET_PLATFORM}" \
      "${build_args[@]}" \
      -f "${SCRIPT_DIR}/Dockerfile.fast_livo" \
      -t "${IMAGE_NAME}" \
      "${SCRIPT_DIR}"
  fi
}

default_base_image_for_arch() {
  case "$1" in
    amd64)
      printf '%s\n' "osrf/ros:humble-desktop"
      ;;
    arm64)
      printf '%s\n' "arm64v8/ros:humble-ros-base"
      ;;
    *)
      printf '%s\n' "osrf/ros:humble-desktop"
      ;;
  esac
}

image_with_arch_suffix() {
  local image="$1"
  local arch="$2"
  local repo="$image"
  local tag="latest"
  if [ "${image##*/}" != "${image##*:}" ]; then
    repo="${image%:*}"
    tag="${image##*:}"
  fi
  printf '%s:%s-%s\n' "${repo}" "${tag}" "${arch}"
}

build_all_and_push() {
  if [ "${CONTAINER_RUNTIME[${#CONTAINER_RUNTIME[@]}-1]}" != "docker" ]; then
    cat >&2 <<'EOF'
[ERROR] buildall 目前仅支持 Docker runtime。
EOF
    exit 1
  fi

  if ! "${CONTAINER_RUNTIME[@]}" buildx version >/dev/null 2>&1; then
    cat >&2 <<'EOF'
[ERROR] 当前 Docker 环境不可用 buildx，无法执行 buildall。
请安装/启用 docker buildx 后重试。
EOF
    exit 1
  fi

  local platforms_csv="${ALL_TARGET_PLATFORMS}"
  local old_image_name="${IMAGE_NAME}"
  local old_target_platform="${TARGET_PLATFORM}"
  local old_base_image="${BASE_IMAGE}"
  local old_use_buildx="${USE_BUILDX}"
  local old_force_build="${FORCE_BUILD}"
  local tag_images=()

  IFS=',' read -r -a target_platforms <<< "${platforms_csv}"
  if [ "${#target_platforms[@]}" -eq 0 ]; then
    echo "[ERROR] ALL_TARGET_PLATFORMS 不能为空" >&2
    exit 1
  fi

  log "buildall: 目标平台=${platforms_csv}"

  local platform
  for platform in "${target_platforms[@]}"; do
    platform="$(printf '%s' "${platform}" | xargs)"
    [ -n "${platform}" ] || continue
    local arch="${platform##*/}"
    local arch_image
    arch_image="$(image_with_arch_suffix "${old_image_name}" "${arch}")"

    IMAGE_NAME="${arch_image}"
    TARGET_PLATFORM="${platform}"
    USE_BUILDX="true"
    FORCE_BUILD="true"
    BASE_IMAGE="$(default_base_image_for_arch "${arch}")"

    log "buildall: 开始构建 ${platform} -> ${IMAGE_NAME}, BASE_IMAGE=${BASE_IMAGE}"
    build_image

    log "buildall: 推送镜像 ${IMAGE_NAME}"
    "${CONTAINER_RUNTIME[@]}" push "${IMAGE_NAME}"
    tag_images+=("${IMAGE_NAME}")
  done

  IMAGE_NAME="${old_image_name}"
  TARGET_PLATFORM="${old_target_platform}"
  BASE_IMAGE="${old_base_image}"
  USE_BUILDX="${old_use_buildx}"
  FORCE_BUILD="${old_force_build}"

  log "buildall: 发布多架构清单 ${old_image_name}"
  "${CONTAINER_RUNTIME[@]}" buildx imagetools create -t "${old_image_name}" "${tag_images[@]}"
  log "buildall: 完成并已上传 ${old_image_name}"
}

image_exists() {
  "${CONTAINER_RUNTIME[@]}" image inspect "${IMAGE_NAME}" >/dev/null 2>&1
}

ensure_image_ready() {
  if [ "${FORCE_BUILD}" = "true" ]; then
    log "FORCE_BUILD=true，强制重建镜像"
    build_image
    return
  fi

  if image_exists; then
    log "检测到本地镜像已存在，复用镜像并跳过构建: ${IMAGE_NAME}"
    return
  fi

  log "本地未找到镜像，开始构建: ${IMAGE_NAME}"
  build_image
}

check_realsense_host() {
  if ! command -v lsusb >/dev/null 2>&1; then
    log "[WARN] 未找到 lsusb，跳过 RealSense 宿主机探测"
    return
  fi

  if lsusb | grep -qiE 'intel.*realsense|8086:'; then
    log "RealSense 宿主机探测: 已检测到 Intel USB 设备(含 RealSense 候选)"
  else
    log "[WARN] RealSense 宿主机探测: 未发现 Intel RealSense 设备，请检查 D435i 连接与供电"
  fi
}

run_container() {
  mkdir -p "${SCRIPT_DIR}/tmp"
  mkdir -p "${SCRIPT_DIR}/tmp/ros_logs"
  mkdir -p "${SCRIPT_DIR}/PCD"

  if "${CONTAINER_RUNTIME[@]}" container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    log "检测到同名容器已存在，先清理: ${CONTAINER_NAME}"
    "${CONTAINER_RUNTIME[@]}" rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  fi

  check_realsense_host

  log "准备启动容器: ${CONTAINER_NAME}"
  log "容器运行时: ${CONTAINER_RUNTIME[*]}"
  log "镜像: ${IMAGE_NAME}"
  log "ROS_DOMAIN_ID=${ROS_DOMAIN_ID_VALUE}, RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION_VALUE}"

  local docker_args=(
    run
    --name "${CONTAINER_NAME}"
    --rm
    --network host
    --ipc host
    --privileged
    -e DISPLAY="${DISPLAY:-}"
    -e QT_X11_NO_MITSHM=1
    -e ROS_DOMAIN_ID="${ROS_DOMAIN_ID_VALUE}"
    -e ROS_LOCALHOST_ONLY=0
    -e ROS_LOG_DIR=/workspace/ros_logs
    -e RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION_VALUE}"
    -e CYCLONEDDS_URI=file:///opt/fast_livo/cyclonedds.xml
    -e MID360_HOST_IP="${MID360_HOST_IP:-192.168.1.50}"
    -e MID360_LIDAR_IP="${MID360_LIDAR_IP:-}"
    -v /tmp/.X11-unix:/tmp/.X11-unix:rw
    -v /run/udev:/run/udev:ro
    -v /dev:/dev
    -v /dev/bus/usb:/dev/bus/usb
    -v "${SCRIPT_DIR}/run.sh:/workspace/run.sh:ro"
    -v "${SCRIPT_DIR}/Fast_Livo/src/FASTLIVO2_ROS2/launch/mapping_avia.launch.py:/workspace/Fast_Livo/install/fast_livo/share/fast_livo/launch/mapping_avia.launch.py:ro"
    -v "${SCRIPT_DIR}/Fast_Livo/src/FASTLIVO2_ROS2/launch/mapping_avia_marslvig.launch.py:/workspace/Fast_Livo/install/fast_livo/share/fast_livo/launch/mapping_avia_marslvig.launch.py:ro"
    -v "${SCRIPT_DIR}/tmp/ros_logs:/workspace/ros_logs"
    -v "${SCRIPT_DIR}/tmp:/workspace/tmp"
    -v "${SCRIPT_DIR}/PCD:/workspace/Fast_Livo/src/FASTLIVO2_ROS2/Log/PCD"
    -w /workspace
    "${IMAGE_NAME}"
  )

  if [ "${1:-run}" = "shell" ]; then
    docker_args+=(/bin/bash)
  else
    docker_args+=(/bin/bash -lc /workspace/run.sh)
  fi

  exec "${CONTAINER_RUNTIME[@]}" "${docker_args[@]}"
}

stop_container() {
  "${CONTAINER_RUNTIME[@]}" rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
}

follow_logs() {
  "${CONTAINER_RUNTIME[@]}" logs -f "${CONTAINER_NAME}"
}

main() {
  ensure_runtime
  prepare_logging

  log "脚本启动"
  log "运行日志: ${LOG_FILE}"
  log "宿主机架构: ${HOST_ARCH}"
  log "宿主机平台: ${HOST_PLATFORM}"
  log "目标平台: ${TARGET_PLATFORM}"
  log "架构默认基础镜像: ${BASE_IMAGE_DEFAULT}"
  log "基础镜像默认值: ${BASE_IMAGE}"
  log "GC 配置: GC_ENABLE=${GC_ENABLE}, GC_LOG_RETENTION_DAYS=${GC_LOG_RETENTION_DAYS}, GC_LOG_KEEP_COUNT=${GC_LOG_KEEP_COUNT}, GC_DOCKER_PRUNE=${GC_DOCKER_PRUNE}, GC_DISK_THRESHOLD_PERCENT=${GC_DISK_THRESHOLD_PERCENT}"
  log "ROS 日志清理: GC_ROS_EMPTY_LOGS=${GC_ROS_EMPTY_LOGS}"
  log "拉取超时设置: PULL_TIMEOUT_SEC=${PULL_TIMEOUT_SEC}"
  log "镜像复用设置: FORCE_BUILD=${FORCE_BUILD}"

  local action="run"
  local should_run_gc="auto"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      build|buildall|build-all|run|shell|stop|logs|gc|rebuild)
        action="$1"
        ;;
      --rebuild|-r)
        FORCE_BUILD=true
        ;;
      -gc|--run-gc)
        should_run_gc="true"
        ;;
      --no-gc)
        should_run_gc="false"
        ;;
      -h|--help|help)
        usage
        return 0
        ;;
      *)
        echo "[ERROR] Unknown action or flag: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
    shift
  done

  if [ "${should_run_gc}" = "true" ]; then
    log "GC 选择: 强制执行"
    run_gc
  elif [ "${should_run_gc}" = "false" ]; then
    log "GC 选择: 跳过本次 GC"
  elif [ "${action}" != "gc" ]; then
    run_gc
  fi

  case "${action}" in
    build)
      log "执行 build 动作"
      ensure_image_ready
      ;;
    buildall|build-all)
      log "执行 buildall 动作"
      build_all_and_push
      ;;
    run)
      log "执行 run 动作"
      ensure_image_ready
      run_container run
      ;;
    shell)
      log "执行 shell 动作"
      ensure_image_ready
      run_container shell
      ;;
    stop)
      log "执行 stop 动作"
      stop_container
      ;;
    logs)
      log "执行 logs 动作"
      follow_logs
      ;;
    gc)
      log "执行 gc 动作"
      run_gc
      ;;
    rebuild)
      log "执行 rebuild 动作"
      FORCE_BUILD=true
      ensure_image_ready
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      echo "[ERROR] Unknown action: ${action}" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
