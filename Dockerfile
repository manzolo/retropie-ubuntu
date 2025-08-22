# Build stage for downloading tools
FROM ubuntu:24.04 AS builder
ARG DEBIAN_FRONTEND=noninteractive
ARG SKIP_CHECKSUM_VALIDATION=false
RUN apt-get update -qq && \
    apt-get install -qqy --no-install-recommends \
        ca-certificates \
        wget \
        curl \
        xz-utils && \
    # Download and verify tini
    ARCH="$(dpkg --print-architecture)" && \
    echo "Detected architecture: ${ARCH}" && \
    TINI_VERSION="v0.19.0" && \
    wget -q -O /usr/local/bin/tini "https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-${ARCH}" && \
    case "${ARCH}" in \
        amd64) TINI_CHECKSUM="93dcc18adc78c65a028a84799ecf8ad40c936fdfc5f2a57b1acda5a8117fa82c" ;; \
        arm64) TINI_CHECKSUM="0877810f436dfb3b7e7e8f13c3f97bd13027819d8e67d35bd4273b86322d097d" ;; \
        *) echo "Unsupported architecture: ${ARCH}" && exit 1 ;; \
    esac && \
    echo "Verifying tini checksum: ${TINI_CHECKSUM}" && \
    if [ "$SKIP_CHECKSUM_VALIDATION" != "true" ]; then \
        echo "Computed checksum for tini:" && \
        sha256sum /usr/local/bin/tini && \
        echo "${TINI_CHECKSUM} /usr/local/bin/tini" | sha256sum -c - || exit 1; \
    else \
        echo "Skipping checksum validation for tini"; \
    fi && \
    chmod +x /usr/local/bin/tini && \
    # Download and verify gosu
    GOSU_VERSION="1.17" && \
    wget -q -O /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-${ARCH}" && \
    case "${ARCH}" in \
        amd64) GOSU_CHECKSUM="bbc4136d03ab138b1ad66fa4fc051bafc6cc7ffae632b069a53657279a450de3" ;; \
        arm64) GOSU_CHECKSUM="c7ad6d90d3e4c8d7d771b1b92d99d106b3d9a853a8016b66e6f7f4a8f6e9920f" ;; \
        *) echo "Unsupported architecture: ${ARCH}" && exit 1 ;; \
    esac && \
    echo "Verifying gosu checksum: ${GOSU_CHECKSUM}" && \
    if [ "$SKIP_CHECKSUM_VALIDATION" != "true" ]; then \
        echo "Computed checksum for gosu:" && \
        sha256sum /usr/local/bin/gosu && \
        echo "${GOSU_CHECKSUM} /usr/local/bin/gosu" | sha256sum -c - || exit 1; \
    else \
        echo "Skipping checksum validation for gosu"; \
    fi && \
    chmod +x /usr/local/bin/gosu && \
    # Download s6-overlay
    S6_VERSION="3.1.6.2" && \
    S6_ARCH="" && \
    case "${ARCH}" in \
        amd64) S6_ARCH="x86_64" ;; \
        arm64) S6_ARCH="aarch64" ;; \
        *) echo "Unsupported architecture: ${ARCH}" && exit 1 ;; \
    esac && \
    wget -q -O /s6-overlay.tar.xz "https://github.com/just-containers/s6-overlay/releases/download/v${S6_VERSION}/s6-overlay-${S6_ARCH}.tar.xz"

# Final stage
FROM ubuntu:24.04
ARG DEBIAN_FRONTEND=noninteractive
ARG CONTAINER_USERNAME=ubuntu
ARG CONTAINER_UID=1000
ARG CONTAINER_GID=1000
ARG NVIDIA_MAJOR_VERSION=575
ARG NVIDIA_FALLBACK_VERSION=575.64-0ubuntu0.24.04.1
ARG INSTALL_NVIDIA_DRIVERS=true
ARG INSTALL_WAYLAND_SUPPORT=true

ENV CONTAINER_USERNAME=${CONTAINER_USERNAME} \
    CONTAINER_UID=${CONTAINER_UID} \
    CONTAINER_GID=${CONTAINER_GID}

# Metadata labels
LABEL maintainer="manzolo@libero.it" \
      description="Ubuntu container with Wayland and NVIDIA drivers" \
      version="1.5" \
      org.opencontainers.image.source="https://github.com/your-repo/docker-ubuntu-wayland" \
      org.opencontainers.image.base.name="ubuntu:24.04" \
      org.opencontainers.image.architecture="amd64,arm64"

# Install runtime packages
RUN apt-get update -qq && \
    apt-get install -qqy --no-install-recommends \
        ca-certificates \
        sudo \
        tzdata \
        locales \
        libgl1-mesa-dri \
        libnotify-bin \
        vulkan-tools \
        pulseaudio \
        git \
        gnupg \
        iproute2 \
        xz-utils \
        qt6-wayland \
        libdecor-0-plugin-1-cairo \
        wayland-protocols \
        libwayland-client0 \
        libwayland-server0 \
        libwayland-egl1 && \
    # Install NVIDIA drivers if enabled
    if [ "$INSTALL_NVIDIA_DRIVERS" = "true" ]; then \
        apt-get install -qqy --no-install-recommends software-properties-common && \
        (add-apt-repository -y ppa:graphics-drivers/ppa || echo "Warning: Failed to add graphics drivers PPA") && \
        apt-get update -qq && \
        (apt-get install -qqy --no-install-recommends libnvidia-gl-${NVIDIA_MAJOR_VERSION}=${NVIDIA_FALLBACK_VERSION} || \
         apt-get install -qqy --no-install-recommends libnvidia-gl-${NVIDIA_MAJOR_VERSION} || \
         echo "Warning: NVIDIA driver installation failed, will be handled at runtime") || true; \
    fi && \
    # Cleanup
    apt-get purge -qqy --auto-remove software-properties-common && \
    apt-get autoremove -y && \
    apt-get autoclean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Copy tools from builder
COPY --from=builder /usr/local/bin/tini /usr/local/bin/tini
COPY --from=builder /usr/local/bin/gosu /usr/local/bin/gosu
COPY --from=builder /s6-overlay.tar.xz /s6-overlay.tar.xz
RUN tar -C / -Jxpf /s6-overlay.tar.xz && \
    rm /s6-overlay.tar.xz

# Configure sudo
RUN echo "${CONTAINER_USERNAME} ALL=(ALL) NOPASSWD:SETENV: /usr/local/bin/docker-entrypoint.sh" > /etc/sudoers.d/passwordless && \
    chmod 440 /etc/sudoers.d/passwordless && \
    visudo -cf /etc/sudoers.d/passwordless

# Create user and group
RUN userdel -r ubuntu 2>/dev/null || true && \
    groupadd --gid ${CONTAINER_GID} ${CONTAINER_USERNAME} && \
    useradd --create-home \
            --shell /bin/bash \
            --uid ${CONTAINER_UID} \
            --gid ${CONTAINER_GID} \
            --groups adm,video,audio,pulse \
            ${CONTAINER_USERNAME}

# Configure log directory
RUN mkdir -p /var/log/container && \
    chgrp -R adm /var/log/container && \
    chmod -R g+w /var/log/container && \
    find /var/log/container -type d -exec chmod g+s {} \; && \
    mkdir -p /run/user/${CONTAINER_UID} && \
    chown ${CONTAINER_UID}:${CONTAINER_GID} /run/user/${CONTAINER_UID} && \
    chmod 700 /run/user/${CONTAINER_UID}

# Copy configuration files
COPY entrypoint.d /etc/entrypoint.d
COPY --chmod=755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

ARG LANG=en_US.UTF-8

# Configure locale
RUN locale-gen ${LANG:-en_US.UTF-8}
ENV LANG=${LANG:-en_US.UTF-8} \
    LANGUAGE=${LANG:-en_US:en} \
    LC_ALL=${LANG:-en_US.UTF-8}

    
# Switch to non-root user
USER ${CONTAINER_USERNAME}
WORKDIR /home/${CONTAINER_USERNAME}

# Create user directories
RUN mkdir -p .cache .config .local/share .local/bin && \
    touch .local/share/ubuntu-docker.log

# Environment variables for XDG and Wayland
ENV XDG_RUNTIME_DIR=/run/user/${CONTAINER_UID} \
    XDG_CONFIG_HOME=/home/${CONTAINER_USERNAME}/.config \
    XDG_CACHE_HOME=/home/${CONTAINER_USERNAME}/.cache \
    XDG_DATA_HOME=/home/${CONTAINER_USERNAME}/.local/share \
    WAYLAND_DISPLAY=wayland-0

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD pgrep -f docker-entrypoint.sh > /dev/null && \
        [ -d "${XDG_RUNTIME_DIR}" ] || exit 1

# Entrypoint and default command
ENTRYPOINT ["/usr/local/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["/bin/bash"]

# Runtime instructions
# To run with GPU and Wayland:
# docker run --gpus all -v $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY:/run/user/${CONTAINER_UID}/$WAYLAND_DISPLAY -e WAYLAND_DISPLAY=$WAYLAND_DISPLAY ...
# To skip checksum validation during testing:
# docker build --build-arg SKIP_CHECKSUM_VALIDATION=true -t my-ubuntu-wayland .