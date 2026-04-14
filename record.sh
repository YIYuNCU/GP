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
source_ros_setup "${WS_SETUP}"

mkdir -p "${LOG_DIR}"

# ros2 bag record 要求 -o 指定的目录不存在，这里自动避开已存在目录
if [ -e "${BAG_DIR}" ]; then
  BAG_BASE="${BAG_DIR}"
  idx=1
  while [ -e "${BAG_BASE}_${idx}" ]; do
    idx=$((idx + 1))
  done
  BAG_DIR="${BAG_BASE}_${idx}"
fi

REALSENSE_LAUNCH="${REALSENSE_LAUNCH:-rs_launch.py}"
LIVOX_PACKAGE="${LIVOX_PACKAGE:-livox_ros_driver2}"
LIVOX_LAUNCH="${LIVOX_LAUNCH:-launch_ROS2/msg_MID360_launch.py}"
SYNC_LAUNCH_PACKAGE="${SYNC_LAUNCH_PACKAGE:-realsense_mid360_sync}"
SYNC_LAUNCH_FILE="${SYNC_LAUNCH_FILE:-realsense_mid360_sync.launch.py}"

cleanup() {
  if [ -n "${LIVOX_PID:-}" ] && kill -0 "${LIVOX_PID}" 2>/dev/null; then
    kill "${LIVOX_PID}" 2>/dev/null || true
  fi
  if [ -n "${REALSENSE_PID:-}" ] && kill -0 "${REALSENSE_PID}" 2>/dev/null; then
    kill "${REALSENSE_PID}" 2>/dev/null || true
  fi
  if [ -n "${SYNC_PID:-}" ] && kill -0 "${SYNC_PID}" 2>/dev/null; then
    kill "${SYNC_PID}" 2>/dev/null || true
  fi
  if [ -n "${BAG_PID:-}" ] && kill -0 "${BAG_PID}" 2>/dev/null; then
    kill "${BAG_PID}" 2>/dev/null || true
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

sleep 2

echo "[INFO] 启动 ros2 bag record..."
ros2 bag record -o "${BAG_DIR}" \
  /sync/rgb \
  /sync/livox_custom \
  /livox/imu >"${LOG_DIR}/fast_livo_bag_record.log" 2>&1 &
BAG_PID=$!

echo "[INFO] 四个进程已启动。"
echo "[INFO] 日志: ${LOG_DIR}/fast_livo_livox.log ${LOG_DIR}/fast_livo_realsense.log ${LOG_DIR}/fast_livo_sync.log ${LOG_DIR}/fast_livo_bag_record.log"
echo "[INFO] rosbag2: ${BAG_DIR}"
echo "[INFO] 按 Ctrl+C 停止全部进程。"

wait "${LIVOX_PID}" "${REALSENSE_PID}" "${SYNC_PID}" "${BAG_PID}"
