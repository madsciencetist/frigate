# syntax=docker/dockerfile:1.2

# https://askubuntu.com/questions/972516/debian-frontend-environment-variable
ARG DEBIAN_FRONTEND=noninteractive

ARG BASE_IMAGE=debian:11
ARG SLIM_BASE=debian:11-slim

FROM ${BASE_IMAGE} AS base

FROM --platform=linux/amd64 debian:11 AS base_amd64

FROM ${SLIM_BASE} AS slim-base

FROM slim-base AS wget
ARG DEBIAN_FRONTEND
RUN apt-get update \
    && apt-get install -y wget xz-utils \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /rootfs

FROM base AS nginx
ARG DEBIAN_FRONTEND
ENV CCACHE_DIR /root/.ccache
ENV CCACHE_MAXSIZE 2G

# bind /var/cache/apt to tmpfs to speed up nginx build
RUN --mount=type=tmpfs,target=/tmp --mount=type=tmpfs,target=/var/cache/apt \
    --mount=type=bind,source=docker/build_nginx.sh,target=/deps/build_nginx.sh \
    --mount=type=cache,target=/root/.ccache \
    /deps/build_nginx.sh

FROM wget AS go2rtc
ARG TARGETARCH
WORKDIR /rootfs/usr/local/go2rtc/bin
RUN wget -qO go2rtc "https://github.com/AlexxIT/go2rtc/releases/download/v1.5.0/go2rtc_linux_${TARGETARCH}" \
    && chmod +x go2rtc


####
#
# OpenVino Support
#
# 1. Download and convert a model from Intel's Public Open Model Zoo
# 2. Build libUSB without udev to handle NCS2 enumeration
#
####
# Download and Convert OpenVino model
FROM base_amd64 AS ov-converter
ARG DEBIAN_FRONTEND

# Install OpenVino Runtime and Dev library
COPY requirements-ov.txt /requirements-ov.txt
RUN apt-get -qq update \
    && apt-get -qq install -y wget python3 python3-distutils \
    && wget -q https://bootstrap.pypa.io/get-pip.py -O get-pip.py \
    && python3 get-pip.py "pip" \
    && pip install -r /requirements-ov.txt

# Get OpenVino Model
RUN mkdir /models \
    && cd /models && omz_downloader --name ssdlite_mobilenet_v2 \
    && cd /models && omz_converter --name ssdlite_mobilenet_v2 --precision FP16


# libUSB - No Udev
FROM wget as libusb-build
ARG TARGETARCH
ARG DEBIAN_FRONTEND
ENV CCACHE_DIR /root/.ccache
ENV CCACHE_MAXSIZE 2G

# Build libUSB without udev.  Needed for Openvino NCS2 support
WORKDIR /opt
RUN apt-get update && apt-get install -y unzip build-essential automake libtool ccache
RUN --mount=type=cache,target=/root/.ccache wget -q https://github.com/libusb/libusb/archive/v1.0.25.zip -O v1.0.25.zip && \
    unzip v1.0.25.zip && cd libusb-1.0.25 && \
    ./bootstrap.sh && \
    ./configure CC='ccache gcc' CCX='ccache g++' --disable-udev --enable-shared && \
    make -j $(nproc --all)
RUN apt-get update && \
    apt-get install -y --no-install-recommends libusb-1.0-0-dev && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /opt/libusb-1.0.25/libusb
RUN /bin/mkdir -p '/usr/local/lib' && \
    /bin/bash ../libtool  --mode=install /usr/bin/install -c libusb-1.0.la '/usr/local/lib' && \
    /bin/mkdir -p '/usr/local/include/libusb-1.0' && \
    /usr/bin/install -c -m 644 libusb.h '/usr/local/include/libusb-1.0' && \
    /bin/mkdir -p '/usr/local/lib/pkgconfig' && \
    cd  /opt/libusb-1.0.25/ && \
    /usr/bin/install -c -m 644 libusb-1.0.pc '/usr/local/lib/pkgconfig' && \
    ldconfig

FROM wget AS models

# Get model and labels
RUN wget -qO edgetpu_model.tflite https://github.com/google-coral/test_data/raw/release-frogfish/ssdlite_mobiledet_coco_qat_postprocess_edgetpu.tflite
RUN wget -qO cpu_model.tflite https://github.com/google-coral/test_data/raw/release-frogfish/ssdlite_mobiledet_coco_qat_postprocess.tflite
COPY labelmap.txt .
# Copy OpenVino model
COPY --from=ov-converter /models/public/ssdlite_mobilenet_v2/FP16 openvino-model
RUN wget -q https://github.com/openvinotoolkit/open_model_zoo/raw/master/data/dataset_classes/coco_91cl_bkgr.txt -O openvino-model/coco_91cl_bkgr.txt && \
    sed -i 's/truck/car/g' openvino-model/coco_91cl_bkgr.txt
# Get Audio Model and labels
RUN wget -qO cpu_audio_model.tflite https://tfhub.dev/google/lite-model/yamnet/classification/tflite/1?lite-format=tflite
COPY audio-labelmap.txt .


FROM wget AS s6-overlay
ARG TARGETARCH
RUN --mount=type=bind,source=docker/install_s6_overlay.sh,target=/deps/install_s6_overlay.sh \
    /deps/install_s6_overlay.sh


FROM base AS wheels
ARG DEBIAN_FRONTEND
ARG TARGETARCH

# Use a separate container to build wheels to prevent build dependencies in final image
RUN apt-get -qq update \
    && apt-get -qq install -y \
    apt-transport-https \
    gnupg \
    wget \
    && apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 9165938D90FDDD2E \
    && echo "deb http://raspbian.raspberrypi.org/raspbian/ bullseye main contrib non-free rpi" | tee /etc/apt/sources.list.d/raspi.list \
    && apt-get -qq update \
    && apt-get -qq install -y \
    python3.9 \
    python3.9-dev \
    wget \
    # opencv dependencies
    build-essential cmake git pkg-config libgtk-3-dev \
    libavcodec-dev libavformat-dev libswscale-dev libv4l-dev \
    libxvidcore-dev libx264-dev libjpeg-dev libpng-dev libtiff-dev \
    gfortran openexr libatlas-base-dev libssl-dev\
    libtbb2 libtbb-dev libdc1394-22-dev libopenexr-dev \
    libgstreamer-plugins-base1.0-dev libgstreamer1.0-dev \
    # scipy dependencies
    gcc gfortran libopenblas-dev liblapack-dev \
    # faster-fifo dependencies
    g++ cython3 && \
    rm -rf /var/lib/apt/lists/*

# Ensure python3 defaults to python3.9
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.9 1

RUN wget -q https://bootstrap.pypa.io/get-pip.py -O get-pip.py \
    && python3 get-pip.py "pip"

COPY requirements.txt /requirements.txt
RUN pip3 install -r /requirements.txt

COPY requirements-wheels.txt /requirements-wheels.txt
RUN pip3 wheel --wheel-dir=/wheels -r /requirements-wheels.txt

# Make this a separate target so it can be built/cached optionally
FROM wheels as trt-wheels
ARG DEBIAN_FRONTEND
ARG TARGETARCH

# Add TensorRT wheels to another folder
COPY requirements-tensorrt.txt /requirements-tensorrt.txt
RUN mkdir -p /trt-wheels && pip3 wheel --wheel-dir=/trt-wheels -r /requirements-tensorrt.txt

FROM wheels AS jetson-trt-wheels
ARG DEBIAN_FRONTEND
ARG TARGETARCH

RUN apt update \
    && apt install -y libnvinfer8 \
    && rm -rf /var/lib/apt/lists/*

# Determine version of tensorrt already installed in base image, e.g. "Version: 8.4.1-1+cuda11.4"
RUN NVINFER_VER=$(dpkg -s libnvinfer8 | grep -Po "Version: \K.*") \
    && echo $NVINFER_VER | grep -Po "^\d+\.\d+\.\d+" > /etc/TENSORRT_VER \
    && echo $NVINFER_VER | grep -Po "cuda\K.*" > /etc/CUDA_VER

# python-tensorrt build deps are 3.4 GB!
RUN CUDA_PKG_VER=$(sed "s/\./-/g" /etc/CUDA_VER) \
    && apt-get update \
    && apt-get install -y ccache cuda-cudart-dev-${CUDA_PKG_VER} cuda-nvcc-${CUDA_PKG_VER} libnvonnxparsers-dev libnvparsers-dev libnvinfer-plugin-dev \
    && ([ -e /usr/local/cuda ] || ln -s /usr/local/cuda-$(cat /etc/CUDA_VER) /usr/local/cuda) \
    && rm -rf /var/lib/apt/lists/*;
RUN --mount=type=bind,source=docker/build_python_tensorrt.sh,target=/deps/build_python_tensorrt.sh \
    --mount=type=cache,target=/root/.ccache \
    export PATH="/usr/lib/ccache:$PATH" CCACHE_DIR=/root/.ccache CCACHE_MAXSIZE=2G \
    && TENSORRT_VER=$(cat /etc/TENSORRT_VER) /deps/build_python_tensorrt.sh

COPY requirements-tensorrt-jetson.txt /requirements-tensorrt-jetson.txt
RUN pip3 wheel --wheel-dir=/trt-wheels -r /requirements-tensorrt-jetson.txt

FROM wheels AS jetson-trt-model-wheels
ARG DEBIAN_FRONTEND

RUN apt-get update \
    && apt-get install -y protobuf-compiler libprotobuf-dev \
    && rm -rf /var/lib/apt/lists/*

# Match versions in tensorrt_models.sh
RUN pip3 wheel --wheel-dir=/trt-model-wheels onnx==1.9.0 protobuf==3.20.3 numpy==1.23.*


# Collect deps in a single layer
FROM scratch AS deps-rootfs
COPY --from=nginx /usr/local/nginx/ /usr/local/nginx/
COPY --from=go2rtc /rootfs/ /
COPY --from=libusb-build /usr/local/lib /usr/local/lib
COPY --from=s6-overlay /rootfs/ /
COPY --from=models /rootfs/ /
COPY docker/rootfs/ /


# Frigate deps (ffmpeg, python, nginx, go2rtc, s6-overlay, etc)
FROM slim-base AS deps
ARG TARGETARCH

ARG DEBIAN_FRONTEND
# http://stackoverflow.com/questions/48162574/ddg#49462622
ARG APT_KEY_DONT_WARN_ON_DANGEROUS_USAGE=DontWarn

# https://github.com/NVIDIA/nvidia-docker/wiki/Installation-(Native-GPU-Support)
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES="compute,video,utility"

ENV PATH="/usr/lib/btbn-ffmpeg/bin:/usr/local/go2rtc/bin:/usr/local/nginx/sbin:${PATH}"

# Install dependencies
RUN --mount=type=bind,source=docker/install_deps.sh,target=/deps/install_deps.sh \
    /deps/install_deps.sh

RUN --mount=type=bind,from=wheels,source=/wheels,target=/deps/wheels \
    python3 -m pip install --upgrade pip && \
    pip3 install -U /deps/wheels/*.whl

COPY --from=deps-rootfs / /

RUN ldconfig

EXPOSE 5000
EXPOSE 1935
EXPOSE 8554
EXPOSE 8555/tcp 8555/udp

# Configure logging to prepend timestamps, log to stdout, keep 0 archives and rotate on 10MB
ENV S6_LOGGING_SCRIPT="T 1 n0 s10000000 T"

ENTRYPOINT ["/init"]
CMD []

# Frigate deps with Node.js and NPM for devcontainer
FROM deps AS devcontainer

# Do not start the actual Frigate service on devcontainer as it will be started by VSCode
# But start a fake service for simulating the logs
COPY docker/fake_frigate_run /etc/s6-overlay/s6-rc.d/frigate/run

# Create symbolic link to the frigate source code, as go2rtc's create_config.sh uses it
RUN mkdir -p /opt/frigate \
    && ln -svf /workspace/frigate/frigate /opt/frigate/frigate

# Install Node 16
RUN apt-get update \
    && apt-get install wget -y \
    && wget -qO- https://deb.nodesource.com/setup_16.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g npm@9

WORKDIR /workspace/frigate

RUN apt-get update \
    && apt-get install make -y \
    && rm -rf /var/lib/apt/lists/*

RUN --mount=type=bind,source=./requirements-dev.txt,target=/workspace/frigate/requirements-dev.txt \
    pip3 install -r requirements-dev.txt

CMD ["sleep", "infinity"]


# Frigate web build
# This should be architecture agnostic, so speed up the build on multiarch by not using QEMU.
FROM --platform=$BUILDPLATFORM node:16 AS web-build

WORKDIR /work
COPY web/package.json web/package-lock.json ./
RUN npm install

COPY web/ ./
RUN npm run build \
    && mv dist/BASE_PATH/monacoeditorwork/* dist/assets/ \
    && rm -rf dist/BASE_PATH

# Collect final files in a single layer
FROM scratch AS rootfs

WORKDIR /opt/frigate/
COPY frigate frigate/
COPY migrations migrations/
COPY --from=web-build /work/dist/ web/

# Frigate final container
FROM deps AS frigate

WORKDIR /opt/frigate/
COPY --from=rootfs / /

# Frigate w/ TensorRT Support as separate image
FROM frigate AS frigate-tensorrt
RUN --mount=type=bind,from=trt-wheels,source=/trt-wheels,target=/deps/trt-wheels \
    pip3 install -U /deps/trt-wheels/*.whl && \
    ln -s libnvrtc.so.11.2 /usr/local/lib/python3.9/dist-packages/nvidia/cuda_nvrtc/lib/libnvrtc.so && \
    ldconfig

# Frigate w/ TensorRT for NVIDIA Jetson platforms
FROM frigate AS frigate-jetson
RUN --mount=type=bind,from=jetson-trt-wheels,source=/trt-wheels,target=/deps/trt-wheels \
    pip3 install -U /deps/trt-wheels/*.whl

# Image to generate TRT models (must run on target HW and with exact same TRT version)
FROM wget AS tensorrt_demos
RUN wget -q https://github.com/yeahme49/tensorrt_demos/archive/refs/heads/master.zip \
    && unzip master.zip && mv tensorrt_demos-master /tensorrt_demos && rm master.zip \
    && cd /tensorrt_demos/yolo && ./download_yolo.sh 2> /dev/null

FROM deps AS jetson-trt-models
RUN --mount=type=bind,from=jetson-trt-wheels,source=/trt-wheels,target=/deps/trt-wheels \
    --mount=type=bind,from=jetson-trt-model-wheels,source=/trt-model-wheels,target=/deps/trt-model-wheels \
    pip3 install -U /deps/trt-wheels/*.whl /deps/trt-model-wheels/*.whl

# On Jetpack 4.6, libnvinfer is mounted from the host via the nvidia container runtime, and thus must
# not be in the image, so don't add: {libnvinfer, libnvinfer-plugin, libnvparsers, libnvonnxparsers}
# Otherwise model generation fails or produces models that don't load.
# For Jetpack 5.0, these libraries must be installed in the image.
RUN apt-get update \
    && apt-get install -y python-is-python3 libprotobuf17 build-essential cuda-nvcc-* \
    && if [ ${CUDA_VERSION%%.*} -ge 11 ]; then \
         apt-get install -y libnvinfer-dev libnvinfer-plugin-dev libnvparsers-dev libnvonnxparsers-dev; \
       else \
         [ ! -e /usr/lib/aarch64-linux-gnu/libnvinfer.so ]; \
       fi \
    && rm -rf /var/lib/apt/lists/*

COPY --from=tensorrt_demos /tensorrt_demos /tensorrt_demos
WORKDIR /tensorrt_demos/yolo
COPY docker/tensorrt_models.sh /tensorrt_models.sh
ENTRYPOINT ["/tensorrt_models.sh"]

# Dev Container w/ TRT
FROM devcontainer AS devcontainer-trt

RUN --mount=type=bind,from=trt-wheels,source=/trt-wheels,target=/deps/trt-wheels \
    pip3 install -U /deps/trt-wheels/*.whl
