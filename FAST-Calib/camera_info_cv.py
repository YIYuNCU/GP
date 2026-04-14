#!/usr/bin/env python3
import rclpy
from rclpy.node import Node
from sensor_msgs.msg import CameraInfo
import yaml

class RealtimeCameraParamMonitor(Node):
    def __init__(self, topic='/camera/color/camera_info'):
        super().__init__('camera_param_monitor')
        
        self.subscription = self.create_subscription(
            CameraInfo,
            topic,
            self.callback,
            10)
        
        self.save_count = 0
        self.max_save = 1  # 只保存一次
        
    def callback(self, msg):
        if self.save_count >= self.max_save:
            return
            
        params = {
            'image_width': msg.width,
            'image_height': msg.height,
            'camera_matrix': {
                'rows': 3,
                'cols': 3,
                'data': [float(msg.k[0]), 0.0, float(msg.k[2]), 
                         0.0, float(msg.k[4]), float(msg.k[5]), 
                         0.0, 0.0, 1.0]
            },
            'distortion_model': msg.distortion_model,
            'distortion_coefficients': {
                'rows': 1,
                'cols': len(msg.d),
                'data': [float(d) for d in msg.d]
            }
        }
        
        # 保存到文件
        filename = f'camera_params_{self.save_count}.yaml'
        with open(filename, 'w') as f:
            yaml.dump(params, f, default_flow_style=False)
        
        # 同时保存为简单格式
        simple_params = f"""fx: {msg.k[0]}
fy: {msg.k[4]}
cx: {msg.k[2]}
cy: {msg.k[5]}
k1: {msg.d[0] if len(msg.d) > 0 else 0.0}
k2: {msg.d[1] if len(msg.d) > 1 else 0.0}
p1: {msg.d[2] if len(msg.d) > 2 else 0.0}
p2: {msg.d[3] if len(msg.d) > 3 else 0.0}
width: {msg.width}
height: {msg.height}"""
        
        with open(f'simple_{filename}', 'w') as f:
            f.write(simple_params)
        
        self.get_logger().info(f"参数已保存到 {filename}")
        self.get_logger().info(f"简单格式已保存到 simple_{filename}")
        
        # 打印参数
        print("\n=== 相机内参 ===")
        print(f"分辨率: {msg.width} x {msg.height}")
        print(f"fx: {msg.k[0]}")
        print(f"fy: {msg.k[4]}")
        print(f"cx: {msg.k[2]}")
        print(f"cy: {msg.k[5]}")
        
        if len(msg.d) >= 5:
            print(f"畸变系数:")
            print(f"  k1: {msg.d[0]}")
            print(f"  k2: {msg.d[1]}")
            print(f"  p1: {msg.d[2]}")
            print(f"  p2: {msg.d[3]}")
            print(f"  k3: {msg.d[4]}")
        
        self.save_count += 1
        
        if self.save_count >= self.max_save:
            self.get_logger().info("已获取参数，退出程序")
            self.destroy_node()
            rclpy.shutdown()

def main(args=None):
    rclpy.init(args=args)
    
    # 可以选择监听不同的话题
    # topic = '/camera/color/camera_info'      # 彩色相机
    # topic = '/camera/depth/camera_info'      # 深度相机
    # topic = '/camera/infra1/camera_info'    # 左红外
    topic = '/camera/camera/color/camera_info'
    
    node = RealtimeCameraParamMonitor(topic)
    rclpy.spin(node)

if __name__ == '__main__':
    main()