#!/usr/bin/env bash
# Build riscv32-unknown-elf-gcc (rv32i/ilp32 + newlib) as user fpga, from
# release tarballs (the gcc.gnu.org git submodule is too large to clone here).
# riscv-gnu-toolchain 2024.04.12 build scripts + GCC 13.2.0 / binutils 2.42 /
# newlib 4.4.0. Log: ~/toolchain-build.log
set -euo pipefail
PREFIX=/opt/riscv32
GNU=https://mirrors.tuna.tsinghua.edu.cn/gnu
SRC=~/tc-src
sudo install -d -o "$(id -u)" -g "$(id -g)" $PREFIX
mkdir -p $SRC && cd $SRC
fetch() { [ -f "$2" ] || curl -fL --retry 3 -o "$2" "$1"; }
fetch $GNU/gcc/gcc-13.2.0/gcc-13.2.0.tar.xz gcc-13.2.0.tar.xz
fetch $GNU/binutils/binutils-2.42.tar.xz binutils-2.42.tar.xz
fetch https://sourceware.org/pub/newlib/newlib-4.4.0.20231231.tar.gz newlib-4.4.0.20231231.tar.gz
for t in gcc-13.2.0.tar.xz binutils-2.42.tar.xz newlib-4.4.0.20231231.tar.gz; do
    d=${t%.tar.*}; [ -d "$d" ] || tar xf "$t"
done
(cd gcc-13.2.0 && ./contrib/download_prerequisites)

cd ~
[ -d riscv-gnu-toolchain ] || git clone https://github.com/riscv-collab/riscv-gnu-toolchain.git
cd riscv-gnu-toolchain
git checkout -q 2024.04.12
rm -rf build && mkdir build && cd build
../configure --prefix=$PREFIX --with-arch=rv32i --with-abi=ilp32 --disable-gdb \
    --with-gcc-src=$SRC/gcc-13.2.0 --with-binutils-src=$SRC/binutils-2.42 \
    --with-newlib-src=$SRC/newlib-4.4.0.20231231
make -j"$(nproc)" newlib
grep -q /opt/riscv32/bin ~/.bashrc || echo 'export PATH=/opt/riscv32/bin:$PATH' >> ~/.bashrc
$PREFIX/bin/riscv32-unknown-elf-gcc --version | head -1
echo "TOOLCHAIN_DONE"
