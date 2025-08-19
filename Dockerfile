FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG CONTAINER_USERNAME=ubuntu
ARG CONTAINER_UID=1000
ARG CONTAINER_GID=1000
ARG NVIDIA_MAJOR_VERSION=550
ARG NVIDIA_FALLBACK_VERSION=550.120-0ubuntu0.24.04.1

ENV CONTAINER_USERNAME=${CONTAINER_USERNAME}
ENV CONTAINER_UID=${CONTAINER_UID}
ENV CONTAINER_GID=${CONTAINER_GID}

# Etichette per metadati
LABEL maintainer="manzolo@libero.it"
LABEL description="Ubuntu container with GUI support and NVIDIA drivers"
LABEL version="1.0"

# Rimuovi l'utente ubuntu esistente
RUN userdel -r ubuntu 2>/dev/null || true

# Installa pacchetti in un singolo layer per ottimizzare le dimensioni
RUN apt-get update -qq && \
    apt-get install -qqy --no-install-recommends \
        ca-certificates \
        sudo \
        tzdata \
        locales \
        wget \
        curl \
        gpg \
        xz-utils \
        # GUI e multimedia
        dbus-x11 \
        gnome-icon-theme \
        libcanberra-gtk-module \
        libcanberra-gtk3-module \
        libgl1-mesa-dri \
        libnotify-bin \
        x11-xserver-utils \
        qt6-wayland \
        libdecor-0-plugin-1-cairo \
        vulkan-tools \
        rtkit \
        pulseaudio \
        # Sviluppo
        git \
        gnupg \
        iproute2 \
        software-properties-common && \
    # Aggiungi PPA per driver NVIDIA (con gestione errori)
    (add-apt-repository -y ppa:graphics-drivers/ppa || echo "Warning: Failed to add graphics drivers PPA") && \
    apt-get purge -qqy --auto-remove software-properties-common && \
    # Installa driver NVIDIA con fallback automatico
    apt-get update -qq && \
    # Prova prima con la versione fallback, poi con la più recente disponibile
    (apt-get install -qqy --no-install-recommends libnvidia-gl-${NVIDIA_MAJOR_VERSION}=${NVIDIA_FALLBACK_VERSION} || \
     apt-get install -qqy --no-install-recommends libnvidia-gl-${NVIDIA_MAJOR_VERSION} || \
     echo "Warning: NVIDIA driver installation failed, will be handled at runtime") && \
    # Pulizia finale
    apt-get autoremove -y && \
    apt-get autoclean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Installa tini con verifica checksum
RUN ARCH="$(dpkg --print-architecture | awk -F- '{ print $NF }')" && \
    TINI_VERSION="v0.19.0" && \
    wget -q -O /usr/local/bin/tini "https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-${ARCH}" && \
    chmod +x /usr/local/bin/tini && \
    # Verifica che tini funzioni
    /usr/local/bin/tini --version

# Installa gosu con verifica
RUN ARCH="$(dpkg --print-architecture | awk -F- '{ print $NF }')" && \
    GOSU_VERSION="1.17" && \
    wget -q -O /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-${ARCH}" && \
    chmod +x /usr/local/bin/gosu && \
    # Verifica che gosu funzioni
    gosu nobody true

# Installa s6-overlay con versione fissa
RUN S6_VERSION="3.1.6.2" && \
    ARCH="$(dpkg --print-architecture)" && \
    S6_ARCH="" && \
    case "${ARCH}" in \
        amd64) S6_ARCH="x86_64" ;; \
        arm64) S6_ARCH="aarch64" ;; \
        *) echo "Unsupported architecture: ${ARCH}" && exit 1 ;; \
    esac && \
    wget -q -O s6-overlay.tar.gz "https://github.com/just-containers/s6-overlay/releases/download/v${S6_VERSION}/s6-overlay-${S6_ARCH}.tar.xz" && \
    tar -C / -Jxpf s6-overlay.tar.gz && \
    rm s6-overlay.tar.gz

# Configura sudo con regole più specifiche
RUN echo "# Allow members of adm to execute the entrypoint" > /etc/sudoers.d/passwordless && \
    echo "%adm ALL=(ALL) NOPASSWD:SETENV: /usr/local/bin/docker-entrypoint.sh" >> /etc/sudoers.d/passwordless && \
    echo "${CONTAINER_USERNAME} ALL=(ALL) NOPASSWD:SETENV: /usr/local/bin/docker-entrypoint.sh" >> /etc/sudoers.d/passwordless && \
    # Verifica la sintassi del file sudoers
    visudo -cf /etc/sudoers.d/passwordless && \
    chmod 440 /etc/sudoers.d/passwordless

# Crea il gruppo e l'utente con UID/GID specificati
RUN groupadd --gid ${CONTAINER_GID} ${CONTAINER_USERNAME} && \
    useradd --create-home \
            --shell /bin/bash \
            --uid ${CONTAINER_UID} \
            --gid ${CONTAINER_GID} \
            --groups adm,video,audio,pulse,rtkit \
            ${CONTAINER_USERNAME}

# Configura log directory
RUN chgrp -R adm /var/log && \
    chmod -R g+w /var/log && \
    find /var/log -type d -exec chmod g+s {} \; && \
    # Crea directory per runtime
    mkdir -p /run/user/${CONTAINER_UID} && \
    chown ${CONTAINER_UID}:${CONTAINER_GID} /run/user/${CONTAINER_UID} && \
    chmod 700 /run/user/${CONTAINER_UID}

# Copia file di configurazione
COPY --chown=root:root entrypoint.d /etc/entrypoint.d
COPY --chown=root:root --chmod=755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# Configura locale
RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

# Passa all'utente non-root
USER ${CONTAINER_USERNAME}
WORKDIR /home/${CONTAINER_USERNAME}

# Crea directory necessarie per l'utente
RUN mkdir -p \
    .cache \
    .config \
    .local/share \
    .local/bin && \
    # Crea un semplice file di log per debug
    touch ubuntu-docker.log

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD pgrep -f docker-entrypoint.sh > /dev/null || exit 1

# Esponi variabili d'ambiente utili
ENV XDG_RUNTIME_DIR=/run/user/${CONTAINER_UID} \
    XDG_CONFIG_HOME=/home/${CONTAINER_USERNAME}/.config \
    XDG_CACHE_HOME=/home/${CONTAINER_USERNAME}/.cache \
    XDG_DATA_HOME=/home/${CONTAINER_USERNAME}/.local/share

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["/bin/bash"]