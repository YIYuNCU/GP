#!/usr/bin/env python3
import rclpy
from rclpy.node import Node
from sensor_msgs.msg import CameraInfo
import yaml
from pathlib import Path

class CameraParamExtractor(Node):
    def __init__(self):
        super().__init__('camera_param_extractor')
        self.subscription = self.create_subscription(
            CameraInfo,
            '/camera/camera/color/camera_info',  # 或 /camera/infra1/camera_info
            self.camera_info_callback,
            10)
        self.got_info = False
    
    def camera_info_callback(self, msg):
        if self.got_info:
            return
        
        self.get_logger().info("成功获取相机参数!")
        
        # 提取内参矩阵 K
        fx = msg.k[0]  # 焦距 x
        fy = msg.k[4]  # 焦距 y
        cx = msg.k[2]  # 主点 x
        cy = msg.k[5]  # 主点 y
        
        # 畸变系数
        d0 = msg.d[0] if len(msg.d) > 0 else 0.0
        d1 = msg.d[1] if len(msg.d) > 1 else 0.0
        d2 = msg.d[2] if len(msg.d) > 2 else 0.0
        d3 = msg.d[3] if len(msg.d) > 3 else 0.0
        
        # 创建字典
        camera_params = {
            'camera': {
                'model': 'Pinhole',
                'width': msg.width,
                'height': msg.height,
                'scale': 0.5,  # 需要根据实际使用调整
                'fx': float(fx),
                'fy': float(fy),
                'cx': float(cx),
                'cy': float(cy),
                'd0': float(d0),
                'd1': float(d1),
                'd2': float(d2),
                'd3': float(d3)
            }
        }
        
        # 保存到 YAML 文件
        output_path = str(Path.home() / 'camera_calibration.yaml')
        with open(output_path, 'w') as f:
            yaml.dump(camera_params, f, default_flow_style=False)
        
        self.get_logger().info(f"参数已保存到: {output_path}")
        self.get_logger().info("参数值:")
        self.get_logger().info(f"  fx: {fx}")
        self.get_logger().info(f"  fy: {fy}")
        self.get_logger().info(f"  cx: {cx}")
        self.get_logger().info(f"  cy: {cy}")
        self.get_logger().info(f"  d0: {d0}")
        self.get_logger().info(f"  d1: {d1}")
        self.get_logger().info(f"  d2: {d2}")
        self.get_logger().info(f"  d3: {d3}")
        
        self.got_info = True
        self.destroy_node()
        rclpy.shutdown()

def main(args=None):
    rclpy.init(args=args)
    node = CameraParamExtractor()
    rclpy.spin(node)

if __name__ == '__main__':
    main()