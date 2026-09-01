local mp = require 'mp'
local msg = require 'mp.msg'

local function val(v)
    if v == nil then return "unknown" end
    return tostring(v)
end

local function show_info()
    local p = mp.get_property_native("video-params") or {}
    local w = p.w or mp.get_property_number("width", 0) or 0
    local h = p.h or mp.get_property_number("height", 0) or 0
    local fps = mp.get_property_number("container-fps", 0) or 0
    local gamma = p.gamma or "unknown"
    local prim = p.primaries or "unknown"
    local hdr = (gamma == "pq" or gamma == "hlg") and "yes" or "no"
    local vcodec = mp.get_property("video-codec", "unknown")
    local acodec = mp.get_property("audio-codec-name", "unknown")
    local hwdec = mp.get_property("hwdec-current", "none")
    local dfps = mp.get_property_number("display-fps", 0) or 0

    mp.osd_message(string.format(
        "Source: %dx%d @ %.3f fps\nVideo: %s | %s / %s | HDR-family: %s\nAudio: %s\nHW decode: %s | Display: %.3f Hz\nRenderer: gpu-next / libplacebo",
        w, h, fps, val(vcodec), val(prim), val(gamma), hdr, val(acodec), val(hwdec), dfps
    ), 8)
end

mp.add_key_binding("Ctrl+i", "show-info", show_info)
mp.register_event("file-loaded", function()
    local p = mp.get_property_native("video-params") or {}
    if p.gamma == "pq" or p.gamma == "hlg" then
        msg.info("HDR-family source detected. Adaptive Media manages Windows HDR when enabled; gpu-next negotiates output colour.")
    end
end)
