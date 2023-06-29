#!/bin/bash

# For jetson platforms, build ffmpeg with custom patches. NVIDIA supplies a deb
# with accelerated decoding, but it doesn't have accelerated encoding

set -euxo pipefail

INSTALL_PREFIX=/rootfs/usr/local

apt-get -qq update
apt-get -qq install -y --no-install-recommends build-essential ccache clang cmake pkg-config

pushd /tmp

# Install libnvmpi to enable nvmpi decoders (h264_nvmpi, hevc_nvmpi)
if [ -e /usr/local/cuda-10.2 ]; then
    # assume Jetpack 4.X
    wget -q https://developer.nvidia.com/embedded/L4T/r32_Release_v5.0/T186/Jetson_Multimedia_API_R32.5.0_aarch64.tbz2 -O jetson_multimedia_api.tbz2
else
    # assume Jetpack 5.X
    wget -q https://developer.nvidia.com/downloads/embedded/l4t/r35_release_v3.1/release/jetson_multimedia_api_r35.3.1_aarch64.tbz2 -O jetson_multimedia_api.tbz2
fi
tar xaf jetson_multimedia_api.tbz2 -C / && rm jetson_multimedia_api.tbz2

wget -q https://github.com/madsciencetist/jetson-ffmpeg/archive/refs/heads/master.zip
unzip master.zip && rm master.zip && cd jetson-ffmpeg-master
LD_LIBRARY_PATH=$(pwd)/stubs:$LD_LIBRARY_PATH   # tegra multimedia libs aren't available in image, so use stubs for ffmpeg build
mkdir build
cd build
cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX
make -j$(nproc)
make install
cd ../../

# Build ffmpeg with nvmpi patch
wget -q https://ffmpeg.org/releases/ffmpeg-6.0.tar.xz
tar xaf ffmpeg-*.tar.xz && rm ffmpeg-*.tar.xz && cd ffmpeg-*
patch -p1 < ../jetson-ffmpeg-master/ffmpeg_patches/ffmpeg6.0_nvmpi.patch
export PKG_CONFIG_PATH=$INSTALL_PREFIX/lib/pkgconfig
# enable Jetson codecs
./configure --cc='ccache gcc' --cxx='ccache g++' \
            --enable-shared --disable-static --prefix=$INSTALL_PREFIX \
            --enable-nvmpi
    || (cat ffbuild/config.log && false)
make -j$(nproc)
make install
cd ../

rm -rf /var/lib/apt/lists/*
popd
