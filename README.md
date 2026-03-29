# docker-idrac7

This repository contains a Dockerized iDRAC7 console image modeled after [`DomiStyle/docker-idrac6`](https://github.com/DomiStyle/docker-idrac6).

The container follows the same pattern as the iDRAC6 project:

- Run a GUI-capable container based on [`jlesage/baseimage-gui`](https://github.com/jlesage/docker-baseimage-gui).
- Download Dell's legacy Java console artifacts from the target iDRAC appliance at startup.
- Launch the Java KVM inside the container and expose it through the built-in web UI on port `5800` or raw VNC on port `5900`.

## Recommended launch mode

For the setup we validated here, the simplest working launch path is direct `IDRAC_USER` / `IDRAC_PASSWORD` mode with the certificate JNI compatibility shim enabled:

```powershell
docker run -d `
  --name idrac7 `
  -p 5800:5800 `
  -e IDRAC_HOST=192.168.0.17 `
  -e IDRAC_PORT=443 `
  -e IDRAC_USER=root `
  -e IDRAC_PASSWORD=changeme `
  -e IDRAC_BYPASS_CERT_JNI=true `
  -v ${PWD}/data/app:/app `
  docker-idrac7
```

When running in plain `IDRAC_USER` / `IDRAC_PASSWORD` mode, the container now automatically adds the same non-auth launch arguments Dell includes in `viewer.jnlp` (`vm=1 reconnect=2 chat=1 F1=1 custom=0 scaling=15 ...`). This avoids the unstable reconnect loop seen on some iDRAC7 systems when the legacy viewer is launched with only the bare minimum arguments.

If your appliance insists on tokenized session credentials, you can still mount a fresh `viewer.jnlp` from the iDRAC. The JNLP contains:

- the one-time `user` / `passwd` session tokens expected by the Java applet
- the current KVM and virtual-media ports
- the correct Linux native library names for this firmware (`avctKVMIOLinux64.jar` and `avctVMAPI_DLLLinux64.jar`)

Example:

```powershell
docker run -d `
  --name idrac7 `
  -p 5800:5800 `
  -e IDRAC_HOST=192.168.0.17 `
  -e IDRAC_PORT=443 `
  -e IDRAC_JNLP_FILE=/jnlp/viewer.jnlp `
  -v D:\POBRANE:/jnlp:ro `
  -v ${PWD}/data/app:/app `
  docker-idrac7
```

When `IDRAC_JNLP_FILE` is set, the container will use the tokenized launch arguments from the JNLP instead of requiring `IDRAC_USER` and `IDRAC_PASSWORD`. If the downloaded JNLP contains a stale console port, any explicit `IDRAC_USER`, `IDRAC_PASSWORD`, `IDRAC_KMPORT`, or `IDRAC_VPORT` environment variables will override the JNLP values.

If your iDRAC7 virtual console is on the default remote-presence port instead of the JNLP port, you can still run with the token values from the JNLP and override the KVM ports explicitly:

```powershell
docker run -d `
  --name idrac7 `
  -p 5800:5800 `
  -e IDRAC_HOST=192.168.0.17 `
  -e IDRAC_KMPORT=5900 `
  -e IDRAC_VPORT=5900 `
  -e IDRAC_USER=11@@... `
  -e IDRAC_PASSWORD=... `
  -e IDRAC_BYPASS_CERT_JNI=true `
  -v ${PWD}/data/app:/app `
  docker-idrac7
```

## Important limitation

This image targets the legacy Java-based iDRAC7 virtual console path. It expects these appliance-hosted downloads to exist:

- `/software/avctKVM.jar`
- `/software/avctKVMIOLinux64.jar`
- `/software/avctVMAPI_DLLLinux64.jar` or `/software/avctVMLinux64.jar`

If your iDRAC7 firmware is configured for HTML5-only launch or serves the Java components from a different path, startup will fail until you either switch the appliance back to Java launch mode or override `IDRAC_DOWNLOAD_BASE`.

Even with the correct JNLP, some iDRAC7 firmware/security combinations still reject the legacy Avocent Java client's TLS handshake unless elliptic-curve cipher support is bootstrapped manually. This image now does that automatically by registering Java's `SunEC` provider before Dell's launcher starts.

Some appliances also trigger Dell's native certificate JNI path, which can fail inside the container. For those cases you can set `IDRAC_BYPASS_CERT_JNI=true` to patch the downloaded `avctKVM.jar` in `/app` and replace that native certificate check with a pure-Java compatibility shim. This is less strict than Dell's original path and should be treated as a trust bypass for private/lab use.

## Usage

Build the image:

```powershell
docker build -t docker-idrac7 .
```

Run it:

```powershell
docker run -d `
  -p 5800:5800 `
  -p 5900:5900 `
  -e IDRAC_HOST=idrac7.example.org `
  -e IDRAC_USER=root `
  -e IDRAC_PASSWORD=changeme `
  -v ${PWD}/data/app:/app `
  docker-idrac7
```

The web interface will be available on port `5800` and the VNC server on `5900`. The first startup can take a little longer because the console JARs are downloaded from the appliance into `/app`.

Run only one active iDRAC console container against the same appliance at a time. Multiple live containers can confuse the session state and break login or reconnect behavior.

If the `/app` bind mount is missing, read-only, or backed by a VM/shared-folder filesystem that doesn't allow writes from the container user, the startup script now falls back automatically to `/tmp/idrac-app`. The console will still work, but the downloaded JAR cache will be ephemeral unless you point `IDRAC_CACHE_DIR` at a writable persistent location.

## Virtual media

Put ISO files in the `/vmedia` bind mount and set `VIRTUAL_MEDIA` to the filename you want mapped after the KVM window appears:

```powershell
docker run -d `
  --name idrac7 `
  -p 5800:5800 `
  -e IDRAC_HOST=192.168.0.17 `
  -e IDRAC_USER=root `
  -e IDRAC_PASSWORD=changeme `
  -e IDRAC_BYPASS_CERT_JNI=true `
  -e VIRTUAL_MEDIA=installer.iso `
  -v ${PWD}/data/app:/app `
  -v ${PWD}/data/vmedia:/vmedia `
  docker-idrac7
```

The helper script waits for the Java viewer window, opens the hidden virtual-media flow when needed, launches `Add Image`, and submits `/vmedia/<filename>` into Dell's real file chooser automatically. If your iDRAC is slow to draw the KVM window, increase `VIRTUAL_MEDIA_START_DELAY`.

The browser-side control bar includes a `Virtual Media` button. Clicking it opens a browser dialog listing files from `/vmedia`; choose one and click `Add Image` to map it into the running session without needing a separate Dell `Virtual Media` window on screen.

That dialog can also upload a new `ISO`, `IMG`, or `IMA` file directly into `/vmedia`. Click `Upload ISO/IMG`, wait for the upload to finish, and then click `Add Image` on the newly uploaded file. If you want to remove an uploaded file from `/vmedia`, select it in the same dialog and click `Delete`.

`VIRTUAL_MEDIA_GUI` supports these modes:

- `auto`: open the lightweight in-container picker when `/vmedia` already contains files
- `picker`: always open the lightweight in-container picker window
- `false`: disable startup GUI helpers and rely on the browser-side `Virtual Media` button or `VIRTUAL_MEDIA=...`

An example compose file is available in [`docker-compose.yml`](./docker-compose.yml).

## Configuration

| Variable | Description | Required |
| --- | --- | --- |
| `IDRAC_HOST` | Hostname or IP of the iDRAC7 appliance. HTTPS is always used. | Yes |
| `IDRAC_USER` | iDRAC username. Required only when `IDRAC_JNLP_FILE` is not provided. | Conditionally |
| `IDRAC_PASSWORD` | iDRAC password. Required only when `IDRAC_JNLP_FILE` is not provided. | Conditionally |
| `IDRAC_JNLP_FILE` | Absolute path to a downloaded `viewer.jnlp` mounted into the container. Recommended for iDRAC7. | No |
| `IDRAC_PORT` | HTTPS port for the iDRAC web UI. Defaults to `443`. | No |
| `IDRAC_CACHE_DIR` | Writable directory used for downloaded JARs, extracted native libraries, and Java prefs. Defaults to `/app`, with automatic fallback to `/tmp/idrac-app` when `/app` is not writable. | No |
| `IDRAC_KMPORT` | KVM port passed to the Java launcher. Defaults to `5900`. | No |
| `IDRAC_VPORT` | Virtual media port passed to the Java launcher. Defaults to `5900`. | No |
| `IDRAC_BYPASS_CERT_JNI` | Rebuilds the cached `avctKVM.jar` in `/app` with a pure-Java certificate compatibility shim. Use only when Dell's native certificate JNI fails. | No |
| `IDRAC_DOWNLOAD_BASE` | Base path used when downloading the Java console artifacts. Defaults to `/software`. | No |
| `IDRAC_HELPURL` | Overrides the help URL passed to the Java launcher. | No |
| `IDRAC_MAIN_CLASS` | Java main class to execute. Defaults to `com.avocent.idrac.kvm.Main`. | No |
| `IDRAC_EXTRA_JAVA_OPTS` | Extra JVM flags appended before the launcher class. | No |
| `IDRAC_EXTRA_KVM_ARGS` | Extra arguments appended after the standard KVM parameters. | No |
| `IDRAC_KEYCODE_HACK` | Enables the legacy X11 keycode shim. | No |
| `VIRTUAL_MEDIA` | Filename inside `/vmedia` to automount after the console starts. | No |
| `VIRTUAL_MEDIA_GUI` | Controls the optional startup helper for virtual media. `auto` opens the lightweight in-container picker when `/vmedia` contains files, `picker` always opens it, and `false` disables startup helpers. The browser-side `Virtual Media` button remains available regardless. Defaults to `false`. | No |
| `VIRTUAL_MEDIA_GUI_DELAY` | Delay in seconds before the in-GUI virtual media picker appears. Defaults to `3`. | No |
| `VIRTUAL_MEDIA_MENU_RIGHT_STEPS` | Number of `Right` key presses used after `F10` to reach `Virtual Media` in the Java menu bar. Defaults to `6`. | No |
| `VIRTUAL_MEDIA_START_DELAY` | Delay in seconds before the virtual media UI automation begins. Defaults to `15`. | No |
| `VIRTUAL_MEDIA_UPLOAD_MAX_BYTES` | Maximum browser-upload size accepted by the local virtual media API. Defaults to `21474836480` (20 GiB). | No |

Docker secrets are also supported through `/run/secrets/idrac_host`, `/run/secrets/idrac_port`, `/run/secrets/idrac_user`, `/run/secrets/idrac_password`, and `/run/secrets/idrac_jnlp_file`.

For advanced desktop/container tuning options, see the [`docker-baseimage-gui` environment variable reference](https://github.com/jlesage/docker-baseimage-gui#environment-variables).

## Volumes

| Path | Description | Required |
| --- | --- | --- |
| `/app` | Cached JAR downloads and extracted native libraries. | No |
| `/vmedia` | Optional ISO repository for automounting virtual media. | No |
| `/screenshots` | Screenshot directory exposed by the base GUI image. | No |

## Repository layout

- [`Dockerfile`](./Dockerfile): Docker image definition for the Java/VNC container.
- [`scripts/startapp.sh`](./scripts/startapp.sh): Downloads the iDRAC7 Java console artifacts and launches the KVM.
- [`scripts/mountiso.sh`](./scripts/mountiso.sh): Maps a selected `/vmedia` file through Dell's `Add Image` flow.
- [`scripts/virtual-media-api.py`](./scripts/virtual-media-api.py): Local API for listing, uploading, deleting, and mapping `/vmedia` files.
- [`scripts/virtual-media-ui.sh`](./scripts/virtual-media-ui.sh): Optional in-container picker for mapping files from `/vmedia`.
- [`assets/branding/dell-logo.png`](./assets/branding/dell-logo.png): Custom logo used by the noVNC/iDRAC browser UI.
- [`web/idrac-virtual-media.js`](./web/idrac-virtual-media.js): Browser-side Virtual Media modal injected into noVNC.
- [`config/nginx/default_site.conf`](./config/nginx/default_site.conf) and [`config/nginx/virtual-media-api.conf`](./config/nginx/virtual-media-api.conf): nginx wiring for the browser UI and local media API.
- [`src/java/IdracLauncher.java`](./src/java/IdracLauncher.java) and [`src/java/wrapper-src`](./src/java/wrapper-src): Java launcher and certificate compatibility wrapper sources.
- [`src/native/keycode-hack.c`](./src/native/keycode-hack.c): Optional native X11 keycode shim.
- [`config/java/java.security.override`](./config/java/java.security.override): JVM security overrides used by the legacy Dell viewer.

Runtime data stays under [`data`](./data) and is intentionally git-ignored so you can keep downloaded JARs, screenshots, and media files locally without polluting the repository.


## KNOWN BUGS
when you're connected into java kvm session and u click into about idrac remote console it gets crash