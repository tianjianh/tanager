#!/bin/bash
# System packages for the Tanager flow. Run once as root in WSL Ubuntu-24.04 on every build host:
#   sudo bash tools/setup_root.sh
#   (from Windows on the same PC: wsl -d Ubuntu-24.04 -u root -e bash tools/setup_root.sh)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq software-properties-common

# GCC 15 for all host builds (Ubuntu toolchain PPA), as for tgsim
add-apt-repository -y ppa:ubuntu-toolchain-r/test
apt-get update -qq
apt-get install -y -qq gcc-15 g++-15 \
  git curl rsync make perl python3 python3-pip python3-venv pkg-config unzip zip \
  autoconf flex bison help2man libfl-dev zlib1g-dev ccache mold numactl libgoogle-perftools-dev \
  libboost-regex-dev libboost-system-dev device-tree-compiler \
  locales libncurses6 libtinfo6 libx11-6 libxext6 libxrender1 libxtst6 libxi6 libfreetype6 fontconfig

# Vivado expects a UTF-8 locale
locale-gen en_US.UTF-8 >/dev/null
gcc-15 --version | head -1
