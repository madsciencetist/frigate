#!/bin/bash

# desktop gpu usage:
#      mkdir trt-models
#      wget https://github.com/blakeblackshear/frigate/raw/master/docker/tensorrt_models.sh
#      chmod +x tensorrt_models.sh
#      docker run --gpus=all --rm -v `pwd`/trt-models:/tensorrt_models -v `pwd`/tensorrt_models.sh:/tensorrt_models.sh nvcr.io/nvidia/tensorrt:22.07-py3 /tensorrt_models.sh <models>

# jetson usage:
#      mkdir trt-models
#      docker run --runtime=nvidia --rm -v `pwd`/trt-models:/tensorrt_models <image> <models>

set -euo pipefail

# On Jetpack 4.6, the nvidia container runtime will mount several host nvidia libraries into the
# container which should not be present in the image - if they are, TRT model generation will
# fail or produce invalid models. Thus we must request the user to install them on the host in
# order to build libyolo here.
# On Jetpack 5.0, these libraries are not mounted by the runtime and are supplied by the image.
if [[ "$(arch)" == "aarch64" &&
      ( ! -e /usr/lib/aarch64-linux-gnu/libnvinfer.so ||
        ! -e /usr/lib/aarch64-linux-gnu/libnvinfer_plugin.so ||
        ! -e /usr/lib/aarch64-linux-gnu/libnvparsers.so ||
        ! -e /usr/lib/aarch64-linux-gnu/libnvonnxparser.so ) ]]; then
    echo "Please run the following on the HOST:"
    echo "  sudo apt install libnvinfer-dev libnvinfer-plugin-dev libnvparsers-dev libnvonnxparsers8"
    exit 1
fi

if [[ $# < 1 || "$1" == "--help" ]]; then
    echo "Please specify a comma-separated list of models to convert, e.g."
    echo "    $0 yolov4-tiny-288,yolov4-tiny-416,yolov7-tiny-416"
    if [[ -e /tensorrt_demos/yolo ]]; then
        echo "Available models:"
        ls *.weights | sed "s/.weights//"
    fi
    exit 1
fi

LD_LIBRARY_PATH=${LD_LIBRARY_PATH}:/usr/local/cuda/lib64:/usr/local/cuda/extras/CUPTI/lib64
OUTPUT_FOLDER=/tensorrt_models
YOLO_MODELS=$1

# Create output folder
mkdir -p ${OUTPUT_FOLDER}

# Install packages
pip3 install --upgrade pip && pip3 install onnx==1.9.0 protobuf==3.20.3 numpy==1.23.*

# Clone tensorrt_demos repo
if [[ ! -e /tensorrt_demos ]]; then
    git clone --depth 1 https://github.com/yeahme49/tensorrt_demos.git /tensorrt_demos
fi

# Build libyolo
cd /tensorrt_demos/plugins
if [ -e /usr/local/cuda-10.2 ]; then
    # cuda-10.2 requires g++-8 but ubuntu20.04 defaults to g++-9
    sed -i 's/CC=g++$/CC=g++-8/g' Makefile
fi
if [ ! -e /usr/local/cuda ]; then
    ln -s /usr/local/cuda-* /usr/local/cuda
fi
make all -j$(nproc)
cp libyolo_layer.so /tensorrt_models/libyolo_layer.so

# Download yolo weights
cd /tensorrt_demos/yolo
if ! ls *.weights &> /dev/null; then
    echo "Downloading yolo weights..."
    ./download_yolo.sh 2> /dev/null
fi

# Build trt engine
cd /tensorrt_demos/yolo

for model in ${YOLO_MODELS//,/ }
do
    start=$(date +%s)

    python3 yolo_to_onnx.py -m ${model}

    python3 onnx_to_tensorrt.py -m ${model} --dla_core -1 # disable DLA (GPU-only)
    mv /tensorrt_demos/yolo/${model}.trt ${OUTPUT_FOLDER}/${model}.trt;

    if [ -e /dev/nvhost-nvdla0 ]; then
        python3 onnx_to_tensorrt.py -m ${model} --dla_core 0 # enable DLA0
        mv /tensorrt_demos/yolo/${model}.trt ${OUTPUT_FOLDER}/${model}_dla.trt;

        # no use in making a dla core 1 model because frigate doesn't have a mechanism
        # to specify the dla core id, so a core 1 model will still run on core 0
    fi

    end=$(date +%s)
    echo "Generated ${model} tensorrt model in $((end-start)) seconds"
done

echo "Available tensorrt models:"
cd ${OUTPUT_FOLDER} && ls *.trt;
