#!/usr/bin/env bash
# One-time Ubuntu-22.04 (WSL2) setup for the RV32I CoreMark flow. Run as root:
#   wsl -d Ubuntu-22.04 -u root -- bash /mnt/c/Users/zct03/Desktop/FPGA/opt_v05/wsl/setup_wsl.sh
# Creates user "fpga", key-only sshd on port 2222, build deps, and the
# riscv32-unknown-elf toolchain (rv32i/ilp32, newlib) under /opt/riscv32.
set -euo pipefail
USER_NAME=fpga
PUBKEY_FILE=/mnt/c/Users/zct03/.ssh/id_ed25519.pub

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y openssh-server git build-essential autoconf automake autotools-dev curl \
    python3 python3-pip libmpc-dev libmpfr-dev libgmp-dev gawk bison flex texinfo gperf \
    libtool patchutils bc zlib1g-dev libexpat-dev ninja-build cmake libglib2.0-dev device-tree-compiler

id "$USER_NAME" >/dev/null 2>&1 || useradd -m -s /bin/bash "$USER_NAME"
echo "$USER_NAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USER_NAME
chmod 440 /etc/sudoers.d/$USER_NAME
printf '[user]\ndefault=%s\n[boot]\nsystemd=true\n' "$USER_NAME" > /etc/wsl.conf

install -d -m 700 -o $USER_NAME -g $USER_NAME /home/$USER_NAME/.ssh
cp "$PUBKEY_FILE" /home/$USER_NAME/.ssh/authorized_keys
chown $USER_NAME:$USER_NAME /home/$USER_NAME/.ssh/authorized_keys
chmod 600 /home/$USER_NAME/.ssh/authorized_keys

cat > /etc/ssh/sshd_config.d/fpga.conf <<'EOF'
Port 2222
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
EOF
systemctl enable ssh >/dev/null 2>&1 || true
service ssh restart || /usr/sbin/sshd

echo "SETUP_BASE_DONE"
