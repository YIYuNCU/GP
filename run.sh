#!/bin/sh

if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

set -euo pipefail

source_ros_setup() {
  set +u
  source "$1"
  set -u
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_ROOT="$(cd "${SCRIPT_DIR}/Fast_Livo" && pwd)"

ROS_SETUP="/opt/ros/humble/setup.bash"
LIVOX_WS_SETUP="${SCRIPT_DIR}/ws_livox/install/setup.bash"
WS_SETUP="${WS_ROOT}/install/setup.bash"
LOG_DIR="${SCRIPT_DIR}/tmp"
BAG_DIR="${BAG_DIR:-${LOG_DIR}/sync_bag_$(date +%Y%m%d_%H%M%S)}"

if [ ! -f "${ROS_SETUP}" ]; then
  echo "[ERROR] 找不到 ROS2 Humble 环境: ${ROS_SETUP}" >&2
  exit 1
fi

if [ ! -f "${WS_SETUP}" ]; then
  echo "[ERROR] 找不到工作空间 overlay: ${WS_SETUP}" >&2
  echo "请先在 ${WS_ROOT} 执行 colcon build" >&2
  exit 1
fi

source_ros_setup "${ROS_SETUP}"
if [ -f "${LIVOX_WS_SETUP}" ]; then
  source_ros_setup "${LIVOX_WS_SETUP}"
fi
source_ros_setup "${WS_SETUP}"

mkdir -p "${LOG_DIR}"

REALSENSE_LAUNCH="${REALSENSE_LAUNCH:-rs_launch.py}"
LIVOX_PACKAGE="${LIVOX_PACKAGE:-livox_ros_driver2}"
LIVOX_LAUNCH="${LIVOX_LAUNCH:-launch_ROS2/msg_MID360_launch.py}"
SYNC_LAUNCH_PACKAGE="${SYNC_LAUNCH_PACKAGE:-realsense_mid360_sync}"
SYNC_LAUNCH_FILE="${SYNC_LAUNCH_FILE:-realsense_mid360_sync.launch.py}"
FASTLIVO_PACKAGE="${FASTLIVO_PACKAGE:-fast_livo}"
FASTLIVO_LAUNCH_FILE="${FASTLIVO_LAUNCH_FILE:-mapping_avia.launch.py}"
FASTLIVO_SAVE_WAIT_SEC="${FASTLIVO_SAVE_WAIT_SEC:-20}"
FASTLIVO_USE_RVIZ="${FASTLIVO_USE_RVIZ:-false}"
MID360_LIDAR_IP="${MID360_LIDAR_IP:-192.168.1.154}"
MID360_HOST_IP="${MID360_HOST_IP:-}"
MID360_CONFIG_FILE="${MID360_CONFIG_FILE:-${WS_ROOT}/src/livox_ros_driver2/config/MID360_config.json}"

detect_host_ip_for_lidar() {
  local lidar_ip="$1"
  if ! command -v ip >/dev/null 2>&1; then
    echo "[WARN] 未找到 ip 命令，跳过自动探测主机IP；请设置 MID360_HOST_IP" >&2
    return 0
  fi

  ip route get "${lidar_ip}" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true
}

prepare_mid360_network_config() {
  if [ ! -f "${MID360_CONFIG_FILE}" ]; then
    echo "[WARN] 未找到 MID360 配置文件，跳过主机网络预配置: ${MID360_CONFIG_FILE}"
    return
  fi

  local host_ip="${MID360_HOST_IP}"
  if [ -z "${host_ip}" ]; then
    host_ip="$(detect_host_ip_for_lidar "${MID360_LIDAR_IP}")"
  fi

  if [ -z "${host_ip}" ]; then
    echo "[WARN] 无法自动推断与 ${MID360_LIDAR_IP} 通信的主机IP，请设置 MID360_HOST_IP 后重试"
    return
  fi

  echo "[INFO] MID360 连接配置: lidar_ip=${MID360_LIDAR_IP}, host_ip=${host_ip}"
  # Only update local host_net_info used by livox driver. No MID360 device-side settings are modified.
  python3 - <<'PY' "${MID360_CONFIG_FILE}" "${host_ip}"
import json
import sys
from pathlib import Path

cfg_path = Path(sys.argv[1])
host_ip = sys.argv[2]
data = json.loads(cfg_path.read_text())
host = data.setdefault("MID360", {}).setdefault("host_net_info", {})
for k in ("cmd_data_ip", "push_msg_ip", "point_data_ip", "imu_data_ip"):
    host[k] = host_ip
cfg_path.write_text(json.dumps(data, indent=2) + "\n")
PY
}

prepare_mid360_network_config

prepare_livox_library_path() {
  local candidates=(
    "/usr/local/lib"
    "/usr/local/lib64"
    "${SCRIPT_DIR}/livox_SDK/Livox-SDK2/build/sdk_core"
    "${SCRIPT_DIR}/livox_SDK/Livox-SDK2/build/sdk_core/lib"
  )

  local found=""
  local path
  for path in "${candidates[@]}"; do
    if [ -f "${path}/liblivox_lidar_sdk_shared.so" ]; then
      found="${path}"
      break
    fi
  done

  if [ -z "${found}" ]; then
    echo "[WARN] 未找到 liblivox_lidar_sdk_shared.so，Livox 驱动可能启动失败" >&2
    return
  fi

  if [ -n "${LD_LIBRARY_PATH:-}" ]; then
    export LD_LIBRARY_PATH="${found}:${LD_LIBRARY_PATH}"
  else
    export LD_LIBRARY_PATH="${found}"
  fi

  echo "[INFO] Livox SDK 动态库路径: ${found}"
}

prepare_livox_library_path

cleanup_ran=0

cleanup() {
  if [ "${cleanup_ran}" -eq 1 ]; then
    return
  fi
  cleanup_ran=1

  if [ -n "${FASTLIVO_PID:-}" ] && kill -0 "${FASTLIVO_PID}" 2>/dev/null; then
    echo "[INFO] 先通知 FastLivo 退出并保留 ${FASTLIVO_SAVE_WAIT_SEC}s 保存时间..."
    kill -INT "${FASTLIVO_PID}" 2>/dev/null || true
    sleep "${FASTLIVO_SAVE_WAIT_SEC}"
  fi

  if [ -n "${BAG_PID:-}" ] && kill -0 "${BAG_PID}" 2>/dev/null; then
    kill -INT "${BAG_PID}" 2>/dev/null || true
  fi

  if [ -n "${LIVOX_PID:-}" ] && kill -0 "${LIVOX_PID}" 2>/dev/null; then
    kill "${LIVOX_PID}" 2>/dev/null || true
  fi
  if [ -n "${REALSENSE_PID:-}" ] && kill -0 "${REALSENSE_PID}" 2>/dev/null; then
    kill "${REALSENSE_PID}" 2>/dev/null || true
  fi
  if [ -n "${SYNC_PID:-}" ] && kill -0 "${SYNC_PID}" 2>/dev/null; then
    kill "${SYNC_PID}" 2>/dev/null || true
  fi

  if [ -n "${FASTLIVO_PID:-}" ] && kill -0 "${FASTLIVO_PID}" 2>/dev/null; then
    echo "[INFO] FastLivo 在等待后仍未退出，发送终止信号..."
    kill -TERM "${FASTLIVO_PID}" 2>/dev/null || true
  fi
}

trap cleanup EXIT INT TERM

echo "[INFO] 启动 Livox 驱动..."
LIVOX_LAUNCH_PATH="${WS_ROOT}/src/livox_ros_driver2/${LIVOX_LAUNCH}"
if [ -f "${LIVOX_LAUNCH_PATH}" ]; then
  ros2 launch "${LIVOX_LAUNCH_PATH}" >"${LOG_DIR}/fast_livo_livox.log" 2>&1 &
else
  ros2 launch "${LIVOX_PACKAGE}" "${LIVOX_LAUNCH}" >"${LOG_DIR}/fast_livo_livox.log" 2>&1 &
fi
LIVOX_PID=$!

sleep 3

echo "[INFO] 启动 RealSense 驱动..."
ros2 launch realsense2_camera "${REALSENSE_LAUNCH}" \
  rgb_camera.color_profile:=640x480x30 \
  enable_color:=true \
  enable_depth:=false \
  enable_accel:=true \
  enable_gyro:=true \
  align_depth:=false \
  pointcloud.enable:=false >"${LOG_DIR}/fast_livo_realsense.log" 2>&1 &
REALSENSE_PID=$!

sleep 5

echo "[INFO] 启动同步节点..."
ros2 launch "${SYNC_LAUNCH_PACKAGE}" "${SYNC_LAUNCH_FILE}" >"${LOG_DIR}/fast_livo_sync.log" 2>&1 &
SYNC_PID=$!

sleep 5

echo "[INFO] 启动 ros2 bag record..."
ros2 bag record -o "${BAG_DIR}" \
  /sync/rgb \
  /sync/livox_custom \
  /livox/imu >"${LOG_DIR}/fast_livo_bag_record.log" 2>&1 &
BAG_PID=$!

sleep 5

echo "[INFO] 启动 FastLivo..."
FASTLIVO_LAUNCH_BASENAME="$(basename "${FASTLIVO_LAUNCH_FILE}")"
FASTLIVO_LAUNCH_ARGS=()
if [ "${FASTLIVO_LAUNCH_BASENAME}" = "mapping_avia.launch.py" ] || [ "${FASTLIVO_LAUNCH_BASENAME}" = "mapping_avia_marslvig.launch.py" ]; then
  FASTLIVO_LAUNCH_ARGS+=("use_rviz:=${FASTLIVO_USE_RVIZ}")
fi

ros2 launch "${FASTLIVO_PACKAGE}" "${FASTLIVO_LAUNCH_FILE}" "${FASTLIVO_LAUNCH_ARGS[@]}" >"${LOG_DIR}/fast_livo_mapping.log" 2>&1 &
FASTLIVO_PID=$!



echo "[INFO] 四个进程已启动。"
echo "[INFO] 日志: ${LOG_DIR}/fast_livo_livox.log ${LOG_DIR}/fast_livo_realsense.log ${LOG_DIR}/fast_livo_sync.log ${LOG_DIR}/fast_livo_mapping.log"
echo "[INFO] 按 Ctrl+C 停止全部进程。"

wait "${LIVOX_PID}" "${REALSENSE_PID}" "${SYNC_PID}" "${FASTLIVO_PID}" "${BAG_PID}"
