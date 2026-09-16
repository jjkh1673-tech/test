# syntax=docker/dockerfile:1
# ============================================================================
# CloudDesk-RDP — container deployment image
# ----------------------------------------------------------------------------
# This is the ALTERNATIVE (container) deployment path, preserved from the
# original CloudDesk-RDP project. For a normal cloud VPS, prefer the native
# installer: sudo ./install.sh  (see README.md).
#
# The image deliberately avoids: full desktop suites, snapd, databases and
# other heavy services. It targets ~1 GB RAM / 1 vCPU class machines.
# Security note: NO default password exists. You must provide RDP_PASSWORD
# as a runtime environment variable, otherwise the container refuses to start.
# ============================================================================

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# --- Core stack: minimal XFCE + xrdp + helpers (same set as install.sh) ---
RUN apt-get update && apt-get install -y --no-install-recommends \
    xrdp \
    xorgxrdp \
    xfce4-session \
    xfwm4 \
    xfdesktop4 \
    xfce4-panel \
    xfce4-settings \
    thunar \
    xfce4-terminal \
    dbus \
    dbus-x11 \
    gvfs \
    sudo \
    ca-certificates \
    curl \
    wget \
    unzip \
    zip \
    file \
    nano \
    less \
    procps \
    psmisc \
    htop \
    iproute2 \
    net-tools \
    fonts-dejavu-core \
    fonts-liberation \
    adwaita-icon-theme \
    && rm -rf /var/lib/apt/lists/*

# --- Optional nice-to-haves: install if available, never fail the build ---
RUN apt-get update \
    && for p in plank greybird-gtk-theme xarchiver thunar-archive-plugin lxpolkit xterm; do \
           apt-get install -y --no-install-recommends "$p" \
               || echo "[container] optional package not available, skipped: $p"; \
       done \
    && rm -rf /var/lib/apt/lists/*

# --- Firefox (official Mozilla APT repository) ---
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64|arm64) ;; \
        *) \
            echo "Unsupported architecture: ${arch}" >&2; \
            exit 1; \
            ;; \
    esac; \
    echo "Configuring Mozilla APT repository for ${arch}..."; \
    install -d -m 0755 /etc/apt/keyrings; \
    rm -f /etc/apt/keyrings/packages.mozilla.org.asc; \
    curl \
        --fail \
        --show-error \
        --silent \
        --location \
        --retry 5 \
        --retry-delay 3 \
        --retry-all-errors \
        --connect-timeout 30 \
        --max-time 120 \
        "https://packages.mozilla.org/apt/repo-signing-key.gpg" \
        --output /etc/apt/keyrings/packages.mozilla.org.asc; \
    test -s /etc/apt/keyrings/packages.mozilla.org.asc; \
    fingerprint="$(gpg --show-keys --with-colons \
        /etc/apt/keyrings/packages.mozilla.org.asc \
        | awk -F: '$1 == "fpr" {print $10; exit}')"; \
    echo "Mozilla repository key fingerprint: ${fingerprint}"; \
    test "${fingerprint}" = "35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3"; \
    echo "Mozilla repository signing key verified."; \
    printf '%s\n' \
        "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
        > /etc/apt/sources.list.d/mozilla.list; \
    printf '%s\n' \
        "Package: *" \
        "Pin: origin packages.mozilla.org" \
        "Pin-Priority: 1000" \
        > /etc/apt/preferences.d/mozilla; \
    printf '%s\n' \
        "Package: firefox" \
        "Pin: release o=Ubuntu" \
        "Pin-Priority: -1" \
        >> /etc/apt/preferences.d/mozilla; \
    apt-get update; \
    apt-get install -y --no-install-recommends firefox; \
    command -v firefox; \
    firefox --version; \
    test -x /usr/bin/firefox; \
    test -f /usr/share/applications/firefox.desktop; \
    ln -sf /usr/share/applications/firefox.desktop \
        /usr/share/applications/firefox-esr.desktop; \
    test -L /usr/share/applications/firefox-esr.desktop; \
    readlink -f /usr/share/applications/firefox-esr.desktop; \
    if command -v update-desktop-database >/dev/null 2>&1; then \
        update-desktop-database /usr/share/applications; \
    fi; \
    rm -rf /var/lib/apt/lists/*

# --- Project files: shared config templates, assets, helper CLI ---
COPY config/ /opt/clouddesk/config/
COPY assets/wallpaper.png /usr/share/clouddesk/wallpaper.png
COPY bin/clouddesk /usr/local/bin/clouddesk
COPY start.sh /start.sh
RUN chmod 755 /start.sh /usr/local/bin/clouddesk

# --- xrdp session launcher (same file the VPS installer deploys) ---
COPY config/xrdp/startwm.sh /etc/xrdp/startwm.sh
RUN chmod 755 /etc/xrdp/startwm.sh

# --- Firefox policy (same file the VPS installer deploys) ---
RUN mkdir -p /etc/firefox/policies \
    && cp /opt/clouddesk/config/firefox/policies.json /etc/firefox/policies/policies.json

# --- Tuned nano (same managed block the VPS installer writes) ---
RUN sed 's/^# __NANO_EXTRAS__$/set indicator/' /opt/clouddesk/config/nano/nanorc.block >> /etc/nanorc

# --- RDP user account (password supplied at RUNTIME via RDP_PASSWORD) ---
RUN if id ubuntu >/dev/null 2>&1; then \
        usermod -s /bin/bash ubuntu; \
    else \
        useradd -m -s /bin/bash ubuntu; \
    fi \
    && usermod -aG sudo ubuntu \
    && mkdir -p /home/ubuntu \
    && chown -R ubuntu:ubuntu /home/ubuntu

# --- Desktop configuration (same templates the VPS installer applies) ---
RUN GTK_XML=/opt/clouddesk/config/xfce4/xsettings.xml \
    && XFWM_XML=/opt/clouddesk/config/xfce4/xfwm4.xml \
    && DESK_XML=/opt/clouddesk/config/xfce4/xfce4-desktop.xml \
    && CONF=/home/ubuntu/.config/xfce4/xfconf/xfce-perchannel-xml \
    && mkdir -p "$CONF" \
    && sed 's/__GTK_THEME__/Greybird/' "$GTK_XML" > "$CONF/xsettings.xml" \
    && sed 's/__XFWM_THEME__/Greybird/' "$XFWM_XML" > "$CONF/xfwm4.xml" \
    && sed 's|__WALLPAPER__|/usr/share/clouddesk/wallpaper.png|g' "$DESK_XML" > "$CONF/xfce4-desktop.xml" \
    && cp /opt/clouddesk/config/xfce4/xfce4-panel.xml "$CONF/xfce4-panel.xml"

# --- Plank dock (Firefox / Terminal / Files) + desktop launchers ---
RUN DOCK=/home/ubuntu/.config/plank/dock1 \
    && LAUNCH="$DOCK/launchers" \
    && mkdir -p "$LAUNCH" /home/ubuntu/Desktop /home/ubuntu/Downloads /home/ubuntu/Workspace \
    && sed 's/__FIREFOX_ID__/firefox-esr.desktop/g' /opt/clouddesk/config/plank/settings.template > "$DOCK/settings" \
    && for id in firefox-esr xfce4-terminal thunar; do \
           sed "s/__DESKTOP_ID__/${id}.desktop/" /opt/clouddesk/config/plank/launcher.dockitem.template \
               > "$LAUNCH/${id}.dockitem"; \
       done \
    && cp /opt/clouddesk/config/desktop/Files.desktop /home/ubuntu/Desktop/Files.desktop \
    && cp /opt/clouddesk/config/desktop/Settings.desktop /home/ubuntu/Desktop/Settings.desktop \
    && cp /opt/clouddesk/config/desktop/Terminal.desktop /home/ubuntu/Desktop/Terminal.desktop \
    && sed 's/^Name=.*/Name=Firefox/' /usr/share/applications/firefox-esr.desktop \
        > /home/ubuntu/Desktop/Firefox.desktop \
    && chmod 644 /home/ubuntu/Desktop/*.desktop

# --- polkit: avoid colord password prompts in RDP sessions ---
RUN mkdir -p /etc/polkit-1/rules.d /etc/polkit-1/localauthority/50-local.d \
    && cp /opt/clouddesk/config/polkit/49-clouddesk-colord.rules /etc/polkit-1/rules.d/ \
    && cp /opt/clouddesk/config/polkit/49-clouddesk-colord.pkla /etc/polkit-1/localauthority/50-local.d/

# --- Runtime dirs ---
RUN mkdir -p /run/dbus /run/user/1000 /var/run/xrdp /home/ubuntu/.cache \
    && chown -R ubuntu:ubuntu /home/ubuntu \
    && chown ubuntu:ubuntu /run/user/1000 \
    && chown xrdp:xrdp /var/run/xrdp

EXPOSE 3389

# RDP_PASSWORD is REQUIRED at runtime (see start.sh).
CMD ["/start.sh"]
