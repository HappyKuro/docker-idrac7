import UI from "./ui.js?v=9d7b76637b";
import * as WebUtil from "./webutil.js?v=9d7b76637b";

const state = {
    files: [],
    selectedFile: "",
    modal: null,
    busy: false,
};

function $(id) {
    return document.getElementById(id);
}

function applyResizeModeValue(value, showStatus = false) {
    const resizeControl = $("noVNC_setting_resize");
    if (!resizeControl) {
        return false;
    }

    resizeControl.value = value;
    WebUtil.writeSetting("resize", value);
    WebUtil.writeSetting("view_clip", false);
    UI.updateSetting("resize");
    UI.applyResizeMode();
    UI.updateViewClip();
    window.dispatchEvent(new Event("resize"));

    if (showStatus) {
        UI.showStatus("Remote Resizing is disabled for iDRAC Java. Using Local Scaling.", "warn", 3000, true);
    }

    return true;
}

function sanitizeResizeModes() {
    const resizeControl = $("noVNC_setting_resize");
    if (!resizeControl) {
        return false;
    }

    for (const option of Array.from(resizeControl.options)) {
        if (option.value === "remote") {
            option.remove();
        }
    }

    resizeControl.addEventListener("change", () => {
        if (resizeControl.value === "remote") {
            applyResizeModeValue("scale", true);
        }
    });

    return true;
}

function applyPreferredResizeMode() {
    const query = new URLSearchParams(window.location.search);
    const requestedResize = query.get("resize");
    if (requestedResize === "remote") {
        return applyResizeModeValue("scale", true);
    }

    if (requestedResize === "scale") {
        return applyResizeModeValue("scale");
    }

    const resizeControl = $("noVNC_setting_resize");
    if (!resizeControl) {
        return false;
    }

    const currentValue = UI.getSetting("resize") ?? WebUtil.readSetting("resize");
    if (currentValue && currentValue !== "remote") {
        return true;
    }

    // The Java iDRAC viewer behaves much better with local scaling than
    // noVNC's desktop default of remote resizing.
    return applyResizeModeValue("scale");
}

function ensurePreferredResizeMode(attempt = 0) {
    if (applyPreferredResizeMode()) {
        return;
    }

    if (attempt >= 20) {
        return;
    }

    window.setTimeout(() => ensurePreferredResizeMode(attempt + 1), 250);
}

function setBusy(busy) {
    state.busy = busy;
    $("noVNC_virtual_media_refresh").disabled = busy;
    $("noVNC_virtual_media_close").disabled = busy;
    $("noVNC_virtual_media_upload_button").disabled = busy;
    $("noVNC_virtual_media_delete_button").disabled = busy || !state.selectedFile;
    $("noVNC_virtual_media_map_button").disabled = busy || !state.selectedFile;
}

function setUploadStatus(message = "", level = "muted") {
    const status = $("noVNC_virtual_media_upload_status");
    status.textContent = message;
    status.className = "small";

    if (!message) {
        status.classList.add("d-none");
        return;
    }

    status.classList.remove("d-none");
    if (level === "error") {
        status.classList.add("text-danger");
    } else if (level === "success") {
        status.classList.add("text-success");
    } else {
        status.classList.add("text-muted");
    }
}

function showError(message) {
    const errorBox = $("noVNC_virtual_media_error");
    errorBox.textContent = message;
    errorBox.classList.remove("d-none");
}

function clearError() {
    const errorBox = $("noVNC_virtual_media_error");
    errorBox.textContent = "";
    errorBox.classList.add("d-none");
}

async function requestJson(url, options = {}) {
    const response = await fetch(url, options);
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
        throw new Error(payload.error || `HTTP ${response.status}`);
    }
    return payload;
}

function renderFiles() {
    const fileList = $("noVNC_virtual_media_file_list");
    const emptyState = $("noVNC_virtual_media_empty");
    fileList.textContent = "";

    if (state.files.length === 0) {
        emptyState.classList.remove("d-none");
        state.selectedFile = "";
        setBusy(state.busy);
        return;
    }

    emptyState.classList.add("d-none");

    for (const file of state.files) {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "list-group-item list-group-item-action d-flex justify-content-between align-items-center";
        if (file === state.selectedFile) {
            button.classList.add("active");
        }

        const name = document.createElement("span");
        name.className = "text-break";
        name.textContent = file;
        button.appendChild(name);

        const badge = document.createElement("span");
        badge.className = "badge text-bg-secondary";
        badge.textContent = file.split(".").pop().toUpperCase();
        button.appendChild(badge);

        button.addEventListener("click", () => {
            state.selectedFile = file;
            renderFiles();
        });

        fileList.appendChild(button);
    }

    if (!state.selectedFile || !state.files.includes(state.selectedFile)) {
        state.selectedFile = state.files[0];
        renderFiles();
        return;
    }

    setBusy(state.busy);
}

async function loadFiles() {
    setBusy(true);
    clearError();
    try {
        const payload = await requestJson("./api/virtual-media/files");
        state.files = Array.isArray(payload.files) ? payload.files : [];
        if (state.files.length === 0) {
            state.selectedFile = "";
        } else if (!state.selectedFile || !state.files.includes(state.selectedFile)) {
            state.selectedFile = state.files[0];
        }
        renderFiles();
    } catch (error) {
        state.files = [];
        state.selectedFile = "";
        renderFiles();
        showError(`Unable to load /vmedia files: ${error.message}`);
    } finally {
        setBusy(false);
    }
}

function openUploadPicker() {
    const input = $("noVNC_virtual_media_upload_input");
    input.value = "";
    input.click();
}

function uploadFile(file) {
    return new Promise((resolve, reject) => {
        const xhr = new XMLHttpRequest();
        xhr.open("POST", "./api/virtual-media/upload");
        xhr.setRequestHeader("X-File-Name", encodeURIComponent(file.name));
        xhr.responseType = "json";

        xhr.upload.addEventListener("progress", (event) => {
            if (!event.lengthComputable || event.total <= 0) {
                setUploadStatus(`Uploading ${file.name}...`);
                return;
            }

            const percent = Math.max(0, Math.min(100, Math.round((event.loaded / event.total) * 100)));
            setUploadStatus(`Uploading ${file.name}... ${percent}%`);
        });

        xhr.addEventListener("load", () => {
            let payload = {};
            if (xhr.response && typeof xhr.response === "object") {
                payload = xhr.response;
            } else {
                try {
                    payload = JSON.parse(xhr.responseText || "{}");
                } catch {
                    payload = {};
                }
            }

            if (xhr.status >= 200 && xhr.status < 300) {
                resolve(payload);
                return;
            }

            reject(new Error(payload.error || `HTTP ${xhr.status}`));
        });

        xhr.addEventListener("error", () => {
            reject(new Error("Upload request failed"));
        });

        xhr.send(file);
    });
}

async function handleUploadSelection(event) {
    const file = event.target.files?.[0];
    if (!file) {
        return;
    }

    setBusy(true);
    clearError();
    setUploadStatus(`Uploading ${file.name}...`);

    try {
        const payload = await uploadFile(file);
        state.selectedFile = payload.file || file.name;
        await loadFiles();
        if (payload.file) {
            state.selectedFile = payload.file;
            renderFiles();
        }
        setUploadStatus(payload.message || `Uploaded ${state.selectedFile}`, "success");
        UI.showStatus(payload.message || "Upload finished", "normal", 2500, true);
    } catch (error) {
        setUploadStatus(error.message, "error");
        showError(`Unable to upload the selected image: ${error.message}`);
        UI.showStatus(`Upload failed: ${error.message}`, "warn", 3500, true);
    } finally {
        event.target.value = "";
        setBusy(false);
    }
}

async function mapSelectedFile() {
    if (!state.selectedFile) {
        showError("Select an ISO or IMG file before clicking Add Image.");
        return;
    }

    setBusy(true);
    clearError();
    try {
        const payload = await requestJson("./api/virtual-media/map", {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
            },
            body: JSON.stringify({ file: state.selectedFile }),
        });
        UI.showStatus(payload.message || "Adding image to Dell Virtual Media", "normal", 3000, true);
        state.modal.hide();
    } catch (error) {
        showError(`Unable to map the selected image: ${error.message}`);
        UI.showStatus(`Virtual Media failed: ${error.message}`, "warn", 3500, true);
    } finally {
        setBusy(false);
    }
}

async function deleteSelectedFile() {
    if (!state.selectedFile) {
        showError("Select an ISO or IMG file before clicking Delete.");
        return;
    }

    const fileToDelete = state.selectedFile;
    if (!window.confirm(`Delete ${fileToDelete} from /vmedia?`)) {
        return;
    }

    setBusy(true);
    clearError();
    setUploadStatus("");

    try {
        const payload = await requestJson("./api/virtual-media/delete", {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
            },
            body: JSON.stringify({ file: fileToDelete }),
        });
        await loadFiles();
        UI.showStatus(payload.message || `Deleted ${fileToDelete}`, "normal", 2500, true);
    } catch (error) {
        showError(`Unable to delete the selected image: ${error.message}`);
        UI.showStatus(`Delete failed: ${error.message}`, "warn", 3500, true);
    } finally {
        setBusy(false);
    }
}

async function showVirtualMediaModal(event) {
    event.preventDefault();
    clearError();
    setUploadStatus("");
    await loadFiles();
    state.modal.show();
}

function installVirtualMediaButton() {
    const button = $("noVNC_virtual_media_button");
    const modalElement = $("noVNC_virtual_media_modal");
    if (!button || !modalElement || !window.bootstrap?.Modal) {
        return;
    }

    state.modal = new window.bootstrap.Modal(modalElement);

    button.addEventListener("click", showVirtualMediaModal);
    $("noVNC_virtual_media_refresh").addEventListener("click", loadFiles);
    $("noVNC_virtual_media_upload_button").addEventListener("click", openUploadPicker);
    $("noVNC_virtual_media_upload_input").addEventListener("change", handleUploadSelection);
    $("noVNC_virtual_media_delete_button").addEventListener("click", deleteSelectedFile);
    $("noVNC_virtual_media_map_button").addEventListener("click", mapSelectedFile);
    modalElement.addEventListener("shown.bs.modal", loadFiles);
    sanitizeResizeModes();
    ensurePreferredResizeMode();
    setUploadStatus("");
    setBusy(false);
}

if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", installVirtualMediaButton);
} else {
    installVirtualMediaButton();
}
