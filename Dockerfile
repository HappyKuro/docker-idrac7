FROM jlesage/baseimage-gui:debian-13-v4

ENV APP_NAME="iDRAC 7" \
    IDRAC_PORT=443 \
    IDRAC_KMPORT=5900 \
    IDRAC_VPORT=5900 \
    IDRAC_DOWNLOAD_BASE=/software \
    IDRAC_MAIN_CLASS=com.avocent.idrac.kvm.Main \
    DISPLAY_WIDTH=1281 \
    DISPLAY_HEIGHT=1045

COPY keycode-hack.c /tmp/keycode-hack.c
COPY IdracLauncher.java /tmp/IdracLauncher.java
COPY wrapper-src /opt/idrac-wrapper-src
COPY java.security.override /etc/java.security.override

RUN apt-get update && \
    apt-get install -y --no-install-recommends wget gnupg ca-certificates curl libx11-dev libc6-dev gcc xdotool tigervnc-viewer tigervnc-tools && \
    curl -fsSL https://repos.azul.com/azul-repo.key | gpg --dearmor -o /usr/share/keyrings/azul.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/azul.gpg] https://repos.azul.com/zulu/deb stable main" > /etc/apt/sources.list.d/zulu.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends zulu8-jdk && \
    gcc -o /keycode-hack.so /tmp/keycode-hack.c -shared -s -ldl -fPIC && \
    mkdir -p /opt/idrac-wrapper && \
    javac -d /opt/idrac-wrapper /tmp/IdracLauncher.java && \
    mkdir -p /app /vmedia /screenshots && \
    chown ${USER_ID}:${GROUP_ID} /app /vmedia /screenshots && \
    rm -f /usr/lib/jvm/zulu8-ca-amd64/jre/lib/security/java.security && \
    apt-get remove -y gcc gnupg libc6-dev && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/* /tmp/keycode-hack.c /tmp/IdracLauncher.java

COPY startapp.sh /startapp.sh
COPY mountiso.sh /mountiso.sh

RUN chmod +x /startapp.sh /mountiso.sh

WORKDIR /app
