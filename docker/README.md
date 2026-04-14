# Fast_Livo + Livox-SDK Docker

这个镜像把 `Fast_Livo`、`livox_SDK/Livox-SDK2` 和 ROS2 Humble 运行时一起封装好了，并默认使用 `host` 网络，方便容器内外的 ROS2 节点互相发现。

## 构建

```bash
docker build -f Dockerfile.fast_livo -t fast_livo:humble .
```

## 运行

如果需要从宿主机显示 RViz，先放行 X11：

```bash
xhost +local:root
```

然后启动：

```bash
./start_fast_livo_docker.sh run
```

如果 Docker Hub 拉取超时，建议先走镜像配置脚本：

```bash
./start_fast_livo_with_mirror.sh run

- `build`：只构建镜像
- `run`：构建后启动并执行 [run.sh](run.sh)
- `shell`：进入容器交互式 shell
- `stop`：停止并删除同名容器
- `logs`：查看容器日志

脚本会把详细日志写到 `tmp/` 目录下，例如 `start_fast_livo_*.log` 和 `start_fast_livo_mirror_*.log`，方便你排查构建和启动过程。
如果需要更细的构建输出，脚本会自动启用 BuildKit 的 plain 日志格式。
```

如果默认的 `osrf/ros:humble-desktop-jammy` 在当前代理源上不存在，脚本会自动尝试一组候选基础镜像；你也可以手动指定：
```

如果你已经知道可用的镜像地址，也可以直接指定候选列表：
BASE_IMAGE_CANDIDATES='osrf/ros:humble-desktop-jammy,docker.m.daocloud.io/osrf/ros:humble-desktop-jammy' ./start_fast_livo_with_mirror.sh run
```

默认会执行根目录的 `run.sh`，启动顺序和你现有脚本一致：Livox 驱动、RealSense、同步节点、rosbag record、FAST-LIVO2。

如果想只进入容器排查环境：

```bash
./start_fast_livo_docker.sh shell
```

如果只想构建镜像：

```bash
./start_fast_livo_docker.sh build
```

## 外部访问 ROS2 话题

这个镜像已经做了三层处理，外部 ROS2 节点可以直接订阅容器里的消息：

1. 使用 `network_mode: host`
2. 固定 `ROS_DOMAIN_ID`
3. 显式切到 `rmw_cyclonedds_cpp`

宿主机或其他外部节点侧保持一致的环境变量即可，例如：

```bash
export ROS_DOMAIN_ID=0
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
ros2 topic list
# Fast_Livo + Livox-SDK Docker

这个镜像把 `Fast_Livo`、`livox_SDK/Livox-SDK2` 和 ROS2 Humble 运行时一起封装好了，并默认使用 `host` 网络，方便容器内外的 ROS2 节点互相发现。

## 构建

```bash
docker build -f Dockerfile.fast_livo -t fast_livo:humble .
```

## 运行

如果需要从宿主机显示 RViz，先放行 X11：

```bash
xhost +local:root
```

然后启动：

```bash
./start_fast_livo_docker.sh run
```

如果 Docker Hub 拉取超时，建议先走镜像配置脚本：

```bash
./start_fast_livo_with_mirror.sh run
```

如果默认的 `osrf/ros:humble-desktop-jammy` 在当前代理源上不存在，脚本会自动尝试一组候选基础镜像；你也可以手动指定：

```bash
BASE_IMAGE=osrf/ros:humble-desktop-jammy ./start_fast_livo_with_mirror.sh run
```

如果你已经知道可用的镜像地址，也可以直接指定候选列表：

```bash
BASE_IMAGE_CANDIDATES='osrf/ros:humble-desktop-jammy,docker.m.daocloud.io/osrf/ros:humble-desktop-jammy' ./start_fast_livo_with_mirror.sh run
```

默认会执行根目录的 `run.sh`，启动顺序和你现有脚本一致：Livox 驱动、RealSense、同步节点、rosbag record、FAST-LIVO2。

如果想只进入容器排查环境：

```bash
./start_fast_livo_docker.sh shell
```

如果只想构建镜像：

```bash
./start_fast_livo_docker.sh build
```

## 外部访问 ROS2 话题

这个镜像已经做了三层处理，外部 ROS2 节点可以直接订阅容器里的消息：

1. 使用 `network_mode: host`
2. 固定 `ROS_DOMAIN_ID`
3. 显式切到 `rmw_cyclonedds_cpp`

宿主机或其他外部节点侧保持一致的环境变量即可，例如：

```bash
export ROS_DOMAIN_ID=0
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
ros2 topic list
ros2 topic echo /sync/livox_custom
```

## 启动脚本说明

根目录的 [start_fast_livo_docker.sh](start_fast_livo_docker.sh) 是推荐入口，兼容大多数 Linux 发行版。

如果系统里没有 `docker`，脚本会自动尝试 `podman`。两者都没有时，需要先安装其中一个。
如果 `docker` 已安装但当前用户没有访问 `/var/run/docker.sock` 的权限，脚本会自动改用 `sudo docker`；否则需要把用户加入 `docker` 组后重新登录。

```bash
chmod +x start_fast_livo_docker.sh
./start_fast_livo_docker.sh run
```

如果你希望自动配置 Docker registry mirror 和容器内 apt 镜像源，使用 [start_fast_livo_with_mirror.sh](start_fast_livo_with_mirror.sh)。它会先写入 Docker 的镜像源配置，再把 `UBUNTU_APT_MIRROR` 和 `ROS_APT_MIRROR` 传给镜像构建阶段。

可用命令：

- `build`：只构建镜像
- `run`：构建后启动并执行 [run.sh](run.sh)
- `shell`：进入容器交互式 shell
- `stop`：停止并删除同名容器
- `logs`：查看容器日志

脚本会把详细日志写到 `tmp/` 目录下，例如 `start_fast_livo_*.log` 和 `start_fast_livo_mirror_*.log`，方便你排查构建和启动过程。
如果需要更细的构建输出，脚本会自动启用 BuildKit 的 plain 日志格式。

在 Docker 构建阶段，Sophus 的安装步骤会输出类似 `[Sophus] cloning source repository`、`[Sophus] configure build` 这样的阶段日志，方便确认当前卡在哪一步。

## 关键话题

- 输入：`/camera/color/image_raw`、`/livox/lidar`
- 同步后输出：`/sync/rgb`、`/sync/livox_custom`、`/sync/sync_info`
- FAST-LIVO2 的输出取决于 `Fast_Livo/src/FASTLIVO2_ROS2/config/*.yaml`

## 备注

- `/dev/bus/usb` 已在 compose 中挂载，适合接真实 Livox 和 RealSense 设备。
- 如果你只想跑离线 bag，不需要真实相机/雷达，可以把 `run.sh` 里的驱动启动步骤关掉，再用 `ros2 bag play` 喂数据。

