-- panel.luau
-- 主力配置窗（双栏：左设备列表、右选中设备参数，见 UI 设计方案 B）。
-- 头部（标题+副标题+统计+刷新/全部停止）→ 双栏主体 → 底部配对 footer。
-- 颜色全部用 Noctalia 主题角色 token，由主题解析、可被主题更改；冲突以 Noctalia 为准。
-- 后端 IPC：新增 refresh / stop_all，其余事件不变。
local state = require("./lib/state.luau")
local persistence = require("./lib/persistence.luau")
local ipcMod = require("./lib/ipc.luau")

local devices = {}
local selectedDevice = nil
local params = {}
local renameDev = nil
local renameVal = ""
local pairAddr = ""
local pairCode = ""
local pairExpanded = false
local running = {}

-- ─── 参数预设（高清/性能/省电）───
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

noctalia.state.watch(state.KEY_DEVICES, function(d)
	devices = d or {}
	if (not selectedDevice) and #devices > 0 then
		selectedDevice = devices[1].id
		params = persistence.loadParams(selectedDevice)
	end
	render()
end)

noctalia.state.watch(state.KEY_RUNNING, function(r)
	running = r or {}
	render()
end)

function onOpen()
	devices = noctalia.state.get(state.KEY_DEVICES) or {}
	running = noctalia.state.get(state.KEY_RUNNING) or {}
	if #devices > 0 then
		selectedDevice = selectedDevice or devices[1].id
		params = persistence.loadParams(selectedDevice)
	end
	render()
end

-- ─── 状态药丸（底色/文字色/文案）───
local function statusPillOf(dev)
	if running[dev.id] then
		return "primary/0.16", "primary", noctalia.tr("panel.status_mirroring")
	elseif dev.online then
		return "primary/0.10", "primary", noctalia.tr("panel.status_online")
	else
		return "surface_variant/0.2", "surface_variant", noctalia.tr("panel.status_offline")
	end
end

local function sectionLabel(rows, text)
	table.insert(rows, ui.label({
		text = text, fontSize = 11, fontWeight = "bold", color = "surface_variant",
	}))
end

-- ─── 设备卡片（左栏）───
local function deviceCard(dev, rows)
	local isSel = (dev.id == selectedDevice)
	local isRenaming = (renameDev == dev.id)
	local isRunning = running[dev.id] ~= nil
	local pillFill, pillColor, statusText = statusPillOf(dev)

	if isRenaming then
		table.insert(rows, ui.row({
			key = "dev-" .. dev.id,
			fill = "primary/0.08", radius = 10, padding = 10, gap = 8, align = "center",
			border = "primary", borderWidth = 1,
		}, {
			ui.glyph({ name = dev.transport == "wifi" and "wifi" or "usb", size = 16 }),
			ui.input({
				key = "rename-input-" .. dev.id,
				value = renameVal,
				placeholder = noctalia.tr("panel.rename_placeholder"),
				onChange = "onRenameInput",
				onSubmit = "onRenameSubmit",
				flexGrow = 1,
			}),
			ui.button({
				glyph = "check", variant = "primary", controlSize = "sm",
				tooltip = noctalia.tr("panel.confirm"),
				onClick = "onRenameSubmit",
			}),
			ui.button({
				glyph = "x", variant = "ghost", controlSize = "sm",
				tooltip = noctalia.tr("panel.cancel"),
				onClick = function()
					renameDev = nil; renameVal = ""; render()
				end,
			}),
		}))
		return
	end

	local actionBtn
	if isRunning then
		actionBtn = ui.button({
			text = noctalia.tr("panel.stop"), variant = "destructive", glyph = "player-stop",
			controlSize = "sm",
			onClick = function() ipc("stop", { device_id = dev.id }) end,
		})
	elseif dev.online then
		actionBtn = ui.button({
			text = noctalia.tr("panel.cast"), variant = "primary", glyph = "player-play",
			controlSize = "sm",
			onClick = function() ipc("start", { device_id = dev.id }) end,
		})
	else
		actionBtn = ui.button({
			text = noctalia.tr("panel.cast"), variant = "ghost", glyph = "player-play",
			controlSize = "sm", enabled = false,
		})
	end

	-- 重命名：仅选中卡可见；用 opacity 占位（visible 切换会引发布局跳动）
	local editBtn = ui.button({
		glyph = "edit", variant = "ghost", controlSize = "sm",
		tooltip = noctalia.tr("panel.rename"),
		opacity = isSel and 1 or 0,
		enabled = isSel,
		onClick = function()
			renameDev = dev.id
			renameVal = persistence.loadName(dev.id) or ""
			render()
		end,
	})

	table.insert(rows, ui.row({
		key = "dev-" .. dev.id,
		fill = isSel and "primary/0.08" or "surface",
		radius = 12, padding = 10, gap = 8, align = "center",
		border = isSel and "primary" or "surface_variant/0.5",
		borderWidth = 1,
		onClick = function()
			selectedDevice = dev.id
			params = persistence.loadParams(dev.id)
			render()
		end,
	}, {
		ui.glyph({ name = dev.transport == "wifi" and "wifi" or "usb", size = 16, color = "on_surface" }),
		ui.column({ gap = 3, flexGrow = 1 }, {
			ui.label({ text = dev.label, fontWeight = "bold", color = "on_surface" }),
			ui.label({
				text = dev.transport .. " · " .. dev.id,
				fontSize = 11, color = "surface_variant",
			}),
		}),
		ui.row({ fill = pillFill, radius = 8, paddingH = 8, paddingV = 3 }, {
			ui.label({ text = statusText, fontSize = 11, color = pillColor }),
		}),
		actionBtn,
		editBtn,
	}))
end

-- ─── 头部（标题 + 副标题 | 统计 + 刷新 + 全部停止）───
local function headerRow()
	return ui.row({ gap = 10, align = "center" }, {
		ui.column({ gap = 2 }, {
			ui.label({ text = noctalia.tr("panel.title"), fontWeight = "bold" }),
			ui.label({
				text = noctalia.tr("panel.subtitle"),
				fontSize = 11, color = "surface_variant",
			}),
		}),
		ui.spacer({ flexGrow = 1 }),
		-- 在线统计
		ui.row({ gap = 4, align = "center" }, {
			ui.box({ width = 8, height = 8, radius = 4, fill = "primary" }),
			ui.label({
				text = tostring(countOnline()) .. " " .. noctalia.tr("panel.status_online"),
				fontSize = 12, color = "on_surface",
			}),
		}),
		-- 投屏中统计
		ui.row({ gap = 4, align = "center" }, {
			ui.glyph({ name = "device-tv", size = 14, color = "primary" }),
			ui.label({
				text = tostring(countRunning()) .. " " .. noctalia.tr("panel.status_mirroring"),
				fontSize = 12, color = "on_surface",
			}),
		}),
		ui.button({
			glyph = "rotate", variant = "ghost", controlSize = "sm",
			tooltip = noctalia.tr("panel.refresh"),
			onClick = function() ipc("refresh", {}) end,
		}),
		ui.button({
			glyph = "player-stop", variant = "ghost", controlSize = "sm",
			tooltip = noctalia.tr("panel.stop_all"),
			onClick = function() ipc("stop_all", {}) end,
		}),
	})
end

-- ─── 参数面板（右栏）───
local function paramsPanel()
	local rows = {}

	if not selectedDevice then
		table.insert(rows, ui.column({ gap = 10, align = "center", padding = 20 }, {
			ui.glyph({ name = "adjustments", size = 32, color = "surface_variant" }),
			ui.label({ text = noctalia.tr("panel.no_device"), color = "surface_variant" }),
		}))
		return ui.column({ gap = 8, flexGrow = 1 }, rows)
	end

	local dev = (function()
		for _, d in ipairs(devices) do
			if d.id == selectedDevice then return d end
		end
		return nil
	end)()
	local devLabel = dev and dev.label or selectedDevice

	-- 标题 + 提示
	table.insert(rows, ui.column({ gap = 2 }, {
		ui.label({
			text = noctalia.tr("panel.current_device") .. " · " .. devLabel,
			fontWeight = "bold",
		}),
		ui.label({
			text = noctalia.tr("panel.params_hint"),
			fontSize = 11, color = "surface_variant",
		}),
	}))

	-- 预设快捷
	local function applyPreset(p)
		for k, v in pairs(p) do params[k] = v end
		persistence.saveParams(selectedDevice, params)
		ipcRestartWithParams()
		render()
	end
	table.insert(rows, ui.row({ gap = 8 }, {
		ui.button({
			text = noctalia.tr("panel.preset_hd"), variant = "ghost", controlSize = "sm",
			onClick = function() applyPreset(PRESETS.hd) end, flexGrow = 1,
		}),
		ui.button({
			text = noctalia.tr("panel.preset_perf"), variant = "ghost", controlSize = "sm",
			onClick = function() applyPreset(PRESETS.perf) end, flexGrow = 1,
		}),
		ui.button({
			text = noctalia.tr("panel.preset_save"), variant = "ghost", controlSize = "sm",
			onClick = function() applyPreset(PRESETS.save) end, flexGrow = 1,
		}),
	}))

	-- 滑块组：onChange 只做实时预览，onDragEnd 才存参+重启（拖动中不连环重启 scrcpy）
	local function paramSlider(labelKey, val, min, max, step, suffix, setter)
		table.insert(rows, ui.row({ gap = 8, align = "center" }, {
			ui.label({ text = noctalia.tr(labelKey), width = 72, color = "surface_variant" }),
			ui.slider({
				min = min, max = max, step = step, value = val,
				onChange = function(v)
					setter(tonumber(v))
					render()
				end,
				onDragEnd = function(v)
					if v ~= nil then setter(tonumber(v)) end
					persistence.saveParams(selectedDevice, params)
					ipcRestartWithParams()
					render()
				end,
				flexGrow = 1,
			}),
			ui.label({ text = tostring(val) .. suffix, width = 48, color = "on_surface" }),
		}))
	end

	paramSlider("panel.max_size", params.max_size or 1920,
		256, 4096, 64, "", function(v) params.max_size = v end)
	paramSlider("panel.bit_rate", params.bit_rate or 8,
		1, 100, 1, "M", function(v) params.bit_rate = v end)
	paramSlider("panel.max_fps", params.max_fps or 60,
		1, 120, 1, "", function(v) params.max_fps = v end)

	-- 开关组（名称 + 小字说明 + toggle）
	local function toggleBlock(labelKey, descKey, checked, setter)
		table.insert(rows, ui.column({ gap = 2 }, {
			ui.row({ gap = 8, align = "center" }, {
				ui.label({ text = noctalia.tr(labelKey), color = "on_surface", flexGrow = 1 }),
				ui.toggle({
					checked = checked,
					onChange = function(v)
						setter(v == "true")
						persistence.saveParams(selectedDevice, params)
						ipcRestartWithParams()
						render()
					end,
				}),
			}),
			ui.label({
				text = noctalia.tr(descKey),
				fontSize = 11, color = "surface_variant",
			}),
		}))
	end

	toggleBlock("panel.turn_screen_off", "panel.turn_screen_off_desc",
		params.turn_screen_off or false, function(v) params.turn_screen_off = v end)
	toggleBlock("panel.record", "panel.record_desc",
		params.record or false, function(v) params.record = v end)

	-- 断开 / 回 USB
	table.insert(rows, ui.row({ gap = 8 }, {
		ui.button({
			text = noctalia.tr("panel.disconnect"), variant = "ghost", glyph = "plug-off",
			onClick = "onDisconnect", flexGrow = 1,
		}),
		ui.button({
			text = noctalia.tr("panel.usb_mode"), variant = "ghost", glyph = "usb",
			onClick = "onUsbMode", flexGrow = 1,
		}),
	}))

	return ui.column({ gap = 8, flexGrow = 1 }, rows)
end

-- ─── 左栏：设备列表 ───
local function devicesPanel()
	local rows = {}
	sectionLabel(rows, noctalia.tr("panel.section.devices"))

	if #devices == 0 then
		-- 空状态
		table.insert(rows, ui.column({ gap = 10, align = "center", padding = 16 }, {
			ui.glyph({ name = "device-mobile", size = 40, color = "surface_variant" }),
			ui.label({ text = noctalia.tr("panel.empty_title"), color = "surface_variant" }),
			ui.button({
				text = noctalia.tr("panel.empty_cta"), variant = "primary", glyph = "wifi",
				onClick = function() pairExpanded = true; render() end,
			}),
		}))
	else
		for _, dev in ipairs(devices) do
			deviceCard(dev, rows)
		end
	end

	return ui.column({ gap = 8, flexGrow = 1 }, rows)
end

function render()
	local rows = {}

	table.insert(rows, headerRow())
	table.insert(rows, ui.separator({ thickness = 1, spacing = 2 }))

	-- 双栏主体：左设备 / 右参数（stretch 让两栏与分隔线等高对齐）
	table.insert(rows, ui.row({ gap = 12, align = "stretch" }, {
		devicesPanel(),
		ui.box({ width = 1, fill = "surface_variant/0.5" }),
		paramsPanel(),
	}))

	-- footer：配对（渐进披露）
	table.insert(rows, ui.separator({ thickness = 1, spacing = 2 }))
	if not pairExpanded then
		table.insert(rows, ui.button({
			text = noctalia.tr("panel.pair_add"), variant = "primary", glyph = "wifi",
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
function onDisconnect()
	if not selectedDevice then return end
	ipc("disconnect", { device_id = selectedDevice })
end

function onUsbMode()
	if not selectedDevice then return end
	ipc("usb_mode", { device_id = selectedDevice })
end

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

function onRenameSubmit()
	if renameDev then
		ipc("rename", { device_id = renameDev, name = renameVal })
		renameDev = nil
		renameVal = ""
	end
end

function onRenameInput(v) renameVal = v end
