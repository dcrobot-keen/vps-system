from setuptools import find_packages, setup

setup(
    name="dc_vps_pipeline",
    version="0.1.0",
    packages=find_packages(include=["dc_vps_pipeline", "dc_vps_pipeline.*"]),
    python_requires=">=3.10",
)
