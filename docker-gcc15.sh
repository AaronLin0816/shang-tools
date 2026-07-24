#!/usr/bin/env bash

set -euo pipefail

DOCKER_BUILD_DIR=${DOCKER_BUILD_DIR:-/workspace/johann/docker-gcc15}
IMAGE_NAME=${IMAGE_NAME:-model-dev-shang-chi-gcc15}
HOST_MODEL_DIR=${HOST_MODEL_DIR:-$(pwd)}
CONTAINER_MODEL_DIR=${CONTAINER_MODEL_DIR:-/work/home/shang-chi/workspace/model}
CONTAINER_COMMAND=("$@")
DOCKER_RUN_FLAGS=(--rm)

if [ "$#" -eq 0 ]; then
    CONTAINER_COMMAND=(bash)
fi

if [ -t 0 ] && [ -t 1 ]; then
    DOCKER_RUN_FLAGS=(-it --rm)
fi

if [ ! -f "$HOST_MODEL_DIR/CMakeLists.txt" ] || [ ! -x "$HOST_MODEL_DIR/build.sh" ]; then
    echo "Run this script from the model root, or set HOST_MODEL_DIR explicitly: $HOST_MODEL_DIR" >&2
    exit 1
fi

if [ ! -d "$DOCKER_BUILD_DIR" ]; then
    echo "Docker build directory does not exist: $DOCKER_BUILD_DIR" >&2
    exit 1
fi

if [ ! -x "$DOCKER_BUILD_DIR/build.sh" ]; then
    echo "Docker build script is not executable: $DOCKER_BUILD_DIR/build.sh" >&2
    exit 1
fi

(
    cd "$DOCKER_BUILD_DIR"
    ./build.sh
)

docker run "${DOCKER_RUN_FLAGS[@]}" \
    -v "$HOST_MODEL_DIR:$CONTAINER_MODEL_DIR" \
    -w "$CONTAINER_MODEL_DIR" \
    "$IMAGE_NAME" \
    "${CONTAINER_COMMAND[@]}"
