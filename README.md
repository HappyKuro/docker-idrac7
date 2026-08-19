# docker-idrac7

This repository contains a Dockerized iDRAC7 console image modeled after [`DomiStyle/docker-idrac6`](https://github.com/DomiStyle/docker-idrac6).

The container follows the same pattern as the iDRAC6 project:

- Run a GUI-capable container based on [`jlesage/baseimage-gui`](https://github.com/jlesage/docker-baseimage-gui).
- Download Dell's legacy Java console artifacts from the target iDRAC appliance at startup.
- Launch the Java KVM inside the container and expose it through the built-in web UI on port `5800` or raw VNC on port `5900`.

`java` mode is the primary and default mode in this repository. The optional `vnc` mode remains available for appliances that expose a native VNC viewer path, but the main examples and Compose setup now target the legacy Java KVM flow first.

## Recommended launch mode

For the setup we validated here, the simplest working launch path is direct `IDRAC_USER` / `IDRAC_PASSWORD` mode with the certificate JNI compatibility shim enabled:

```bash
docker run -d \
  --name idrac7 \
  -p 5800:5800 \
  -e IDRAC_HOST=idrac7.example.org \
  -e IDRAC_PORT=443 \
  -e IDRAC_USER=root \
  -e IDRAC_PASSWORD=changeme \
  -e IDRAC_BYPASS_CERT_JNI=true \
  -v ${PWD}/data/app:/app \
  docker-idrac7
```

The launcher automatically adds the compatibility arguments needed by the legacy Java KVM (`vm=1 reconnect=2 chat=1 F1=1 custom=0 scaling=15 ...`). This keeps the default username/password launch path stable on the iDRAC7 systems we validated.

## Important limitation

This image targets the legacy Java-based iDRAC7 virtual console path. It expects these appliance-hosted downloads to exist:

- `/software/avctKVM.jar`
- `/software/avctKVMIOLinux64.jar`
- `/software/avctVMAPI_DLLLinux64.jar` or `/software/avctVMLinux64.jar`

If your iDRAC7 firmware is configured for HTML5-only launch or serves the Java components from a different path, startup will fail until you either switch the appliance back to Java launch mode or override `IDRAC_DOWNLOAD_BASE`.

Some iDRAC7 firmware/security combinations still reject the legacy Avocent Java client's TLS handshake unless elliptic-curve cipher support is bootstrapped manually. This image now does that automatically by registering Java's `SunEC` provider before Dell's launcher starts.

Modern JDK 8 builds also disable TLSv1, TLSv1.1, 3DES and plain ECDH outright, which older iDRAC7 firmware still needs. [`java.security.override`](./java.security.override) relaxes those constraints. It is applied with `-Djava.security.properties=`, which merges it over the JDK's own `lib/security/java.security` - that master file has to stay in place, because it is what enables the override mechanism in the first place. Do not re-declare `security.provider.N` entries in the override either; the stock list already has `SunEC` and `SunJSSE` in the right order.

Some appliances also trigger Dell's native certificate JNI path, which can fail inside the container. For those cases you can set `IDRAC_BYPASS_CERT_JNI=true` to replace that native certificate check with a pure-Java compatibility shim. This is less strict than Dell's original path and should be treated as a trust bypass for private/lab use.

The rebuild is written to `avctKVM.patched.jar`, and the jar downloaded from the appliance is left untouched. Clearing `IDRAC_BYPASS_CERT_JNI` therefore goes back to Dell's original certificate check instead of silently reusing a jar that is still patched from an earlier run.

## Usage

Build the image:

```bash
docker build -t docker-idrac7 .
```

Run it directly:

```bash
docker run -d \
  --name idrac7 \
  -p 5800:5800 \
  -p 5900:5900 \
  -e IDRAC_HOST=idrac7.example.org \
  -e IDRAC_PORT=443 \
  -e IDRAC_USER=root \
  -e IDRAC_PASSWORD=changeme \
  -e IDRAC_BYPASS_CERT_JNI=true \
  -v ${PWD}/data/app:/app \
  -v ${PWD}/data/vmedia:/vmedia \
  -v ${PWD}/data/screenshots:/screenshots \
  docker-idrac7
```

Run it with Docker Compose:

```bash
docker compose up -d --build idrac7
```

The bundled [`docker-compose.yml`](./docker-compose.yml) treats the `idrac7` service as the primary Java-mode service and reads host credentials from environment variables, so you can keep local values out of the committed YAML. `IDRAC_MODE` is omitted there because `java` is already the default in [`startapp.sh`](./startapp.sh).

The web interface will be available on port `5800` and the VNC server on `5900`. The first startup can take a little longer because the console JARs are downloaded from the appliance into `/app`.

Run only one active iDRAC console container against the same appliance at a time. Multiple live containers can confuse the session state and break login or reconnect behavior.

If the `/app` bind mount is missing, read-only, or backed by a VM/shared-folder filesystem that doesn't allow writes from the container user, the startup script now falls back automatically to `/tmp/idrac-app`. The console will still work, but the downloaded JAR cache will be ephemeral unless you point `IDRAC_CACHE_DIR` at a writable persistent location.

## Virtual media

Put ISO files in the `/vmedia` bind mount and set `VIRTUAL_MEDIA` to the filename you want mapped after the KVM window appears:

```bash
docker run -d \
  --name idrac7 \
  -p 5800:5800 \
  -e IDRAC_HOST=idrac7.example.org \
  -e IDRAC_USER=root \
  -e IDRAC_PASSWORD=changeme \
  -e IDRAC_BYPASS_CERT_JNI=true \
  -e VIRTUAL_MEDIA=installer.iso \
  -v ${PWD}/data/app:/app \
  -v ${PWD}/data/vmedia:/vmedia \
  docker-idrac7
```

The helper script waits for the Java viewer window, opens `Launch Virtual Media`, and enters `/vmedia/<filename>` automatically. If your iDRAC is slow to draw the KVM window, increase `VIRTUAL_MEDIA_START_DELAY`.

An example compose file is available in [`docker-compose.yml`](./docker-compose.yml).

## Configuration

| Variable | Description | Required |
| --- | --- | --- |
| `IDRAC_HOST` | Hostname or IP of the iDRAC7 appliance. HTTPS is always used. | Yes |
| `IDRAC_MODE` | Launch mode. Defaults to `java`; set to `vnc` only when you want to connect with the native VNC viewer path instead of the Java KVM launcher. | No |
| `IDRAC_USER` | iDRAC username. Required in `java` mode. | Conditionally |
| `IDRAC_PASSWORD` | iDRAC password. Required in `java` mode. | Conditionally |
| `IDRAC_PORT` | HTTPS port for the iDRAC web UI. Defaults to `443`. | No |
| `IDRAC_CACHE_DIR` | Writable directory used for downloaded JARs, extracted native libraries, and Java prefs. Defaults to `/app`, with automatic fallback to `/tmp/idrac-app` when `/app` is not writable. | No |
| `IDRAC_KMPORT` | KVM port passed to the Java launcher. Defaults to `5900`. | No |
| `IDRAC_VPORT` | Virtual media port passed to the Java launcher. Defaults to `5900`. | No |
| `IDRAC_BYPASS_CERT_JNI` | Rebuilds the cached console jar with a pure-Java certificate compatibility shim, written to `avctKVM.patched.jar` alongside the untouched `avctKVM.jar`. Use only when Dell's native certificate JNI fails. | No |
| `IDRAC_DOWNLOAD_BASE` | Base path used when downloading the Java console artifacts. Defaults to `/software`. | No |
| `IDRAC_HELPURL` | Overrides the help URL passed to the Java launcher. | No |
| `IDRAC_MAIN_CLASS` | Java main class to execute. Defaults to `com.avocent.idrac.kvm.Main`. | No |
| `IDRAC_EXTRA_JAVA_OPTS` | Extra JVM flags appended before the launcher class. | No |
| `IDRAC_EXTRA_KVM_ARGS` | Extra arguments appended after the standard KVM parameters. | No |
| `IDRAC_KEYCODE_HACK` | Set to `true` to enable the legacy X11 keycode shim. Any other value leaves it off. | No |
| `IDRAC_FORCE_CIPHER_STRING` | Pushes a cipher list into the Avocent client's internal config after launch. | No |
| `IDRAC_FORCE_PROTOCOL_STRING` | Pushes a TLS protocol list into the Avocent client's internal config after launch. | No |
| `IDRAC_EXTRA_VNC_ARGS` | Extra arguments appended to `vncviewer` in `vnc` mode. | No |
| `IDRAC_VNC_PORT` | Port used in `vnc` mode. Defaults to `5901`. | No |
| `IDRAC_VNC_PASSWORD` | Password used in `vnc` mode. Also readable from a Docker secret. | No |
| `IDRAC_VNC_SECURITY_TYPES` | VNC security types. Defaults to `TLSVnc,VncAuth,TLSNone,None`. | No |
| `IDRAC_VNC_GNUTLS_PRIORITY` | GnuTLS priority string for `vnc` mode. Defaults to `NORMAL`. | No |
| `VIRTUAL_MEDIA` | Filename inside `/vmedia` to automount after the console starts. | No |
| `VIRTUAL_MEDIA_START_DELAY` | Delay in seconds before the virtual media UI automation begins. Defaults to `15`. | No |
| `VIRTUAL_MEDIA_WINDOW_TIMEOUT` | Seconds to wait for each virtual media window. Defaults to `30`. | No |
| `VIRTUAL_MEDIA_WINDOW_NAME` | Title of the virtual media window to drive. Defaults to `Virtual Media`. | No |
| `VIRTUAL_MEDIA_MENU_X` / `_MENU_Y` / `_LAUNCH_X` / `_LAUNCH_Y` / `_PATH_X` / `_PATH_Y` / `_MAP_X` / `_MAP_Y` | Click coordinates for the virtual media automation. Adjust if your console lays its menus out differently. | No |

Docker secrets are also supported through `/run/secrets/idrac_host`, `/run/secrets/idrac_port`, `/run/secrets/idrac_user`, `/run/secrets/idrac_password`, and `/run/secrets/idrac_vnc_password`.

The `secret` compose profile reads those from `./secrets/*.txt`. That directory is gitignored - keep it that way, it holds your iDRAC password in plain text.

For advanced desktop/container tuning options, see the [`docker-baseimage-gui` environment variable reference](https://github.com/jlesage/docker-baseimage-gui#environment-variables).

## Volumes

| Path | Description | Required |
| --- | --- | --- |
| `/app` | Cached JAR downloads (`avctKVM.jar`, plus `avctKVM.patched.jar` when the cert shim is on) and extracted native libraries. | No |
| `/vmedia` | Optional ISO repository for automounting virtual media. | No |
| `/screenshots` | Screenshot directory exposed by the base GUI image. | No |

## Repository layout

- [`Dockerfile`](./Dockerfile): Docker image definition for the Java/VNC container.
- [`startapp.sh`](./startapp.sh): Downloads the iDRAC7 Java console artifacts and launches the KVM.
- [`mountiso.sh`](./mountiso.sh): Optional legacy UI automation for virtual media insertion.
