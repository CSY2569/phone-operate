-- panel.luau
-- 合并面板：phone-connect 的完整 UI（设备卡/媒体/短信/操作栏/页脚）+ scrcpy：
--   adb 设备（id 前缀 "adb:"）在右栏显示 投屏/停止、投屏参数、断开；
--   「投屏参数」展开时覆盖左栏。参数读 lib/persistence，写经 pc.cmd 通道。

local persistence = require("./lib/persistence.luau")

local function t(key)
	local table = noctalia.state.get("pc.trTable") or {}
	return table[key] or key
end

-- ── 命令通道 ─────────────────────────────────────────────────────────────────
local cmdSeq = 0
local function sendCmd(cmd)
	cmdSeq = cmdSeq + 1
	cmd.seq = os.time() * 1000000 + cmdSeq
	noctalia.state.set("pc.cmd", cmd)
end

-- ── 每设备 UI 状态 ───────────────────────────────────────────────────────────
local smsDrafts = {}
local function draftFor(id)
	local d = smsDrafts[id]
	if not d then
		d = { dest = "", msg = "" }
		smsDrafts[id] = d
	end
	return d
end

local mediaDragState = {}
local volumeDragState = {}
local mutedPrevVolume = {}
local deviceNameEdits = {}

-- ── scrcpy 参数状态 ──────────────────────────────────────────────────────────
local paramsExpanded = true
local activePreset = nil
local pairExpanded = false
local pairAddr = ""
local pairCode = ""

local PRESETS = {
	hd   = { max_size = 1920, bit_rate = 16, max_fps = 60 },
	perf = { max_size = 1280, bit_rate = 8,  max_fps = 60 },
	save = { max_size = 1024, bit_rate = 4,  max_fps = 30 },
}

-- ── 工具 ─────────────────────────────────────────────────────────────────────
local function glyphForType(tp)
	if tp == "tablet" then return "device-tablet" end
	if tp == "laptop" then return "device-laptop" end
	if tp == "desktop" or tp == "computer" then return "device-desktop" end
	if tp == "tv" then return "device-tv" end
	return "device-mobile"
end

local function batteryGlyph(charge, charging)
	if charging then return "battery-charging" end
	if type(charge) ~= "number" then return "battery" end
	if charge >= 90 then return "battery" end
	if charge >= 60 then return "battery-3" end
	if charge >= 30 then return "battery-2" end
	if charge > 0 then return "battery-1" end
	return "battery-off"
end

local function fmtTime(ms)
	if type(ms) ~= "number" or ms <= 0 then return "0:00" end
	local s = math.floor(ms / 1000)
	local m = math.floor(s / 60)
	s = s % 60
	return string.format("%d:%02d", m, s)
end

-- ── 头部：连接数 + 设备切换器 + 刷新/关闭 ─────────────────────────────────────
local function headerRow(order, devices, sel)
	local connected = 0
	for _, id in ipairs(order) do
		local d = devices[id]
		if d and d.isPaired and d.isReachable then connected = connected + 1 end
	end
	local connText = t("panel.devices_connected"):gsub("{connected}", tostring(connected))
	local aliasMap = noctalia.state.get("pc.aliasMap") or {}
	local multi = #order > 1
	local kids = {
		ui.glyph({ name = "device-mobile", size = 18, color = "primary" }),
		ui.label({ text = connText, fontSize = 13, fontWeight = "medium",
			color = "on_surface", flexGrow = multi and 0 or 1 }),
	}
	if multi then
		for idx, id in ipairs(order) do
			local d = devices[id]
			if d then
				local isSel = id == sel
				local devName = aliasMap[id] or d.name or "Your-Phone"
				table.insert(kids, ui.button({
					key = "sw-" .. id,
					text = tostring(idx),
					glyph = d.source == "adb"
						and (d.transport == "wifi" and "wifi" or "usb")
						or glyphForType(d.type),
					variant = isSel and "primary" or "outline",
					controlSize = "sm",
					selected = isSel,
					flexGrow = 1,
					tooltip = devName,
					onClick = function()
						paramsExpanded = true
						sendCmd({ op = "select", device = id })
					end,
				}))
			end
		end
	end
	table.insert(kids, ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm",
		tooltip = t("action.refresh"),
		onClick = function() sendCmd({ op = "refresh" }) end }))
	table.insert(kids, ui.button({ glyph = "close", variant = "ghost", controlSize = "sm",
		tooltip = t("panel.close"),
		onClick = function() panel.close() end }))
	return ui.row({ gap = 8, align = "center" }, kids)
end

-- ── 设备卡 ───────────────────────────────────────────────────────────────────
local function adbDeviceCard(d)
	local online = d.isReachable == true
	local runningMap = noctalia.state.get("pc.running") or {}
	local casting = runningMap[d.adbId] == true
	local statusText = online and t("status.connected") or t("status.offline")
	local statusColor = online and "primary" or "on_surface_variant"

	return ui.row({ gap = 10, padding = 12, radius = 10, fill = "surface/0.7",
		border = "primary/0.2", borderWidth = 1, align = "center" }, {
		ui.box({ width = 44, height = 44, radius = 22, fill = "primary/0.15" }, {
			ui.glyph({ name = d.transport == "wifi" and "wifi" or "usb",
				size = 24, color = "primary" }),
		}),
		ui.column({ gap = 3, flexGrow = 1, minWidth = 0 }, {
			ui.label({ text = d.name, fontSize = 14, fontWeight = "bold",
				color = "on_surface", maxLines = 1 }),
			ui.row({ gap = 6, align = "center" }, {
				ui.row({ radius = 8, fill = statusColor .. "/0.15", paddingH = 6, paddingV = 2 }, {
					ui.label({ text = statusText, fontSize = 10, color = statusColor }),
				}),
				casting and ui.row({ radius = 8, fill = "primary/0.15", paddingH = 6, paddingV = 2 }, {
					ui.label({ text = t("status.mirroring"), fontSize = 10, color = "primary" }),
				}) or nil,
			}),
		}),
	})
end

local function deviceCard(d)
	if d.source == "adb" then
		return adbDeviceCard(d)
	end

	local reachable = d.isPaired == true and d.isReachable == true
	local aliasMap = noctalia.state.get("pc.aliasMap") or {}
	local name = aliasMap[d.id] or d.name or "Your-Phone"
	local glyph = glyphForType(d.type)
	local imgMap = noctalia.state.get("pc.imageMap") or {}
	local imgPath = imgMap[d.id]
	if imgPath and imgPath ~= "" and not noctalia.fileExists(imgPath) then
		noctalia.log("[phone-operate] image not found: " .. imgPath)
	end

	local statusText, statusColor
	if not reachable then
		statusText = t("status.offline")
		statusColor = "on_surface_variant"
	else
		statusText = t("status.connected")
		statusColor = "primary"
	end

	local charge = d.batteryCharge
	local hasCharge = type(charge) == "number" and charge >= 0
	local chargeText = hasCharge and (tostring(charge) .. "%") or "--"
	local chargeColor = "on_surface"
	if hasCharge and charge <= 20 then chargeColor = "error" end
	local charging = d.batteryCharging == true

	local netText = (d.networkType and d.networkType ~= "")
		and (d.networkType .. (type(d.networkStrength) == "number"
			and d.networkStrength >= 0 and (" " .. tostring(d.networkStrength) .. "/4") or ""))
		or "--"

	local vol = tonumber(d.mediavolume)
	local hasVol = type(vol) == "number" and vol >= 0
	local muted = hasVol and vol <= 0
	local vDrag = volumeDragState[d.id]
	local vFrozen = vDrag and vDrag.dragging and (os.clock() - (vDrag.at or 0)) < 2.0
	if vDrag and vDrag.dragging and not vFrozen then volumeDragState[d.id] = nil end
	local volValue = vFrozen and vDrag.position or (hasVol and vol or 0)
	local volLabel = hasVol and (tostring(math.floor(volValue)) .. "%") or "--"

	local function toggleMute()
		if not hasVol then return end
		if muted then
			local restore = mutedPrevVolume[d.id] or 50
			sendCmd({ op = "media_set_volume", device = d.id, volume = tostring(restore) })
		else
			mutedPrevVolume[d.id] = vol
			sendCmd({ op = "media_set_volume", device = d.id, volume = "0" })
		end
	end

	local volumeGroup
	if hasVol then
		volumeGroup = ui.row({ gap = 4, align = "center", width = 132 }, {
			ui.button({
				glyph = muted and "volume-off" or "volume",
				variant = "ghost",
				controlSize = "sm",
				glyphSize = 13,
				tooltip = t(muted and "media.unmute" or "media.mute"),
				onClick = toggleMute,
			}),
			ui.label({ text = volLabel, fontSize = 10, color = "on_surface_variant", width = 34 }),
			ui.slider({
				key = "vol-" .. d.id,
				min = 0, max = 100, step = 1, value = volValue,
				controlSize = "sm", enabled = reachable, flexGrow = 1,
				onChange = function(v)
					volumeDragState[d.id] = { dragging = true, position = tonumber(v) or 0, at = os.clock() }
				end,
				onDragEnd = function()
					local st = volumeDragState[d.id]
					local target = (st and st.position) or (hasVol and vol or 0)
					volumeDragState[d.id] = nil
					sendCmd({ op = "media_set_volume", device = d.id, volume = tostring(target) })
				end,
			}),
		})
	end

	local function pickImage()
		sendCmd({ op = "pick_image", device = d.id })
	end

	local function commitName(v)
		local newName = (v or ""):gsub("^%s+", ""):gsub("%s+$", "")
		deviceNameEdits[d.id] = nil
		sendCmd({ op = "set_alias", device = d.id, alias = newName })
		render()
	end

	return ui.row({ gap = 10, padding = 12, radius = 10, fill = "surface/0.7",
		border = "primary/0.2", borderWidth = 1, align = "center" }, {
		imgPath and ui.image({ path = imgPath, width = 44, height = 44,
			radius = 22, fit = "cover", onClick = pickImage })
			or ui.box({ width = 44, height = 44, radius = 22, fill = "primary/0.15",
				onClick = pickImage }, {
				ui.glyph({ name = glyph, size = 24, color = "primary" }),
				ui.glyph({ name = "pencil", size = 10, color = "on_surface_variant" }),
			}),
		ui.column({ gap = 3, flexGrow = 1, minWidth = 0 }, {
			deviceNameEdits[d.id] and ui.input({
				key = "name-edit-" .. d.id,
				value = name,
				placeholder = name,
				controlSize = "sm",
				onSubmit = commitName,
			})
			or ui.row({ gap = 4, align = "center", onClick = function()
					deviceNameEdits[d.id] = true
					render()
				end }, {
				ui.label({ text = name, fontSize = 14, fontWeight = "bold",
					color = "on_surface", maxLines = 1 }),
				ui.glyph({ name = "pencil", size = 10, color = "on_surface_variant" }),
			}),
			ui.row({ gap = 6, align = "center" }, {
				ui.row({ radius = 8, fill = statusColor .. "/0.15", paddingH = 6, paddingV = 2 }, {
					ui.label({ text = statusText, fontSize = 10, color = statusColor }),
				}),
			}),
		}),
		volumeGroup,
		ui.column({ gap = 2, align = "center", width = 52 }, {
			ui.glyph({ name = "antenna", size = 16,
				color = (reachable and d.networkType and d.networkType ~= "") and "primary" or "on_surface_variant" }),
			ui.label({ text = netText, fontSize = 9, color = "on_surface_variant" }),
		}),
		ui.column({ gap = 2, align = "center", width = 52 }, {
			ui.glyph({ name = batteryGlyph(charge, charging), size = 16, color = chargeColor }),
			ui.label({ text = chargeText, fontSize = 10, fontWeight = "medium", color = chargeColor }),
		}),
	})
end

-- ── 右栏操作按钮 ─────────────────────────────────────────────────────────────
local function vActionBtn(text, glyph, onClick, variant, tooltip)
	return ui.button({ text = text, glyph = glyph, variant = variant or "outline",
		controlSize = "md", tooltip = tooltip, onClick = onClick })
end

local function rightColumn(d)
	if d.source == "adb" then
		local runningMap = noctalia.state.get("pc.running") or {}
		local casting = runningMap[d.adbId] == true
		local btns = {}
		table.insert(btns, vActionBtn(casting and t("action.stop") or t("action.cast"),
			casting and "player-stop" or "player-play",
			function()
				sendCmd(casting and { op = "stop_cast", device = d.adbId }
					or { op = "cast", device = d.adbId })
			end, casting and "destructive" or "primary"))
		table.insert(btns, vActionBtn(t("panel.params"), "adjustments",
			function()
				paramsExpanded = not paramsExpanded
				render()
			end, paramsExpanded and "primary" or "outline"))
		table.insert(btns, vActionBtn(t("action.disconnect"), "plug-off",
			function() sendCmd({ op = "adb_disconnect", device = d.adbId }) end, "ghost"))
		return ui.column({ width = 110 }, {
			ui.scroll({ flexGrow = 1, gap = 8, padding = 8, align = "stretch" }, btns),
		})
	end

	local reachable = d.isReachable == true
	local paired = d.isPaired == true
	local btns = {}
	if reachable and paired then
		table.insert(btns, vActionBtn(t("action.ring"), "bell-ringing",
			function() sendCmd({ op = "ring", device = d.id }) end, "primary"))
		table.insert(btns, vActionBtn(t("action.ping"), "message",
			function() sendCmd({ op = "ping", device = d.id }) end))
		table.insert(btns, vActionBtn(t("action.browse"), "folder",
			function() sendCmd({ op = "browse", device = d.id }) end))
		if noctalia.getConfig("enable_clipboard_action") then
			table.insert(btns, vActionBtn(t("action.clipboard"), "clipboard",
				function() sendCmd({ op = "clipboard", device = d.id }) end))
		end
		table.insert(btns, vActionBtn(t("action.share"), "share",
			function() sendCmd({ op = "pick_share", device = d.id }) end))
		table.insert(btns, vActionBtn(t("action.unpair"), "link-off",
			function() sendCmd({ op = "unpair", device = d.id }) end, "ghost"))
	elseif not paired then
		table.insert(btns, vActionBtn(t("action.pair"), "link",
			function() sendCmd({ op = "pair", device = d.id }) end, "primary"))
	else
		table.insert(btns, vActionBtn(t("action.unpair"), "link-off",
			function() sendCmd({ op = "unpair", device = d.id }) end, "ghost"))
	end
	return ui.column({ width = 110 }, {
		ui.scroll({ flexGrow = 1, gap = 8, padding = 8, align = "stretch" }, btns),
	})
end

-- ── 左栏：媒体 + 短信（connect 原版） ──────────────────────────────────────────
local function mediaSection(d)
	local title = d.mediatitle
	if not title or title == "" then
		return ui.column({ gap = 6, padding = 10, radius = 8, fill = "surface/0.5" }, {
			ui.row({ gap = 6, align = "center" }, {
				ui.glyph({ name = "music", size = 13, color = "primary" }),
				ui.label({ text = t("panel.now_playing"), fontSize = 10,
					color = "primary", fontWeight = "bold", flexGrow = 1 }),
			}),
			ui.row({ gap = 8, align = "center" }, {
				ui.glyph({ name = "music-off", size = 20, color = "on_surface_variant" }),
				ui.label({ text = t("panel.no_media"), fontSize = 11,
					color = "on_surface_variant" }),
			}),
		})
	end
	local artist = d.mediaartist or ""
	local album = d.mediaalbum or ""
	local playing = d.mediaisPlaying == true
	local length = tonumber(d.medialength) or 0
	local position = tonumber(d.mediaposition) or 0
	local canSeek = d.mediacanSeek == true
	local artUrl = d.mediaArtPath

	if artUrl and artUrl ~= "" and not noctalia.fileExists(artUrl) then
		artUrl = nil
	end

	local header = ui.row({ gap = 6, align = "center" }, {
		ui.glyph({ name = "music", size = 13, color = "primary" }),
		ui.label({ text = t("panel.now_playing"), fontSize = 10,
			color = "primary", fontWeight = "bold", flexGrow = 1 }),
	})

	local titleBlock
	if artUrl then
		titleBlock = ui.row({ gap = 8, align = "center" }, {
			ui.image({ path = artUrl, width = 36, height = 36, radius = 4, fit = "cover" }),
			ui.column({ gap = 1, flexGrow = 1 }, {
				ui.label({ text = title, fontSize = 12, fontWeight = "medium",
					color = "on_surface", maxLines = 1 }),
				ui.label({ text = artist, fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
				ui.label({ text = album, fontSize = 9, color = "on_surface_variant", maxLines = 1 }),
			}),
		})
	else
		titleBlock = ui.column({ gap = 1 }, {
			ui.label({ text = title, fontSize = 12, fontWeight = "medium",
				color = "on_surface", maxLines = 1 }),
			ui.label({ text = artist, fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
			ui.label({ text = album, fontSize = 9, color = "on_surface_variant", maxLines = 1 }),
		})
	end

	local transport = ui.row({ gap = 4, align = "center" }, {
		ui.button({ glyph = "player-skip-back", variant = "ghost", controlSize = "sm",
			tooltip = t("media.previous"),
			onClick = function() sendCmd({ op = "media", device = d.id, action = "Previous" }) end }),
		ui.button({ glyph = playing and "player-pause" or "player-play",
			variant = "primary", controlSize = "sm",
			tooltip = t(playing and "media.pause" or "media.play"),
			onClick = function() sendCmd({ op = "media", device = d.id, action = "PlayPause" }) end }),
		ui.button({ glyph = "player-skip-forward", variant = "ghost", controlSize = "sm",
			tooltip = t("media.next"),
			onClick = function() sendCmd({ op = "media", device = d.id, action = "Next" }) end }),
		ui.button({ glyph = "player-stop", variant = "ghost", controlSize = "sm",
			tooltip = t("media.stop"),
			onClick = function() sendCmd({ op = "media", device = d.id, action = "Stop" }) end }),
	})

	local progress
	if canSeek and length > 0 then
		local st = mediaDragState[d.id]
		local frozen = st and st.dragging and (os.clock() - (st.at or 0)) < 2.0
		if st and st.dragging and not frozen then mediaDragState[d.id] = nil end
		local sliderValue = frozen and st.position or position
		progress = ui.column({ gap = 2 }, {
			ui.slider({ min = 0, max = length, step = 1000, value = sliderValue,
				controlSize = "sm",
				onChange = function(v)
					mediaDragState[d.id] = { dragging = true, position = tonumber(v) or position, at = os.clock() }
				end,
				onDragEnd = function()
					local st2 = mediaDragState[d.id]
					local target = (st2 and st2.position) or position
					mediaDragState[d.id] = nil
					sendCmd({ op = "media_seek", device = d.id, offset = tostring(target) })
				end }),
			ui.row({ justify = "space_between" }, {
				ui.label({ text = fmtTime(sliderValue), fontSize = 9, color = "on_surface_variant" }),
				ui.label({ text = fmtTime(length), fontSize = 9, color = "on_surface_variant" }),
			}),
		})
	end

	local children = { header, titleBlock, transport }
	if progress then table.insert(children, progress) end
	return ui.column({ gap = 6, padding = 10, radius = 8, fill = "primary/0.08" }, children)
end

local function smsComposer(d)
	local draft = draftFor(d.id)
	return ui.column({ gap = 8, padding = 12, radius = 8, fill = "surface/0.5",
		border = "on_surface/0.1", borderWidth = 1 }, {
		ui.label({ text = t("panel.sms"), fontSize = 12, fontWeight = "bold",
			color = "on_surface" }),
		ui.input({ key = "sms-dest-" .. d.id, placeholder = t("panel.sms_dest"),
			value = draft.dest, controlSize = "sm",
			onChange = function(v) draftFor(d.id).dest = v end }),
		ui.input({ key = "sms-msg-" .. d.id, placeholder = t("panel.sms_msg"),
			value = draft.msg, controlSize = "sm",
			onChange = function(v) draftFor(d.id).msg = v end }),
		ui.button({ text = t("panel.sms_send"), glyph = "send",
			variant = "primary", controlSize = "sm",
			onClick = function()
				local df = draftFor(d.id)
				if df.dest ~= "" and df.msg ~= "" then
					sendCmd({ op = "sms_send", device = d.id,
						destination = df.dest, text = df.msg })
					df.msg = ""
					render()
				end
			end }),
	})
end

-- ── 投屏参数面板（adb 设备，覆盖左栏） ────────────────────────────────────────
local function paramsPanel(d)
	local adbId = d.adbId
	local params = persistence.loadParams(adbId)

	local function commit()
		persistence.saveParams(adbId, params)
		persistence.saveCustom(adbId, params)
		sendCmd({ op = "restart_params", device = adbId, params = params })
	end

	local function applyPreset(key, p)
		activePreset = key
		for k, v in pairs(p) do params[k] = v end
		commit()
		render()
	end

	local children = {}

	table.insert(children, ui.row({ gap = 4 }, {
		ui.button({ text = t("panel.preset_hd"), variant = "ghost", controlSize = "sm",
			selected = activePreset == "hd",
			onClick = function() applyPreset("hd", PRESETS.hd) end, flexGrow = 1 }),
		ui.button({ text = t("panel.preset_perf"), variant = "ghost", controlSize = "sm",
			selected = activePreset == "perf",
			onClick = function() applyPreset("perf", PRESETS.perf) end, flexGrow = 1 }),
		ui.button({ text = t("panel.preset_save"), variant = "ghost", controlSize = "sm",
			selected = activePreset == "save",
			onClick = function() applyPreset("save", PRESETS.save) end, flexGrow = 1 }),
		ui.button({ text = t("panel.preset_custom"), variant = "ghost", controlSize = "sm",
			selected = activePreset == "custom",
			onClick = function()
				activePreset = "custom"
				local c = persistence.loadCustom(adbId)
				if c then
					for k, v in pairs(c) do params[k] = v end
					commit()
				end
				render()
			end, flexGrow = 1 }),
	}))

	local function paramSlider(labelKey, val, min, max, step, suffix, setter)
		table.insert(children, ui.row({ key = "row-" .. labelKey, gap = 8, align = "center" }, {
			ui.label({ text = t(labelKey), width = 72, fontSize = 11, color = "on_surface_variant" }),
			ui.slider({
				key = "slider-" .. labelKey,
				min = min, max = max, step = step, value = val,
				controlSize = "sm",
				onChange = function(v)
					setter(tonumber(v))
					activePreset = "custom"
					render()
				end,
				onDragEnd = function()
					activePreset = "custom"
					commit()
					render()
				end,
				flexGrow = 1,
			}),
			ui.label({ text = tostring(val) .. suffix, width = 48, fontSize = 11, color = "on_surface" }),
		}))
	end

	paramSlider("panel.max_size", params.max_size or 1920, 256, 3840, 64, "",
		function(v) params.max_size = v end)
	paramSlider("panel.bit_rate", params.bit_rate or 8, 1, 30, 1, "M",
		function(v) params.bit_rate = v end)
	paramSlider("panel.max_fps", params.max_fps or 60, 1, 240, 1, "",
		function(v) params.max_fps = v end)

	local function toggleBlock(labelKey, descKey, checked, setter)
		table.insert(children, ui.column({ gap = 2 }, {
			ui.row({ gap = 8, align = "center" }, {
				ui.label({ text = t(labelKey), fontSize = 12, color = "on_surface", flexGrow = 1 }),
				ui.toggle({
					checked = checked,
					onChange = function(v)
						setter(v == "true")
						activePreset = "custom"
						commit()
						render()
					end,
				}),
			}),
			ui.label({ text = t(descKey), fontSize = 10, color = "on_surface_variant" }),
		}))
	end

	toggleBlock("panel.turn_screen_off", "panel.turn_screen_off_desc",
		params.turn_screen_off or false, function(v) params.turn_screen_off = v end)
	toggleBlock("panel.record", "panel.record_desc",
		params.record or false, function(v) params.record = v end)

	local scrollItems = {
		ui.column({ gap = 6, padding = 10, radius = 8, fill = "surface/0.5",
			border = "on_surface/0.1", borderWidth = 1 },
			{ ui.label({ text = t("panel.params"), fontSize = 12, fontWeight = "bold",
				color = "on_surface" }),
				ui.label({ text = t("panel.params_hint"), fontSize = 10, color = "on_surface_variant" }) }),
	}
	for _, c in ipairs(children) do
		table.insert(scrollItems, c)
	end
	return ui.column({ flexGrow = 1 }, {
		ui.scroll({ flexGrow = 1, gap = 10, padding = 0 }, scrollItems),
	})
end

-- ── 左栏 ─────────────────────────────────────────────────────────────────────
local function leftColumn(d)
	if d.source == "adb" then
		if paramsExpanded then
			return paramsPanel(d)
		end
		return ui.column({ flexGrow = 1 }, {
			ui.scroll({ flexGrow = 1, gap = 12, padding = 0 }, {
				ui.column({ gap = 6, padding = 10, radius = 8, fill = "surface/0.5" }, {
					ui.row({ gap = 6, align = "center" }, {
						ui.glyph({ name = "device-mobile", size = 13, color = "primary" }),
						ui.label({ text = t("panel.params"), fontSize = 10,
							color = "primary", fontWeight = "bold", flexGrow = 1 }),
					}),
					ui.label({ text = t("panel.adb_hint"), fontSize = 11, color = "on_surface_variant" }),
				}),
			}),
		})
	end
	local items = {}
	table.insert(items, mediaSection(d))
	if d.isReachable and d.isPaired then
		table.insert(items, smsComposer(d))
	end
	return ui.column({ flexGrow = 1 }, {
		ui.scroll({ flexGrow = 1, gap = 12, padding = 0 }, items),
	})
end

-- ── 页脚：设备地址 ────────────────────────────────────────────────────────────
local function infoFooter(d)
	if d.source == "adb" then
		local function cell(label, val)
			return ui.column({ gap = 2, padding = 6, radius = 6, fill = "surface/0.5",
				flexGrow = 1 }, {
				ui.label({ text = label, fontSize = 9, color = "on_surface_variant" }),
				ui.label({ text = val or "--", fontSize = 10, maxLines = 1,
					color = val and "on_surface" or "on_surface_variant" }),
			})
		end
		return ui.row({ gap = 8 }, {
			cell("ADB ID", d.adbId),
			cell("USB/WiFi", d.transport or "usb"),
		})
	end
	local function ipCell(label, ip)
		return ui.column({ gap = 2, padding = 6, radius = 6, fill = "surface/0.5",
			flexGrow = 1 }, {
			ui.label({ text = label, fontSize = 9, color = "on_surface_variant" }),
			ui.label({ text = ip or "--", fontSize = 10, maxLines = 1,
				color = ip and "on_surface" or "on_surface_variant" }),
		})
	end
	return ui.row({ gap = 8 }, {
		ipCell("IPv4", d.ipv4),
		ipCell("IPv6", d.ipv6),
	})
end

-- ── adb 无线配对（折叠） ──────────────────────────────────────────────────────
local function pairSection()
	if pairExpanded then
		return ui.column({ gap = 8, padding = 10, radius = 8, fill = "surface/0.5",
			border = "on_surface/0.1", borderWidth = 1 }, {
			ui.row({ gap = 8 }, {
				ui.input({ key = "pair-addr", placeholder = t("panel.pair_addr_placeholder"),
					controlSize = "sm",
					onChange = function(v) pairAddr = v end, flexGrow = 1 }),
				ui.input({ key = "pair-code", placeholder = t("panel.pair_code_placeholder"),
					controlSize = "sm", width = 140,
					onChange = function(v) pairCode = v end }),
			}),
			ui.markdown({ text = t("panel.pair_hint") }),
			ui.row({ gap = 8 }, {
				ui.button({ text = t("panel.pair_btn"), glyph = "link",
					variant = "secondary", controlSize = "sm",
					onClick = function()
						if pairAddr ~= "" and pairCode ~= "" then
							sendCmd({ op = "adb_pair", address = pairAddr, code = pairCode })
							pairAddr, pairCode = "", ""
							pairExpanded = false
							render()
						end
					end, flexGrow = 1 }),
				ui.button({ text = t("panel.cancel"), variant = "ghost", controlSize = "sm",
					onClick = function()
						pairExpanded = false
						render()
					end, flexGrow = 1 }),
			}),
		})
	end
	return ui.button({ text = t("panel.pair_add"), glyph = "wifi",
		variant = "ghost", controlSize = "sm",
		onClick = function()
			pairExpanded = true
			render()
		end, flexGrow = 1 })
end

-- ── 主渲染 ───────────────────────────────────────────────────────────────────
function render()
	local backend = noctalia.state.get("pc.backend") or { available = false }
	local devices = noctalia.state.get("pc.devices") or {}
	local order = noctalia.state.get("pc.order") or {}
	local sel = noctalia.state.get("pc.selected")
	if not sel or not devices[sel] then sel = order[1] end

	local body = {}
	table.insert(body, headerRow(order, devices, sel))

	if not backend.available and #order == 0 then
		table.insert(body, ui.column({ gap = 8, padding = 40, align = "center", flexGrow = 1 }, {
			ui.glyph({ name = "phone-off", size = 40, color = "on_surface_variant" }),
			ui.label({ text = t("status.no_backend"), color = "on_surface_variant" }),
		}))
	elseif not sel or not devices[sel] then
		table.insert(body, ui.column({ gap = 8, padding = 40, align = "center", flexGrow = 1 }, {
			ui.glyph({ name = "phone-off", size = 40, color = "on_surface_variant" }),
			ui.label({ text = t("panel.empty"), color = "on_surface_variant" }),
		}))
	else
		local d = devices[sel]
		table.insert(body, deviceCard(d))
		table.insert(body, ui.row({ gap = 14, flexGrow = 1, align = "stretch", justify = "center" }, {
			leftColumn(d),
			rightColumn(d),
		}))
		table.insert(body, infoFooter(d))
	end

	table.insert(body, pairSection())

	panel.render(ui.column({ gap = 10, padding = 12 }, body))
end

function onOpen(_context) render() end
function onClose() end

noctalia.state.watch("pc.devices", render)
noctalia.state.watch("pc.order", render)
noctalia.state.watch("pc.selected", render)
noctalia.state.watch("pc.backend", render)
noctalia.state.watch("pc.imageMap", render)
noctalia.state.watch("pc.trTable", render)
noctalia.state.watch("pc.aliasMap", render)
noctalia.state.watch("pc.running", render)