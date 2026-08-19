-- panel.luau
-- 主力配置窗。按 UI-design 截图样式还原（见开发文档 §4.2 ASCII 模拟）：
--   选中卡左侧翠绿轨；卡片多行（图标+名称 / 副标题）；右侧状态药丸 + 操作按钮；
--   熄屏/录屏并排；配对区渐进披露。
-- 颜色全部用 Noctalia 主题角色 token，由主题解析、可被主题更改；冲突以 Noctalia 为准。
-- 后端 IPC 事件不变。
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
		return "surface_variant/0.2", "on_surface", noctalia.tr("panel.status_online")
	else
		return "surface_variant/0.2", "surface_variant", noctalia.tr("panel.status_offline")
	end
end

local function sectionLabel(rows, text)
	table.insert(rows, ui.label({
		text = text, fontSize = 11, fontWeight = "bold", color = "surface_variant",
	}))
end

-- ─── 设备卡片（截图样式：左轨 + 多行内容 + 右侧药丸/按钮）───
local function deviceCard(dev, rows)
	local isSel = (dev.id == selectedDevice)
	local isRenaming = (renameDev == dev.id)
	local isRunning = running[dev.id] ~= nil
	local pillFill, pillColor, statusText = statusPillOf(dev)

	if isRenaming then
		table.insert(rows, ui.row({
			key = "dev-" .. dev.id,
			fill = "primary/0.08", radius = 12, padding = 12, gap = 10, align = "center",
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

	-- 操作按钮：投屏中=停止 / 在线=投屏 / 离线=投屏(禁用)
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

	-- 重命名：仅选中卡显示（截图不显示常驻编辑按钮）
	local editBtn = ui.button({
		glyph = "edit", variant = "ghost", controlSize = "sm",
		tooltip = noctalia.tr("panel.rename"),
		visible = isSel,
		onClick = function()
			renameDev = dev.id
			renameVal = persistence.loadName(dev.id) or ""
			render()
		end,
	})

	table.insert(rows, ui.row({
		key = "dev-" .. dev.id,
		fill = isSel and "primary/0.08" or "surface",
		radius = 12, padding = 0, gap = 0, align = "stretch",
		border = isSel and "primary" or "surface_variant/0.5",
		borderWidth = 1,
		onClick = function()
			selectedDevice = dev.id
			params = persistence.loadParams(dev.id)
			render()
		end,
	}, {
		-- 左侧翠绿轨（选中）
		ui.box({ width = 3, radius = 2, fill = "primary", visible = isSel }),
		-- 内层内容行（自带 padding）
		ui.row({ padding = 12, gap = 10, align = "center", flexGrow = 1 }, {
			ui.column({ gap = 3, flexGrow = 1 }, {
				ui.row({ gap = 8, align = "center" }, {
					ui.glyph({ name = dev.transport == "wifi" and "wifi" or "usb", size = 16, color = "on_surface" }),
					ui.label({ text = dev.label, fontWeight = "bold", color = "on_surface" }),
				}),
				ui.label({
					text = dev.transport .. " · " .. dev.id,
					fontSize = 11, color = "surface_variant",
				}),
			}),
			-- 状态药丸
			ui.row({ fill = pillFill, radius = 8, paddingH = 8, paddingV = 3 }, {
				ui.label({ text = statusText, fontSize = 11, color = pillColor }),
			}),
			actionBtn,
			editBtn,
		}),
	}))
end

local function paramSlider(rows, labelKey, val, min, max, step, suffix, setter)
	table.insert(rows, ui.row({ gap = 8, align = "center" }, {
		ui.label({ text = noctalia.tr(labelKey), width = 72, color = "surface_variant" }),
		ui.slider({
			min = min, max = max, step = step, value = val,
			onChange = function(v)
				setter(tonumber(v))
				persistence.saveParams(selectedDevice, params)
				ipcRestartWithParams()
				render()
			end,
			flexGrow = 1,
		}),
		ui.label({ text = tostring(val) .. suffix, width = 48, color = "on_surface" }),
	}))
end

local function toggleRow(labelKey, checked, setter)
	return ui.row({ gap = 8, align = "center", flexGrow = 1 }, {
		ui.label({ text = noctalia.tr(labelKey), color = "on_surface" }),
		ui.toggle({
			checked = checked,
			onChange = function(v)
				setter(v == "true")
				persistence.saveParams(selectedDevice, params)
				ipcRestartWithParams()
				render()
			end,
			flexGrow = 1,
		}),
	})
end

function render()
	local rows = {}

	-- ─── 头部：标题 + 状态小结 ───
	local onlineN = #devices
	local runningN = countRunning()
	table.insert(rows, ui.row({ gap = 8, align = "center" }, {
		ui.label({ text = noctalia.tr("panel.title"), fontWeight = "bold" }),
		ui.spacer({ flexGrow = 1 }),
		ui.label({
			text = noctalia.tr("panel.header_summary", { online = onlineN, running = runningN }),
			fontSize = 11, color = "surface_variant",
		}),
	}))

	if #devices == 0 then
		table.insert(rows, ui.column({ gap = 12, align = "center", padding = 32 }, {
			ui.glyph({ name = "device-mobile", size = 40, color = "surface_variant" }),
			ui.label({ text = noctalia.tr("panel.no_device"), color = "surface_variant" }),
			ui.button({
				text = noctalia.tr("panel.empty_cta"), variant = "primary", glyph = "link",
				onClick = function() pairExpanded = true; render() end,
			}),
		}))
	else
		-- ─── 设备区 ───
		sectionLabel(rows, noctalia.tr("panel.section.devices"))
		for _, dev in ipairs(devices) do
			deviceCard(dev, rows)
		end

		-- ─── 参数区（仅选中设备）───
		if selectedDevice then
			local dev = (function()
				for _, d in ipairs(devices) do
					if d.id == selectedDevice then return d end
				end
				return nil
			end)()
			local devLabel = dev and dev.label or selectedDevice
			table.insert(rows, ui.separator({ thickness = 1, spacing = 4 }))
			-- 区段头带状态点（截图 "● 参数 · Mi 14"）
			table.insert(rows, ui.row({ gap = 6, align = "center" }, {
				ui.box({ width = 7, height = 7, radius = 4, fill = "primary" }),
				ui.label({
					text = noctalia.tr("panel.section.params") .. " · " .. devLabel,
					fontSize = 11, fontWeight = "bold", color = "surface_variant",
				}),
			}))

			paramSlider(rows, "panel.max_size", params.max_size or 1920,
				256, 4096, 64, "", function(v) params.max_size = v end)
			paramSlider(rows, "panel.bit_rate", params.bit_rate or 8,
				1, 100, 1, "M", function(v) params.bit_rate = v end)
			paramSlider(rows, "panel.max_fps", params.max_fps or 60,
				1, 120, 1, "", function(v) params.max_fps = v end)

			-- 熄屏 / 录屏 并排
			table.insert(rows, ui.row({ gap = 12 }, {
				toggleRow("panel.turn_screen_off", params.turn_screen_off or false,
					function(v) params.turn_screen_off = v end),
				toggleRow("panel.record", params.record or false,
					function(v) params.record = v end),
			}))

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
		end
	end

	-- ─── 配对区（渐进披露）───
	table.insert(rows, ui.separator({ thickness = 1, spacing = 4 }))
	if not pairExpanded then
		table.insert(rows, ui.button({
			text = noctalia.tr("panel.pair_add"), variant = "ghost", glyph = "plus",
			onClick = function() pairExpanded = true; render() end, flexGrow = 1,
		}))
	else
		sectionLabel(rows, noctalia.tr("panel.pair_title"))
		table.insert(rows, ui.input({
			key = "pair-addr",
			placeholder = noctalia.tr("panel.pair_addr_placeholder"),
			onChange = "onPairAddr",
			onSubmit = "onPairSubmit",
			flexGrow = 1,
		}))
		table.insert(rows, ui.input({
			key = "pair-code",
			placeholder = noctalia.tr("panel.pair_code_placeholder"),
			onChange = "onPairCode",
			onSubmit = "onPairSubmit",
			flexGrow = 1,
		}))
		table.insert(rows, ui.markdown({ text = noctalia.tr("panel.pair_hint") }))
		table.insert(rows, ui.button({
			text = noctalia.tr("panel.pair_btn"), variant = "secondary", glyph = "link",
			onClick = "onPair", flexGrow = 1,
		}))
	end

	panel.render(ui.scroll({ gap = 12, padding = 16 }, rows))
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
