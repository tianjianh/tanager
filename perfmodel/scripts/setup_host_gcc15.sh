#!/bin/bash
# Host GCC 15 for building tgsim on Ubuntu 24.04 (run as root in WSL Ubuntu-24.04).
# Adds the Ubuntu toolchain test PPA and installs g++-15.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q software-properties-common
add-apt-repository -y ppa:ubuntu-toolchain-r/test
apt-get update -q
apt-get install -y -q g++-15
g++-15 --version | head -1
