#!/bin/bash
# System packages needed to build the RTL tools (run as root in WSL Ubuntu-24.04):
#   wsl -d Ubuntu-24.04 -u root -e bash tools/setup_root.sh
set -euo pipefail
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  git curl make perl python3 python3-pip python3-venv pkg-config \
  autoconf flex bison help2man libfl-dev zlib1g-dev ccache mold numactl libgoogle-perftools-dev \
  libboost-regex-dev libboost-system-dev device-tree-compiler
