FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq \
 && apt-get install -qqy --no-install-recommends \
      ca-certificates \
      sudo \
      tzdata \
      wget \
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
      git gnupg iproute2 \
      && apt-get install -qqy --no-install-recommends software-properties-common \
      && (add-apt-repository -y ppa:graphics-drivers/ppa || true) \
      && apt-get purge -qqy --auto-remove software-properties-common \
      && apt-get install -qqy --no-install-recommends libnvidia-gl-550=550.120-0ubuntu0.22.04.1 \
      && rm -rf /var/lib/apt/lists/*

# add tini
RUN ARCH="$(dpkg --print-architecture | awk -F- '{ print $NF }')" \
 && wget -q -O /tmp/release.json "https://api.github.com/repos/krallin/tini/releases/latest" \
 && grep -E '"browser_download_url":.+'$ARCH'' /tmp/release.json | grep -v -E ".(asc|sig)" | head -n1 | cut -d '"' -f4 > /tmp/release.txt \
 && wget -q -O /usr/local/bin/tini "$(cat /tmp/release.txt)" \
 && chmod +x /usr/local/bin/tini \
 && rm -f /tmp/release.*

# add gosu
RUN ARCH="$(dpkg --print-architecture | awk -F- '{ print $NF }')" \
 && wget -q -O /tmp/release.json "https://api.github.com/repos/tianon/gosu/releases/latest" \
 && grep -E '"browser_download_url":.+'$ARCH'' /tmp/release.json | grep -v -E ".(asc|sig)" | head -n1 | cut -d '"' -f4 > /tmp/release.txt \
 && wget -q -O /usr/local/bin/gosu "$(cat /tmp/release.txt)" \
 && chmod +x /usr/local/bin/gosu \
 && rm -f /tmp/release.* \
 && gosu nobody true

# add s6-overlay
RUN ARCH="$(dpkg --print-architecture | awk -F- '{ print $NF }')" \
 && wget -q -O /tmp/release.json "https://api.github.com/repos/just-containers/s6-overlay/releases/38080409" \
 && grep -E '"browser_download_url":.+'$ARCH'\.tar\.gz' /tmp/release.json | grep -v -E ".(asc|sig)" | head -n1 | cut -d '"' -f4 > /tmp/release.txt \
 && wget -q -O s6-overlay.tar.gz "$(cat /tmp/release.txt)" \
 && mkdir s6-overlay \
 && tar zxfh s6-overlay.tar.gz -C s6-overlay/ \
 && find s6-overlay -mindepth 1 -maxdepth 1 -exec sh -c 'cp -rl {}/* /$(basename {})' \; \
 && mv s6-overlay/init /init \
 && rm -rf /tmp/release.* s6-overlay*

# allow passwordless sudo to entrypoint
RUN /bin/echo -e "\
\n\
# Allow members of adm to execute the entrypoint\n\
%adm ALL=(ALL) NOPASSWD:SETENV: /usr/local/bin/emulationstation-bootstrap\n\
manzolo ALL=(ALL) NOPASSWD:ALL\n\
" \
  >/etc/sudoers.d/passwordless

# Assicurati che il file sudoers sia corretto (questo comando verifica la sintassi)
RUN visudo -cf /etc/sudoers.d/passwordless

#RUN id 1000
#RUN userdel -r 1000 && groupdel 1000

# Crea il gruppo manzolo
RUN addgroup --gid 1000 manzolo \
    && adduser --gecos "" \
    --shell /bin/bash \
    --uid 1000 \
    --gid 1000 \
    --disabled-password \
    manzolo \
    && adduser manzolo sudo


# make /var/log writeable by adm group
RUN chgrp -R adm /var/log \
 && chmod -R g+w /var/log \
 && find /var/log -type d -exec chmod g+s {} \;

# add manzolo user to multimedia
RUN for group in video audio voice pulse rtkit \
     ; do \
         adduser manzolo $group ; \
     done

# copy files to the container
COPY entrypoint.d /etc/entrypoint.d
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# change to the manzolo user
USER manzolo
WORKDIR /home/manzolo

# create common directories, some apps will fail if they don't exist
RUN mkdir -p \
  /home/manzolo/.cache \
  /home/manzolo/.config \
  /home/manzolo/.local/share

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
