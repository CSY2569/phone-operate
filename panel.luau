-- panel.luau
-- 统一设备列表（adb 与 KDE Connect 按设备合并），UI 参照 phone-connect：
--   右栏操作按钮（响铃/ping/浏览/剪贴板/分享 + 投屏参数 + 投屏/停止 + 配对）
--   「投屏参数」点击后覆盖左栏媒体+短信区域
-- 颜色全 Noctalia 主题角色 token。
local state = require("./lib/state.luau")
local persistence = require("./lib/persistence.luau")
local ipcMod = require("./lib/ipc.luau")

local devices = {}
local selectedDevice = nil
local params = {}
local running = {}
local pairAddr = ""
local pairCode = ""
local pairExpanded = false
local paramsExpanded = false
local activePreset = nil
local smsDrafts = {}
local seekDrag = {}
local volDrag = {}

local PRESETS = {
	hd   = { max_size = 1920, bit_rate = 16, max_fps = 60 },
	perf = { max_size = 1280, bit_rate = 8,  max_fps = 60 },
	save = { max_size = 1024, bit_rate = 4,  max_fps = 30 },
}

local function ipc(event, payload)
	ipcMod.send(event, payload)
end

local function ipcRestartWithParams()
	if not selectedDevice then return end
	ipc("restart_with_params", { device_id = selectedDevice, params = params })
end

local function hasAdb(dev) return dev.adb_id ~= nil end
local function hasKde(dev) return dev.kde_id ~= nil end

local function countRunning()
	local n = 0
	for _ in pairs(running) do n = n + 1 end
	return n
end

local function countOnline()
	local n = 0
	for _, d in ipairs(devices) do
		if d.online then n = n + 1 end
	end
	return n
end

local function findSelected()
	for _, d in ipairs(devices) do
		if d.id == selectedDevice then return d end
	end
	return nil
end

local function fmtTime(ms)
	local total = math.floor((ms or 0) / 1000)
	return string.format("%d:%02d", math.floor(total / 60), total % 60)
end

local function selectDevice(dev)
	selectedDevice = dev.id
	params = persistence.loadParams(dev.id)
	-- adb-only 设备默认展开参数（左栏无媒体/短信可显示）
	paramsExpanded = not hasKde(dev)
	render()
end

noctalia.state.watch(state.KEY_DEVICES, function(d)
	devices = d or {}
	if (not selectedDevice) and #devices > 0 then
		selectDevice(devices[1])
	else
		render()
	end
end)

noctalia.state.watch(state.KEY_RUNNING, function(r)
	running = r or {}
	render()
end)

function onOpen()
	devices = noctalia.state.get(state.KEY_DEVICES) or {}
	running = noctalia.state.get(state.KEY_RUNNING) or {}
	if #devices > 0 and not selectedDevice then
		selectDevice(devices[1])
	else
		render()
	end
end

local function sectionLabel(rows, text)
	table.insert(rows, ui.label({
		text = text, fontSize = 11, fontWeight = "bold", color = "surface_variant",
	}))
end

-- ─── 头部 ───
local function headerRow()
	return ui.row({ gap = 10, align = "center" }, {
		ui.column({ gap = 2 }, {
			ui.label({ text = noctalia.tr("panel.title"), fontWeight = "bold" }),
			ui.label({ text = noctalia.tr("panel.subtitle"), fontSize = 11, color = "surface_variant" }),
		}),
		ui.spacer({ flexGrow = 1 }),
		ui.row({ gap = 4, align = "center" }, {
			ui.box({ width = 8, height = 8, radius = 4, fill = "primary" }),
			ui.label({ text = tostring(countOnline()), fontSize = 12, color = "on_surface" }),
		}),
		ui.row({ gap = 4, align = "center" }, {
			ui.glyph({ name = "device-tv", size = 14, color = "primary" }),
			ui.label({ text = tostring(countRunning()), fontSize = 12, color = "on_surface" }),
		}),
		ui.button({ glyph = "rotate", variant = "ghost", controlSize = "sm",
			tooltip = noctalia.tr("panel.refresh"),
			onClick = function() ipc("refresh", {}) end }),
		ui.button({ glyph = "player-stop", variant = "ghost", controlSize = "sm",
			tooltip = noctalia.tr("panel.stop_all"),
			onClick = function() ipc("stop_all", {}) end }),
	})
end

-- ─── 设备切换器 ───
local function deviceSwitcher()
	local buttons = {}
	for _, dev in ipairs(devices) do
		local glyph = "device-mobile"
		if hasAdb(dev) then glyph = (dev.transport == "wifi") and "wifi" or "usb" end
		table.insert(buttons, ui.button({
			key = "sw-" .. dev.id,
			text = dev.label,
			glyph = glyph,
			variant = (selectedDevice == dev.id) and "primary" or "ghost",
			controlSize = "sm",
			onClick = function() selectDevice(dev) end,
			flexGrow = 1,
		}))
	end
	if #buttons == 0 then return nil end
	return ui.row({ gap = 6 }, buttons)
end

-- ─── 媒体区（KDE） ───
local function mediaSection(dev, rows)
	sectionLabel(rows, noctalia.tr("media.now_playing"))
	local m = dev.media
	if not m or not m.title then
		table.insert(rows, ui.label({
			text = noctalia.tr("media.no_media"), fontSize = 11, color = "surface_variant",
		}))
		return
	end

	table.insert(rows, ui.column({ gap = 2 }, {
		ui.label({ text = m.title or "", fontWeight = "bold", color = "on_surface" }),
		ui.label({ text = m.artist or "", fontSize = 11, color = "surface_variant" }),
	}))

	table.insert(rows, ui.row({ gap = 6 }, {
		ui.button({ glyph = "player-skip-back", variant = "ghost", controlSize = "sm",
			tooltip = noctalia.tr("media.prev"),
			onClick = function() ipc("media", { device_id = dev.kde_id, action = "Previous" }) end }),
		ui.button({ glyph = m.isPlaying and "player-pause" or "player-play",
			variant = "primary", controlSize = "sm",
			tooltip = noctalia.tr(m.isPlaying and "media.pause" or "media.play"),
			onClick = function() ipc("media", { device_id = dev.kde_id, action = "PlayPause" }) end }),
		ui.button({ glyph = "player-skip-forward", variant = "ghost", controlSize = "sm",
			tooltip = noctalia.tr("media.next"),
			onClick = function() ipc("media", { device_id = dev.kde_id, action = "Next" }) end }),
		ui.button({ glyph = "player-stop", variant = "ghost", controlSize = "sm",
			tooltip = noctalia.tr("media.stop"),
			onClick = function() ipc("media", { device_id = dev.kde_id, action = "Stop" }) end }),
	}))

	if m.canSeek and (m.length or 0) > 0 then
		local pos = seekDrag[dev.id] or m.position or 0
		table.insert(rows, ui.row({ key = "seek-row-" .. dev.id, gap = 8, align = "center" }, {
			ui.label({ text = fmtTime(pos), fontSize = 11, color = "surface_variant", width = 38 }),
			ui.slider({
				key = "seek-" .. dev.id,
				min = 0, max = m.length or 1, step = 1000, value = pos,
				onChange = function(v) seekDrag[dev.id] = tonumber(v); render() end,
				onDragEnd = function()
					local off = seekDrag[dev.id] or 0
					seekDrag[dev.id] = nil
					ipc("media_seek", { device_id = dev.kde_id, offset = off })
					render()
				end,
				flexGrow = 1,
			}),
			ui.label({ text = fmtTime(m.length), fontSize = 11, color = "surface_variant", width = 38 }),
		}))
	end

	if m.volume and m.volume >= 0 then
		local vol = volDrag[dev.id] or m.volume
		table.insert(rows, ui.row({ key = "vol-row-" .. dev.id, gap = 8, align = "center" }, {
			ui.glyph({ name = "volume", size = 14, color = "surface_variant" }),
			ui.slider({
				key = "vol-" .. dev.id,
				min = 0, max = 100, step = 1, value = vol,
				onChange = function(v) volDrag[dev.id] = tonumber(v); render() end,
				onDragEnd = function()
					local vv = volDrag[dev.id] or 0
					volDrag[dev.id] = nil
					ipc("media_set_volume", { device_id = dev.kde_id, volume = vv })
					render()
				end,
				flexGrow = 1,
			}),
			ui.label({ text = tostring(vol) .. "%", fontSize = 11, color = "surface_variant", width = 38 }),
		}))
	end
end

-- ─── 短信区（KDE） ───
local function smsSection(dev, rows)
	sectionLabel(rows, noctalia.tr("panel.section.sms"))
	local draft = smsDrafts[dev.id]
	if not draft then draft = { dest = "", msg = "" }; smsDrafts[dev.id] = draft end

	table.insert(rows, ui.input({
		key = "sms-dest-" .. dev.id,
		value = draft.dest,
		placeholder = noctalia.tr("sms.dest"),
		onChange = function(v) draft.dest = v end,
		flexGrow = 1,
	}))
	table.insert(rows, ui.input({
		key = "sms-msg-" .. dev.id,
		value = draft.msg,
		placeholder = noctalia.tr("sms.msg"),
		onChange = function(v) draft.msg = v end,
		multiline = true,
		flexGrow = 1,
	}))
	table.insert(rows, ui.button({
		text = noctalia.tr("sms.send"), variant = "primary", glyph = "send",
		onClick = function()
			if draft.dest ~= "" and draft.msg ~= "" then
				ipc("sms_send", { device_id = dev.kde_id, destination = draft.dest, text = draft.msg })
				draft.msg = ""
				render()
			end
		end,
		flexGrow = 1,
	}))
end

-- ─── 投屏参数区（adb） ───
local function paramsContent()
	local rows = {}

	local function applyPreset(key, p)
		activePreset = key
		for k, v in pairs(p) do params[k] = v end
		persistence.saveParams(selectedDevice, params)
		ipcRestartWithParams()
		render()
	end

	table.insert(rows, ui.row({ gap = 8 }, {
		ui.button({ text = noctalia.tr("panel.preset_hd"), variant = "ghost", controlSize = "sm",
			selected = activePreset == "hd", onClick = function() applyPreset("hd", PRESETS.hd) end, flexGrow = 1 }),
		ui.button({ text = noctalia.tr("panel.preset_perf"), variant = "ghost", controlSize = "sm",
			selected = activePreset == "perf", onClick = function() applyPreset("perf", PRESETS.perf) end, flexGrow = 1 }),
		ui.button({ text = noctalia.tr("panel.preset_save"), variant = "ghost", controlSize = "sm",
			selected = activePreset == "save", onClick = function() applyPreset("save", PRESETS.save) end, flexGrow = 1 }),
		ui.button({ text = noctalia.tr("panel.preset_custom"), variant = "ghost", controlSize = "sm",
			selected = activePreset == "custom",
			onClick = function()
				activePreset = "custom"
				local c = persistence.loadCustom(selectedDevice)
				if c then
					for k, v in pairs(c) do params[k] = v end
					persistence.saveParams(selectedDevice, params)
					ipcRestartWithParams()
				end
				render()
			end, flexGrow = 1 }),
	}))

	local function paramSlider(labelKey, val, min, max, step, suffix, setter)
		table.insert(rows, ui.row({ key = "row-" .. labelKey, gap = 8, align = "center" }, {
			ui.label({ text = noctalia.tr(labelKey), width = 72, color = "surface_variant" }),
			ui.slider({
				key = "slider-" .. labelKey,
				min = min, max = max, step = step, value = val,
				onChange = function(v)
					setter(tonumber(v))
					activePreset = "custom"
					render()
				end,
				onDragEnd = function()
					persistence.saveParams(selectedDevice, params)
					persistence.saveCustom(selectedDevice, params)
					ipcRestartWithParams()
					render()
				end,
				flexGrow = 1,
			}),
			ui.label({ text = tostring(val) .. suffix, width = 48, color = "on_surface" }),
		}))
	end

	paramSlider("panel.max_size", params.max_size or 1920, 256, 3840, 64, "", function(v) params.max_size = v end)
	paramSlider("panel.bit_rate", params.bit_rate or 8, 1, 30, 1, "M", function(v) params.bit_rate = v end)
	paramSlider("panel.max_fps", params.max_fps or 60, 1, 240, 1, "", function(v) params.max_fps = v end)

	local function toggleBlock(labelKey, descKey, checked, setter)
		table.insert(rows, ui.column({ gap = 2 }, {
			ui.row({ gap = 8, align = "center" }, {
				ui.label({ text = noctalia.tr(labelKey), color = "on_surface", flexGrow = 1 }),
				ui.toggle({
					checked = checked,
					onChange = function(v)
						setter(v == "true")
						activePreset = "custom"
						persistence.saveParams(selectedDevice, params)
						persistence.saveCustom(selectedDevice, params)
						ipcRestartWithParams()
						render()
					end,
				}),
			}),
			ui.label({ text = noctalia.tr(descKey), fontSize = 11, color = "surface_variant" }),
		}))
	end

	toggleBlock("panel.turn_screen_off", "panel.turn_screen_off_desc",
		params.turn_screen_off or false, function(v) params.turn_screen_off = v end)
	toggleBlock("panel.record", "panel.record_desc",
		params.record or false, function(v) params.record = v end)

	return ui.column({ gap = 8, flexGrow = 1 }, rows)
end

-- ─── 左栏：媒体+短信（或投屏参数覆盖，或离线提示） ───
local function leftColumn(dev)
	if hasAdb(dev) and paramsExpanded then
		return paramsContent()
	end
	local rows = {}
	if hasKde(dev) then
		if dev.kde_online then
			mediaSection(dev, rows)
			table.insert(rows, ui.separator({ thickness = 1, spacing = 2 }))
			smsSection(dev, rows)
		else
			table.insert(rows, ui.label({
				text = noctalia.tr("panel.status_offline"), fontSize = 11, color = "surface_variant",
			}))
		end
	else
		table.insert(rows, ui.label({
			text = noctalia.tr("panel.adb_hint"), fontSize = 11, color = "surface_variant",
		}))
	end
	return ui.column({ gap = 8, flexGrow = 1 }, rows)
end

-- ─── 右栏操作按钮 ───
local function actionsColumn(dev)
	local rows = {}
	sectionLabel(rows, noctalia.tr("panel.section.actions"))

	if hasAdb(dev) then
		local isRunning = running[dev.adb_id] ~= nil
		table.insert(rows, isRunning and ui.button({
			text = noctalia.tr("action.stop"), variant = "destructive", glyph = "player-stop",
			onClick = function() ipc("stop", { device_id = dev.adb_id }) end, flexGrow = 1,
		}) or ui.button({
			text = noctalia.tr("action.cast"), variant = hasKde(dev) and "ghost" or "primary", glyph = "player-play",
			onClick = function() ipc("start", { device_id = dev.adb_id }) end, flexGrow = 1,
		}))
	end

	if hasKde(dev) then
		table.insert(rows, ui.button({
			text = noctalia.tr("action.ring"), variant = hasAdb(dev) and "ghost" or "primary", glyph = "bell-ringing",
			onClick = function() ipc("ring", { device_id = dev.kde_id }) end, flexGrow = 1,
		}))
		table.insert(rows, ui.button({
			text = noctalia.tr("action.ping"), variant = "ghost", glyph = "message",
			onClick = function() ipc("ping", { device_id = dev.kde_id }) end, flexGrow = 1,
		}))
		table.insert(rows, ui.button({
			text = noctalia.tr("action.browse"), variant = "ghost", glyph = "folder",
			onClick = function() ipc("browse", { device_id = dev.kde_id }) end, flexGrow = 1,
		}))
		table.insert(rows, ui.button({
			text = noctalia.tr("action.clipboard"), variant = "ghost", glyph = "clipboard",
			onClick = function() ipc("clipboard", { device_id = dev.kde_id }) end, flexGrow = 1,
		}))
		table.insert(rows, ui.button({
			text = noctalia.tr("action.share"), variant = "ghost", glyph = "share",
			onClick = function()
				local draft = smsDrafts[dev.id]
				local text = draft and draft.msg or ""
				if text == "" then
					noctalia.notify("Phone Operate", noctalia.tr("notify.share_empty"))
				else
					ipc("share_text", { device_id = dev.kde_id, text = text })
				end
			end, flexGrow = 1,
		}))
	end

	if hasAdb(dev) then
		-- 投屏参数（分享按钮下方）
		table.insert(rows, ui.button({
			text = noctalia.tr("panel.section.params"), variant = paramsExpanded and "primary" or "ghost",
			glyph = "adjustments",
			onClick = function() paramsExpanded = not paramsExpanded; render() end, flexGrow = 1,
		}))
		if not hasKde(dev) then
			table.insert(rows, ui.button({
				text = noctalia.tr("action.disconnect"), variant = "ghost", glyph = "plug-off",
				onClick = function() ipc("disconnect", { device_id = dev.adb_id }) end, flexGrow = 1,
			}))
			table.insert(rows, ui.button({
				text = noctalia.tr("action.usb"), variant = "ghost", glyph = "usb",
				onClick = function() ipc("usb_mode", { device_id = dev.adb_id }) end, flexGrow = 1,
			}))
		end
	end

	if hasKde(dev) then
		table.insert(rows, dev.isPaired and ui.button({
			text = noctalia.tr("action.unpair"), variant = "ghost", glyph = "link-off",
			onClick = function() ipc("kde_unpair", { device_id = dev.kde_id }) end, flexGrow = 1,
		}) or ui.button({
			text = noctalia.tr("action.pair"), variant = "ghost", glyph = "link",
			onClick = function() ipc("kde_pair", { device_id = dev.kde_id }) end, flexGrow = 1,
		}))
	end

	return ui.column({ gap = 8, width = 140 }, rows)
end

-- ─── 主渲染 ───
function render()
	local rows = {}

	table.insert(rows, headerRow())
	table.insert(rows, ui.separator({ thickness = 1, spacing = 2 }))

	if #devices == 0 then
		table.insert(rows, ui.column({ gap = 10, align = "center", padding = 20 }, {
			ui.glyph({ name = "device-mobile", size = 40, color = "surface_variant" }),
			ui.label({ text = noctalia.tr("panel.empty_title"), color = "surface_variant" }),
			ui.button({
				text = noctalia.tr("panel.empty_cta"), variant = "primary", glyph = "wifi",
				onClick = function() pairExpanded = true; render() end,
			}),
		}))
	else
		local sw = deviceSwitcher()
		if sw then table.insert(rows, sw) end
		table.insert(rows, ui.separator({ thickness = 1, spacing = 2 }))

		local sel = findSelected()
		if sel then
			table.insert(rows, ui.row({ gap = 12, align = "stretch" }, {
				leftColumn(sel),
				ui.box({ width = 1, fill = "surface_variant/0.5" }),
				actionsColumn(sel),
			}))
		end
	end

	-- adb 无线配对 footer
	table.insert(rows, ui.separator({ thickness = 1, spacing = 2 }))
	if not pairExpanded then
		table.insert(rows, ui.button({
			text = noctalia.tr("panel.pair_add"), variant = "ghost", glyph = "wifi",
			onClick = function() pairExpanded = true; render() end, flexGrow = 1,
		}))
	else
		table.insert(rows, ui.column({ gap = 8 }, {
			ui.row({ gap = 8 }, {
				ui.input({
					key = "pair-addr",
					placeholder = noctalia.tr("panel.pair_addr_placeholder"),
					onChange = "onPairAddr",
					onSubmit = "onPairSubmit",
					flexGrow = 1,
				}),
				ui.input({
					key = "pair-code",
					placeholder = noctalia.tr("panel.pair_code_placeholder"),
					onChange = "onPairCode",
					onSubmit = "onPairSubmit",
					width = 140,
				}),
			}),
			ui.markdown({ text = noctalia.tr("panel.pair_hint") }),
			ui.row({ gap = 8 }, {
				ui.button({
					text = noctalia.tr("panel.pair_btn"), variant = "secondary", glyph = "link",
					onClick = "onPair", flexGrow = 1,
				}),
				ui.button({
					text = noctalia.tr("panel.cancel"), variant = "ghost",
					onClick = function() pairExpanded = false; render() end, flexGrow = 1,
				}),
			}),
		}))
	end

	panel.render(ui.scroll({ gap = 8, padding = 12 }, rows))
end

-- ─── 回调 ───
function onPair()
	if pairAddr and pairAddr ~= "" and pairCode and pairCode ~= "" then
		ipc("pair", { address = pairAddr, code = pairCode })
		pairAddr, pairCode = "", ""
		pairExpanded = false
		render()
	end
end

function onPairSubmit() onPair() end
function onPairAddr(v) pairAddr = v end
function onPairCode(v) pairCode = v end