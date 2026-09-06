-- Tracks the actual video rectangle after resize, fullscreen, monitor or playlist changes.
-- The driver owns RTX activation; a configured filter is never proof of driver activity.
local mp = require 'mp'
local options = { sr = 'no', hdr = 'no' }
require('mp.options').read_options(options, 'adaptive-playback')
local timer, last, failed = nil, nil, false
local function state(text)
    mp.set_property_native('user-data/adaptive/state', text)
end
local function update()
    if failed then return end
    if options.sr ~= 'yes' and options.hdr ~= 'yes' then return end
    local video = mp.get_property_native('video-params')
    local osd = mp.get_property_native('osd-dimensions')
    if not video or not osd or not video.w or not video.h or video.w <= 0 or video.h <= 0 then return end
    local width = osd.w - (osd.ml or 0) - (osd.mr or 0)
    local height = osd.h - (osd.mt or 0) - (osd.mb or 0)
    if width <= 0 or height <= 0 then return end
    local aspect = video.aspect or (video.w / video.h)
    local factor = math.min(width / video.w, height / video.h)
    local sr = options.sr == 'yes' and factor > 1.001 and factor <= 8 and math.abs(aspect - video.w / video.h) < 0.015
    local sdr = { ['bt.1886']=true, srgb=true, ['gamma1.8']=true, ['gamma2.0']=true, ['gamma2.2']=true, ['gamma2.4']=true, ['gamma2.6']=true, ['gamma2.8']=true, linear=true }
    local hdr = options.hdr == 'yes' and sdr[video.gamma] == true
    local key = (sr and string.format('%.4f', factor) or 'native') .. (hdr and '-hdr' or '')
    if last == key then return end
    last = key
    local filters = mp.get_property_native('vf') or {}
    local next_filters = {}
    for _, filter in ipairs(filters) do
        if filter.label ~= 'adaptive-vpp' then table.insert(next_filters, filter) end
    end
    if sr or hdr then
        local params = {}
        if sr then params.scale = string.format('%.6f', factor); params['scaling-mode'] = 'nvidia' end
        if hdr then params['nvidia-true-hdr'] = 'yes' end
        table.insert(next_filters, {name='d3d11vpp', label='adaptive-vpp', enabled=true, params=params})
    end
    local ok, error = mp.set_property_native('vf', next_filters)
    if not ok then
        failed = true
        mp.commandv('vf', 'remove', '@adaptive-vpp')
        state('RTX filter could not be applied; continuing with standard scaling.')
        mp.osd_message('RTX processing unavailable. Standard scaling remains available.', 5)
    elseif sr then
        state(string.format('RTX VPP configured for the observed video rectangle (%d × %d). Driver activation is unverified.', width, height))
    else
        state(hdr and 'RTX HDR filter configured; driver activation is unverified.' or 'RTX SR unnecessary at the current window size.')
    end
end
local function schedule()
    if timer then timer:kill() end
    timer = mp.add_timeout(0.35, update)
end
mp.observe_property('osd-dimensions', 'native', schedule)
mp.observe_property('video-params', 'native', schedule)
mp.register_event('file-loaded', function() last = nil; failed = false; schedule() end)

-- Keep the established measured motion guard; show its effective fallback in playback.
local had_interpolation = mp.get_property_native('interpolation', false)
mp.observe_property('interpolation', 'bool', function(_, enabled)
    if had_interpolation and enabled == false then
        mp.osd_message('Smooth motion disabled because display timing became unstable.', 6)
    end
    had_interpolation = enabled
end)

