FROM --platform=linux/amd64 ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive
ARG FLUTTER_VERSION=3.47.8
ARG RUST_VERSION=1.99.1

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates clang cmake curl git libgtk-3-dev libudev-dev \
    libx11-dev libxi-dev liblzma-dev ninja-build pkg-config python3 \
    unzip xz-utils zip && rm -rf /var/lib/apt/lists/*

ENV CARGO_HOME=/opt/cargo RUSTUP_HOME=/opt/rustup
ENV PATH=/opt/cargo/bin:/opt/flutter/bin:$PATH
RUN curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh && \
    sh /tmp/rustup.sh -y --no-modify-path --profile minimal --default-toolchain "$RUST_VERSION" && \
    rm /tmp/rustup.sh
RUN git clone --depth 1 --branch "$FLUTTER_VERSION" https://github.com/flutter/flutter.git /opt/flutter && \
    flutter config --no-analytics && flutter precache --linux

WORKDIR /workspace
