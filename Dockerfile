FROM jlesage/baseimage-gui:debian-13-v4

ENV APP_NAME="iDRAC 7" \
    IDRAC_PORT=443 \
    IDRAC_KMPORT=5900 \
    IDRAC_VPORT=5900 \
    IDRAC_DOWNLOAD_BASE=/software \
    IDRAC_MAIN_CLASS=com.avocent.idrac.kvm.Main \
    DISPLAY_WIDTH=1281 \
    DISPLAY_HEIGHT=1045

COPY src/native/keycode-hack.c /tmp/keycode-hack.c
COPY src/java/IdracLauncher.java /tmp/IdracLauncher.java
COPY src/java/wrapper-src /opt/idrac-wrapper-src
COPY config/java/java.security.override /etc/java.security.override
COPY assets/branding/dell-logo.png /opt/noVNC/app/images/icons/dell-logo.png
COPY web/idrac-virtual-media.js /opt/noVNC/app/idrac-virtual-media.js
COPY scripts/patch-novnc-index.py /tmp/patch-novnc-index.py
COPY config/nginx/default_site.conf /opt/base/etc/nginx/default_site.conf
COPY config/nginx/virtual-media-api.conf /opt/base/etc/nginx/include/virtual-media-api.conf

RUN apt-get update && \
    apt-get install -y --no-install-recommends wget gnupg ca-certificates curl libx11-dev libc6-dev gcc xdotool wmctrl tigervnc-viewer tigervnc-tools python3 && \
    curl -fsSL https://repos.azul.com/azul-repo.key | gpg --dearmor -o /usr/share/keyrings/azul.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/azul.gpg] https://repos.azul.com/zulu/deb stable main" > /etc/apt/sources.list.d/zulu.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends zulu8-jdk && \
    gcc -o /keycode-hack.so /tmp/keycode-hack.c -shared -s -ldl -fPIC && \
    mkdir -p /opt/idrac-wrapper && \
    javac -d /opt/idrac-wrapper /tmp/IdracLauncher.java && \
    python3 /tmp/patch-novnc-index.py && \
    mkdir -p /app /vmedia /screenshots && \
    chown ${USER_ID}:${GROUP_ID} /app /vmedia /screenshots && \
    rm -f /usr/lib/jvm/zulu8-ca-amd64/jre/lib/security/java.security && \
    apt-get remove -y gcc gnupg libc6-dev && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/* /tmp/keycode-hack.c /tmp/IdracLauncher.java /tmp/patch-novnc-index.py

COPY scripts/startapp.sh /startapp.sh
COPY scripts/mountiso.sh /mountiso.sh
COPY scripts/virtual-media-ui.sh /virtual-media-ui.sh
COPY scripts/virtual-media-api.py /virtual-media-api.py

RUN chmod +x /startapp.sh /mountiso.sh /virtual-media-ui.sh /virtual-media-api.py

WORKDIR /app
