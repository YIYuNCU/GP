#!/usr/bin/env bash
set -euo pipefail

source_ros_setup() {
  if [ -f "$1" ]; then
    set +u
    source "$1"
    set -u
  fi
}

source_ros_setup /opt/ros/humble/setup.bash
source_ros_setup /workspace/ws_livox/install/setup.bash
source_ros_setup /workspace/Fast_Livo/install/setup.bash

if [ "$#" -eq 0 ]; then
  exec /bin/bash
fi

exec "$@"
