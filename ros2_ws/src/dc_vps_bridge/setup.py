from setuptools import find_packages, setup

package_name = "dc_vps_bridge"

setup(
    name=package_name,
    version="0.1.0",
    packages=find_packages(exclude=["test"]),
    data_files=[
        ("share/ament_index/resource_index/packages", ["resource/" + package_name]),
        ("share/" + package_name, ["package.xml"]),
        ("share/" + package_name + "/launch", ["launch/vps_localizer.launch.py"]),
        ("share/" + package_name + "/config", ["config/vps_localizer.yaml"]),
    ],
    install_requires=["setuptools"],
    zip_safe=True,
    maintainer="keen",
    maintainer_email="ehrudxo@gmail.com",
    description="dc-vps 로컬라이제이션 서버를 호출해 pose를 퍼블리시하는 브리지 노드",
    license="TODO",
    entry_points={
        "console_scripts": [
            "vps_localizer_node = dc_vps_bridge.vps_localizer_node:main",
        ],
    },
)
