import re
from pathlib import Path

index_path = Path("/opt/noVNC/index.html")
content = index_path.read_text(encoding="utf-8")
content = content.replace("<title></title>", "<title>iDRAC 7</title>", 1)

script_tag = '    <script type="module" crossorigin="anonymous" src="app/idrac-virtual-media.js?v=20260329f"></script>\n'
content = re.sub(
    r'    <script type="module" crossorigin="anonymous" src="app/idrac-virtual-media\.js\?v=[^"]+"></script>\n',
    script_tag,
    content,
)

if "app/idrac-virtual-media.js" not in content:
    marker = '    <script type="module" crossorigin="anonymous" src="app/error-handler.js"></script>\n'
    content = content.replace(marker, marker + script_tag)

content = re.sub(
    r'src="app/images/icons/master_icon\.png\?v=[^"]+" id="noVNC_app_logo"',
    'src="app/images/icons/dell-logo.png?v=20260329a" id="noVNC_app_logo"',
    content,
)

button_html = '                            <a class="btn btn-outline-secondary btn-sm ms-2 d-inline-flex align-items-center gap-1" href="#" title="Open Virtual Media" id="noVNC_virtual_media_button"><i class="fas fa-compact-disc fa-fw"></i><span>Media</span></a>\n'
if 'id="noVNC_virtual_media_button"' not in content:
    marker = '                            <a class="btn shadow-none p-0 px-2 noVNC_hidden" href="#" title="Open Terminal" id="noVNC_terminal_button" data-bs-toggle="modal" data-bs-target="#terminal_modal"><i class="fas fa-terminal fa-fw fa-lg"></i></a>\n'
    content = content.replace(marker, marker + button_html)

modal_html = """

    <!-- Virtual Media Modal -->
    <div class="modal fade" id="noVNC_virtual_media_modal" data-bs-backdrop="static" data-bs-keyboard="false" tabindex="-1" aria-labelledby="noVNC_virtual_media_modal_label" aria-hidden="true">
        <div class="modal-dialog modal-dialog-centered">
            <div class="modal-content">
                <div class="modal-header">
                    <h5 class="modal-title" id="noVNC_virtual_media_modal_label">Virtual Media</h5>
                    <button type="button" class="btn-close" id="noVNC_virtual_media_close" data-bs-dismiss="modal" aria-label="Close"></button>
                </div>
                <div class="modal-body">
                    <p class="small text-muted mb-3">Pick a file from <code>/vmedia</code> and click <strong>Add Image</strong> to map it into the running iDRAC session.</p>
                    <div class="alert alert-danger d-none py-2 mb-3" id="noVNC_virtual_media_error"></div>
                    <div class="small text-muted d-none mb-3" id="noVNC_virtual_media_upload_status"></div>
                    <div class="small text-muted d-none mb-2" id="noVNC_virtual_media_empty">No ISO or IMG files were found in <code>/vmedia</code>.</div>
                    <div class="list-group" id="noVNC_virtual_media_file_list"></div>
                </div>
                <div class="modal-footer">
                    <button type="button" class="btn btn-outline-secondary btn-sm" id="noVNC_virtual_media_refresh">Refresh</button>
                    <button type="button" class="btn btn-outline-secondary btn-sm" id="noVNC_virtual_media_upload_button">Upload ISO/IMG</button>
                    <button type="button" class="btn btn-outline-danger btn-sm" id="noVNC_virtual_media_delete_button">Delete</button>
                    <button type="button" class="btn btn-primary btn-sm" id="noVNC_virtual_media_map_button">Add Image</button>
                </div>
                <input type="file" class="d-none" id="noVNC_virtual_media_upload_input" accept=".iso,.img,.ima">
            </div>
        </div>
    </div>
""".lstrip("\n")

if 'id="noVNC_virtual_media_modal"' not in content:
    content = content.replace("\n</body>\n</html>\n", "\n" + modal_html + "\n</body>\n</html>\n")

index_path.write_text(content, encoding="utf-8")

ui_path = Path("/opt/noVNC/app/ui.js")
ui_content = ui_path.read_text(encoding="utf-8")
remote_resize_snippet = """        // Use remote sizing by default...
        let resize = 'remote';
"""
scale_resize_snippet = """        // Use local scaling by default for the Java iDRAC viewer.
        let resize = 'scale';
"""

if remote_resize_snippet in ui_content:
    ui_content = ui_content.replace(remote_resize_snippet, scale_resize_snippet, 1)
elif "let resize = 'remote';" in ui_content:
    ui_content = ui_content.replace("let resize = 'remote';", "let resize = 'scale';", 1)

ui_path.write_text(ui_content, encoding="utf-8")
