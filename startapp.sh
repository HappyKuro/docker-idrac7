#!/bin/sh

set -eu

# Container entrypoint used by the baseimage app service.

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

ensure_writable_dir() {
    dir="$1"

    if ! mkdir -p "$dir" 2>/dev/null; then
        return 1
    fi

    probe_file="$(mktemp "${dir}/.write-test.XXXXXX" 2>/dev/null)" || return 1
    rm -f "$probe_file"
    return 0
}

initialize_workdir() {
    APP_WORKDIR="${IDRAC_CACHE_DIR}"
    APP_LIBDIR="${APP_WORKDIR}/lib"
    APP_PREFS_USER_ROOT="${APP_WORKDIR}/.java-prefs/user"
    APP_PREFS_SYSTEM_ROOT="${APP_WORKDIR}/.java-prefs/system"
    fallback_dir="/tmp/idrac-app"

    if ! ensure_writable_dir "${APP_WORKDIR}"; then
        info "Cache directory ${APP_WORKDIR} is not writable, falling back to ${fallback_dir}"
        APP_WORKDIR="${fallback_dir}"
        APP_LIBDIR="${APP_WORKDIR}/lib"
        APP_PREFS_USER_ROOT="${APP_WORKDIR}/.java-prefs/user"
        APP_PREFS_SYSTEM_ROOT="${APP_WORKDIR}/.java-prefs/system"
        ensure_writable_dir "${APP_WORKDIR}" || die 1 "Failed to prepare a writable cache directory."
    fi

    mkdir -p "${APP_LIBDIR}" "${APP_PREFS_USER_ROOT}" "${APP_PREFS_SYSTEM_ROOT}"

    # PRISTINE_KVM_JAR is exactly what the appliance served and is never
    # modified in place; PATCHED_KVM_JAR is the optional cert-shim rebuild.
    # KVM_JAR selects which of the two actually gets launched.
    PRISTINE_KVM_JAR="${APP_WORKDIR}/avctKVM.jar"
    PATCHED_KVM_JAR="${APP_WORKDIR}/avctKVM.patched.jar"
    KVM_JAR="${PRISTINE_KVM_JAR}"

    info "Using cache directory ${APP_WORKDIR}"
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
    patched_jar="$(mktemp "${APP_WORKDIR}/avctKVM.jar.patched.XXXXXX")"

    cleanup_patch_dirs() {
        rm -rf "$override_dir" "$patch_dir"
        rm -f "$patched_jar"
    }

    if ! javac -cp "${PRISTINE_KVM_JAR}" -d "$override_dir" /opt/idrac-wrapper-src/com/avocent/app/security/X509CertificateJNI.java; then
        cleanup_patch_dirs
        die 4 "Failed to compile the certificate JNI wrapper override."
    fi

    # Repack with "jar cfm": a plain "jar cf" silently drops the jar's own
    # META-INF/MANIFEST.MF and substitutes a two-line stub, which loses
    # Main-Class, Class-Path and the applet security attributes Dell ships.
    # Removing just the signature files leaves the manifest safe to reuse.
    (
        cd "$patch_dir" && \
        jar xf "${PRISTINE_KVM_JAR}" && \
        rm -f META-INF/*.SF META-INF/*.RSA META-INF/*.DSA && \
        mkdir -p com/avocent/app/security && \
        cp "${override_dir}/com/avocent/app/security/X509CertificateJNI.class" com/avocent/app/security/X509CertificateJNI.class && \
        if [ -f META-INF/MANIFEST.MF ]; then
            jar cfm "$patched_jar" META-INF/MANIFEST.MF .
        else
            jar cf "$patched_jar" .
        fi
    ) || {
        cleanup_patch_dirs
        die 4 "Failed to patch avctKVM.jar with the certificate JNI override."
    }

    # Never overwrite the cached download. The pristine jar has to stay on
    # disk so that turning IDRAC_BYPASS_CERT_JNI back off actually restores
    # Dell's original certificate check instead of silently reusing a jar
    # that is still patched from an earlier run.
    mv "$patched_jar" "${PATCHED_KVM_JAR}"
    rm -rf "$override_dir" "$patch_dir"
    KVM_JAR="${PATCHED_KVM_JAR}"
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
    JAVA_USER_ARG="${IDRAC_USER}"
    JAVA_PASSWORD_ARG="${IDRAC_PASSWORD}"
    JAVA_IDRAC_KMPORT="$IDRAC_KMPORT"
    JAVA_IDRAC_VPORT="$IDRAC_VPORT"
    JAVA_EXTRA_FIXED_ARGS=" vm=1 reconnect=2 chat=1 F1=1 custom=0 scaling=15 minwinheight=100 minwinwidth=100 videoborder=0"
}

download_console_artifacts() {
    download_appliance_file_if_missing "${PRISTINE_KVM_JAR}" avctKVM.jar
    download_appliance_file_if_missing "${APP_LIBDIR}/avctKVMIOLinux64.jar" avctKVMIOLinux64.jar

    if ! try_download_appliance_file_if_missing "${APP_LIBDIR}/avctVMAPI_DLLLinux64.jar" avctVMAPI_DLLLinux64.jar; then
        download_appliance_file_if_missing "${APP_LIBDIR}/avctVMLinux64.jar" avctVMLinux64.jar
    fi
}

extract_console_artifacts() {
    cd "${APP_LIBDIR}"
    extract_native_libs avctKVMIOLinux64.jar libavctKVMIO.so

    # Prefer the newer iDRAC7 VMAPI bundle when it exists, but keep the
    # older avctVMLinux64 fallback for firmware that still uses it.
    if [ -f avctVMAPI_DLLLinux64.jar ]; then
        extract_native_libs avctVMAPI_DLLLinux64.jar libVMAPI_DLL.so
    else
        extract_native_libs avctVMLinux64.jar libavmLinux64.so
    fi

    cd "${APP_WORKDIR}"
}

enable_keycode_hack_if_needed() {
    : "${IDRAC_KEYCODE_HACK:=false}"

    if [ "$IDRAC_KEYCODE_HACK" = "true" ]; then
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
    cd "${APP_WORKDIR}"

    prepare_launch_parameters
    download_console_artifacts
    extract_console_artifacts
    patch_certificate_jni_if_needed
    enable_keycode_hack_if_needed

    info "${GREEN}Initialization complete, starting virtual console${NC}"

    set -- java

    if [ -n "${IDRAC_EXTRA_JAVA_OPTS:-}" ]; then
        # shellcheck disable=SC2086
        set -- "$@" $IDRAC_EXTRA_JAVA_OPTS
    fi

    set -- "$@" \
        -Djava.security.properties=/etc/java.security.override \
        -Djava.util.prefs.userRoot="${APP_PREFS_USER_ROOT}" \
        -Djava.util.prefs.systemRoot="${APP_PREFS_SYSTEM_ROOT}" \
        -Didrac.main.class="${IDRAC_MAIN_CLASS}" \
        -cp "/opt/idrac-wrapper:${KVM_JAR}" \
        -Djava.library.path="${APP_LIBDIR}" \
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

    : "${IDRAC_PORT:=443}"
    : "${IDRAC_MODE:=java}"
    : "${IDRAC_CACHE_DIR:=/app}"
    : "${IDRAC_KMPORT:=5900}"
    : "${IDRAC_VPORT:=5900}"
    : "${IDRAC_DOWNLOAD_BASE:=/software}"
    : "${IDRAC_MAIN_CLASS:=com.avocent.idrac.kvm.Main}"
    : "${IDRAC_VNC_PORT:=5901}"
    : "${IDRAC_VNC_SECURITY_TYPES:=TLSVnc,VncAuth,TLSNone,None}"
    : "${IDRAC_VNC_GNUTLS_PRIORITY:=NORMAL}"

    # Validate before deriving anything from IDRAC_HOST: IDRAC_HELPURL
    # interpolates it, and under "set -u" that aborted with a bare
    # "parameter not set" instead of the intended "Please set IDRAC_HOST".
    require_env IDRAC_HOST

    case "${IDRAC_MODE}" in
        java)
            require_env IDRAC_USER
            require_env IDRAC_PASSWORD
            ;;
        vnc)
            ;;
        *)
            die 1 "Unsupported IDRAC_MODE: ${IDRAC_MODE}"
            ;;
    esac

    : "${IDRAC_HELPURL:=https://${IDRAC_HOST}:${IDRAC_PORT}/help/contents.html}"

    initialize_workdir

    info "Environment ok"
    info "Selected launch mode: ${IDRAC_MODE}"
}

main() {
    load_configuration

    if [ "${IDRAC_MODE}" = "vnc" ]; then
        start_vnc_mode
    fi

    start_java_mode
}

main "$@"
