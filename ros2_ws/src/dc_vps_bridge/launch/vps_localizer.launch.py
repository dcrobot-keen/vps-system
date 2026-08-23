import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch_ros.actions import Node


def generate_launch_description() -> LaunchDescription:
    config = os.path.join(
        get_package_share_directory("dc_vps_bridge"), "config", "vps_localizer.yaml"
    )
    return LaunchDescription(
        [
            Node(
                package="dc_vps_bridge",
                executable="vps_localizer_node",
                name="vps_localizer_node",
                output="screen",
                parameters=[config],
            )
        ]
    )
