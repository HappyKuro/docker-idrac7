#!/bin/sh

set -eu

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

info() {
    echo "$*"
}

die() {
    code="$1"
    shift
    echo "${RED}$*${NC}"
    exit "$code"
}

read_secret() {
    key="$1"
    path="/run/secrets/$2"

    if [ -f "$path" ]; then
        info "Using Docker secret for $key"
        value="$(cat "$path")"
        export "$key=$value"
    fi
}

require_env() {
    key="$1"
    eval "value=\${$key:-}"
    if [ -z "$value" ]; then
        die 1 "Please set $key"
    fi
}

extract_jnlp_argument() {
    name="$1"
    file="$2"
    sed -n "s#.*<argument>${name}=\(.*\)</argument>.*#\1#p" "$file" | head -n 1
}

extract_jnlp_native_href() {
    pattern="$1"
    file="$2"
    sed -n "s#.*<nativelib href=\"\\([^\"]*${pattern}[^\"]*\\)\".*#\\1#p" "$file" | head -n 1
}

download_appliance_file_if_missing() {
    target="$1"
    remote_name="$2"

    if [ -f "$target" ]; then
        return 0
    fi

    url="https://${IDRAC_HOST}:${IDRAC_PORT}${IDRAC_DOWNLOAD_BASE}/${remote_name}"
    info "Downloading ${remote_name} from ${url}"

    if wget -O "$target" "$url" --no-check-certificate; then
        return 0
    fi

    rm -f "$target"
    die 2 "Failed to download ${remote_name}. This image expects the legacy Java console artifacts under ${IDRAC_DOWNLOAD_BASE}."
}

try_download_appliance_file_if_missing() {
    target="$1"
    remote_name="$2"

    if [ -f "$target" ]; then
        return 0
    fi

    url="https://${IDRAC_HOST}:${IDRAC_PORT}${IDRAC_DOWNLOAD_BASE}/${remote_name}"
    info "Trying ${remote_name} from ${url}"

    if wget -O "$target" "$url" --no-check-certificate; then
        return 0
    fi

    rm -f "$target"
    return 1
}

download_absolute_if_missing() {
    target="$1"
    absolute_url="$2"

    if [ -f "$target" ]; then
        return 0
    fi

    info "Downloading $(basename "$target") from ${absolute_url}"

    if wget -O "$target" "$absolute_url" --no-check-certificate; then
        return 0
    fi

    rm -f "$target"
    die 2 "Failed to download ${absolute_url}."
}

extract_native_libs() {
    archive="$1"
    expected_path="$2"

    if [ -f "$expected_path" ]; then
        return 0
    fi

    info "Extracting native libraries from ${archive}"
    jar -xf "$archive"

    if [ ! -f "$expected_path" ]; then
        die 3 "Expected native library ${expected_path} was not found after extracting ${archive}."
    fi
}

patch_certificate_jni_if_needed() {
    : "${IDRAC_BYPASS_CERT_JNI:=false}"

    if [ "$IDRAC_BYPASS_CERT_JNI" != "true" ]; then
        return 0
    fi

    info "Compiling certificate JNI wrapper override"

    override_dir="$(mktemp -d)"
    patch_dir="$(mktemp -d)"
    patched_jar="$(mktemp /app/avctKVM.jar.patched.XXXXXX)"

    cleanup_patch_dirs() {
        rm -rf "$override_dir" "$patch_dir"
        rm -f "$patched_jar"
    }

    if ! javac -cp /app/avctKVM.jar -d "$override_dir" /opt/idrac-wrapper-src/com/avocent/app/security/X509CertificateJNI.java; then
        cleanup_patch_dirs
        die 4 "Failed to compile the certificate JNI wrapper override."
    fi

    (
        cd "$patch_dir" && \
        jar xf /app/avctKVM.jar && \
        rm -f META-INF/*.SF META-INF/*.RSA META-INF/*.DSA && \
        mkdir -p com/avocent/app/security && \
        cp "${override_dir}/com/avocent/app/security/X509CertificateJNI.class" com/avocent/app/security/X509CertificateJNI.class && \
        jar cf "$patched_jar" .
    ) || {
        cleanup_patch_dirs
        die 4 "Failed to patch avctKVM.jar with the certificate JNI override."
    }

    mv "$patched_jar" /app/avctKVM.jar
    rm -rf "$override_dir" "$patch_dir"
}

start_vnc_mode() {
    info "${GREEN}Initialization complete, starting VNC viewer mode${NC}"

    set -- vncviewer \
        -AlertOnFatalError=0 \
        -ReconnectOnError=0 \
        -Shared=1 \
        -RemoteResize=0 \
        -MenuKey=F8 \
        -SecurityTypes="${IDRAC_VNC_SECURITY_TYPES}" \
        -GnuTLSPriority="${IDRAC_VNC_GNUTLS_PRIORITY}"

    if [ -n "${IDRAC_VNC_PASSWORD:-}" ]; then
        passwd_file="/tmp/idrac-vnc.passwd"
        printf '%s\n' "${IDRAC_VNC_PASSWORD}" | vncpasswd -f > "${passwd_file}"
        chmod 600 "${passwd_file}"
        set -- "$@" -PasswordFile "${passwd_file}"
    fi

    if [ -n "${IDRAC_EXTRA_VNC_ARGS:-}" ]; then
        # shellcheck disable=SC2086
        set -- "$@" $IDRAC_EXTRA_VNC_ARGS
    fi

    exec "$@" "${IDRAC_HOST}::${IDRAC_VNC_PORT}"
}

prepare_launch_parameters() {
    JAVA_USER_ARG="${IDRAC_USER:-}"
    JAVA_PASSWORD_ARG="${IDRAC_PASSWORD:-}"
    JAVA_IDRAC_KMPORT="$IDRAC_KMPORT"
    JAVA_IDRAC_VPORT="$IDRAC_VPORT"
    JAVA_EXTRA_FIXED_ARGS=""
    KVM_JAR_URL=""
    KVM_NATIVE_URL=""
    VM_NATIVE_URL=""

    if [ -z "${IDRAC_JNLP_FILE:-}" ]; then
        JAVA_EXTRA_FIXED_ARGS=" vm=1 reconnect=2 chat=1 F1=1 custom=0 scaling=15 minwinheight=100 minwinwidth=100 videoborder=0"
        return 0
    fi

    if [ ! -f "${IDRAC_JNLP_FILE}" ]; then
        die 1 "IDRAC_JNLP_FILE does not exist: ${IDRAC_JNLP_FILE}"
    fi

    info "Using launcher parameters from ${IDRAC_JNLP_FILE}"

    JAVA_USER_ARG="$(extract_jnlp_argument user "${IDRAC_JNLP_FILE}")"
    JAVA_PASSWORD_ARG="$(extract_jnlp_argument passwd "${IDRAC_JNLP_FILE}")"
    JAVA_IDRAC_KMPORT="$(extract_jnlp_argument kmport "${IDRAC_JNLP_FILE}")"
    JAVA_IDRAC_VPORT="$(extract_jnlp_argument vport "${IDRAC_JNLP_FILE}")"

    if [ -n "${IDRAC_USER:-}" ]; then
        JAVA_USER_ARG="${IDRAC_USER}"
    fi
    if [ -n "${IDRAC_PASSWORD:-}" ]; then
        JAVA_PASSWORD_ARG="${IDRAC_PASSWORD}"
    fi
    if [ -n "${IDRAC_KMPORT:-}" ]; then
        JAVA_IDRAC_KMPORT="${IDRAC_KMPORT}"
    fi
    if [ -n "${IDRAC_VPORT:-}" ]; then
        JAVA_IDRAC_VPORT="${IDRAC_VPORT}"
    fi

    for arg_name in vm title reconnect chat F1 custom scaling minwinheight minwinwidth videoborder version apcp; do
        arg_value="$(extract_jnlp_argument "${arg_name}" "${IDRAC_JNLP_FILE}")"
        if [ -n "${arg_value}" ]; then
            JAVA_EXTRA_FIXED_ARGS="${JAVA_EXTRA_FIXED_ARGS} ${arg_name}=${arg_value}"
        fi
    done

    KVM_JAR_URL="$(sed -n 's#.*<jar href=\"\([^\"]*avctKVM.jar\)\".*#\1#p' "${IDRAC_JNLP_FILE}" | head -n 1)"
    KVM_NATIVE_URL="$(extract_jnlp_native_href 'avctKVMIOLinux64.jar' "${IDRAC_JNLP_FILE}")"
    VM_NATIVE_URL="$(extract_jnlp_native_href 'avctVMAPI_DLLLinux64.jar' "${IDRAC_JNLP_FILE}")"

    if [ -z "${JAVA_USER_ARG}" ] || [ -z "${JAVA_PASSWORD_ARG}" ] || [ -z "${JAVA_IDRAC_KMPORT}" ]; then
        die 1 "The supplied JNLP file is missing required launch arguments."
    fi
}

download_console_artifacts() {
    if [ -n "${KVM_JAR_URL}" ]; then
        download_absolute_if_missing avctKVM.jar "${KVM_JAR_URL}"
    else
        download_appliance_file_if_missing avctKVM.jar avctKVM.jar
    fi

    if [ -n "${KVM_NATIVE_URL}" ]; then
        download_absolute_if_missing lib/avctKVMIOLinux64.jar "${KVM_NATIVE_URL}"
    else
        download_appliance_file_if_missing lib/avctKVMIOLinux64.jar avctKVMIOLinux64.jar
    fi

    if [ -n "${VM_NATIVE_URL}" ]; then
        download_absolute_if_missing lib/avctVMAPI_DLLLinux64.jar "${VM_NATIVE_URL}"
        return 0
    fi

    if [ -n "${IDRAC_JNLP_FILE:-}" ]; then
        download_appliance_file_if_missing lib/avctVMAPI_DLLLinux64.jar avctVMAPI_DLLLinux64.jar
        return 0
    fi

    if ! try_download_appliance_file_if_missing lib/avctVMAPI_DLLLinux64.jar avctVMAPI_DLLLinux64.jar; then
        download_appliance_file_if_missing lib/avctVMLinux64.jar avctVMLinux64.jar
    fi
}

extract_console_artifacts() {
    cd /app/lib
    extract_native_libs avctKVMIOLinux64.jar libavctKVMIO.so

    # Prefer the newer iDRAC7 VMAPI bundle when it exists, but keep the
    # older avctVMLinux64 fallback for firmware that still uses it.
    if [ -f avctVMAPI_DLLLinux64.jar ]; then
        extract_native_libs avctVMAPI_DLLLinux64.jar libVMAPI_DLL.so
    else
        extract_native_libs avctVMLinux64.jar libavmLinux64.so
    fi

    cd /app
}

enable_keycode_hack_if_needed() {
    if [ -n "${IDRAC_KEYCODE_HACK:-}" ]; then
        info "Enabling keycode hack"
        export LD_PRELOAD=/keycode-hack.so
    fi
}

start_virtual_media_if_requested() {
    java_pid="$1"
    media_file="${VIRTUAL_MEDIA:-${VIRTUAL_ISO:-}}"

    if [ -n "$media_file" ] && [ -f "/vmedia/$media_file" ]; then
        /mountiso.sh "$media_file" "$java_pid" &
    fi
}

start_java_mode() {
    cd /app
    mkdir -p lib

    prepare_launch_parameters
    download_console_artifacts
    extract_console_artifacts
    enable_keycode_hack_if_needed
    patch_certificate_jni_if_needed

    info "${GREEN}Initialization complete, starting virtual console${NC}"

    set -- java

    if [ -n "${IDRAC_EXTRA_JAVA_OPTS:-}" ]; then
        # shellcheck disable=SC2086
        set -- "$@" $IDRAC_EXTRA_JAVA_OPTS
    fi

    set -- "$@" \
        -Djava.security.properties=/etc/java.security.override \
        -Didrac.main.class="${IDRAC_MAIN_CLASS}" \
        -cp "/opt/idrac-wrapper:avctKVM.jar" \
        -Djava.library.path=./lib \
        IdracLauncher \
        "ip=${IDRAC_HOST}" \
        "kmport=${JAVA_IDRAC_KMPORT}" \
        "vport=${JAVA_IDRAC_VPORT}" \
        "user=${JAVA_USER_ARG}" \
        "passwd=${JAVA_PASSWORD_ARG}" \
        "apcp=1" \
        "version=2" \
        "vmprivilege=true" \
        "helpurl=${IDRAC_HELPURL}"

    if [ -n "${JAVA_EXTRA_FIXED_ARGS}" ]; then
        # shellcheck disable=SC2086
        set -- "$@" $JAVA_EXTRA_FIXED_ARGS
    fi

    if [ -n "${IDRAC_EXTRA_KVM_ARGS:-}" ]; then
        # shellcheck disable=SC2086
        set -- "$@" $IDRAC_EXTRA_KVM_ARGS
    fi

    "$@" &
    java_pid="$!"

    start_virtual_media_if_requested "$java_pid"
    wait "$java_pid"
}

load_configuration() {
    info "Starting iDRAC 7 container"

    read_secret IDRAC_HOST idrac_host
    read_secret IDRAC_PORT idrac_port
    read_secret IDRAC_USER idrac_user
    read_secret IDRAC_PASSWORD idrac_password
    read_secret IDRAC_VNC_PASSWORD idrac_vnc_password
    read_secret IDRAC_JNLP_FILE idrac_jnlp_file

    : "${IDRAC_PORT:=443}"
    : "${IDRAC_MODE:=java}"
    : "${IDRAC_KMPORT:=5900}"
    : "${IDRAC_VPORT:=5900}"
    : "${IDRAC_DOWNLOAD_BASE:=/software}"
    : "${IDRAC_MAIN_CLASS:=com.avocent.idrac.kvm.Main}"
    : "${IDRAC_HELPURL:=https://${IDRAC_HOST}:${IDRAC_PORT}/help/contents.html}"
    : "${IDRAC_VNC_PORT:=5901}"
    : "${IDRAC_VNC_SECURITY_TYPES:=TLSVnc,VncAuth,TLSNone,None}"
    : "${IDRAC_VNC_GNUTLS_PRIORITY:=NORMAL}"

    require_env IDRAC_HOST

    case "${IDRAC_MODE}" in
        java)
            if [ -z "${IDRAC_JNLP_FILE:-}" ]; then
                require_env IDRAC_USER
                require_env IDRAC_PASSWORD
            fi
            ;;
        vnc)
            ;;
        *)
            die 1 "Unsupported IDRAC_MODE: ${IDRAC_MODE}"
            ;;
    esac

    info "Environment ok"
}

main() {
    load_configuration

    if [ "${IDRAC_MODE}" = "vnc" ]; then
        start_vnc_mode
    fi

    start_java_mode
}

main "$@"
