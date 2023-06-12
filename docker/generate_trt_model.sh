#!/bin/bash

# Must run on target Jetson device - not as part of a Docker build
# try:
#      mkdir tensorrt_models
#      docker run --runtime=nvidia --rm -it -v `pwd`/tensorrt_models:/tensorrt_models jetson-trt-models

set -euo pipefail

if [[ $# < 1 || "$1" == "--help" ]]; then
    echo "Please specify a comma-separated list of models to convert from the following options:"
    ls *.weights | sed "s/.weights//"
    exit 1
fi

set -x
YOLO_MODELS=$1

OUTPUT_FOLDER=/tensorrt_models

# Build libyolo
cd /tensorrt_demos/plugins
if [ -e /usr/local/cuda-10.2 ]; then
    # cuda-10.2 requires g++-8 but ubuntu20.04 defaults to g++-9
    sed -i 's/CC=g++$/CC=g++-8/g' Makefile
fi
make all -j$(nproc)
mkdir -p ${OUTPUT_FOLDER}
cp libyolo_layer.so /tensorrt_models/libyolo_layer.so

# Build trt engine
cd /tensorrt_demos/yolo

for model in ${YOLO_MODELS//,/ }
do
    start=$(date +%s)

    python3 yolo_to_onnx.py -m ${model}

    python3 onnx_to_tensorrt.py -m ${model} --dla_core -1 # 0, 1, or -1 to disable DLA (default)
    mv /tensorrt_demos/yolo/${model}.trt ${OUTPUT_FOLDER}/${model}_gpu.trt;

    if [ -e /dev/nvhost-nvdla0 ]; then
        python3 onnx_to_tensorrt.py -m ${model} --dla_core 0
        mv /tensorrt_demos/yolo/${model}.trt ${OUTPUT_FOLDER}/${model}_dla.trt;
    fi

    # no use in making a dla core 1 model because frigate doesn't have a mechanism
    # to specify the dla core id, so a core 1 model will still run on core 0

    end=$(date +%s)
    echo "Generated ${model} tensorrt model in $((end-start)) seconds"
done
