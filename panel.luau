-- panel.luau
-- 主力配置 UI（用完即关弹窗，declarative UI）。
-- 设备选择（含 inline 重命名）+ 参数配置（改参即重启）+ 启动/停止/断开/回 USB + 配对新设备。
local state = require("./lib/state.luau")
local persistence = require("./lib/persistence.luau")
local ipcMod = require("./lib/ipc.luau")

local devices = {}
local selectedDevice = nil  -- 当前选中的 device_id
local params = {}           -- 当前选中设备的参数
local renameDev = nil       -- 正在重命名的 device_id
local renameVal = ""        -- 重命名输入框当前值
local pairAddr = ""         -- 配对地址输入框当前值
local pairCode = ""         -- 配对码输入框当前值

-- ─── 工具：发 IPC 给 service（委托给 ipc 模块，走 shell 字符串形式）───
local function ipc(event, payload)
	ipcMod.send(event, payload)
end

local function ipcRestartWithParams()
	if not selectedDevice then return end
	ipc("restart_with_params", { device_id = selectedDevice, params = params })
end

-- ─── 订阅设备列表 ───
noctalia.state.watch(state.KEY_DEVICES, function(d)
	devices = d or {}
	if (not selectedDevice) and #devices > 0 then
		selectedDevice = devices[1].id
		params = persistence.loadParams(selectedDevice)
	end
	render()
end)

function onOpen()
	devices = noctalia.state.get(state.KEY_DEVICES) or {}
	if #devices > 0 then
		selectedDevice = selectedDevice or devices[1].id
		params = persistence.loadParams(selectedDevice)
	end
	render()
end

function render()
	local rows = {}

	-- ─── 设备选择区 ───
	for _, dev in ipairs(devices) do
		local isSel = (dev.id == selectedDevice)
		local isRenaming = (renameDev == dev.id)

		if isRenaming then
			-- 重命名模式：label 位置直接变成输入框，inline 编辑
			table.insert(rows, ui.row({
				key = "dev-" .. dev.id,
				gap = 8, align = "center",
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
		else
			-- 正常模式：显示 label，右键或点 edit 进入重命名
			table.insert(rows, ui.row({
				key = "dev-" .. dev.id,
				gap = 8, align = "center",
				onClick = function()
					selectedDevice = dev.id
					params = persistence.loadParams(dev.id)
					render()
				end,
				onRightClick = function()
					renameDev = dev.id
					renameVal = persistence.loadName(dev.id) or ""
					render()
				end,
			}, {
				ui.glyph({ name = dev.transport == "wifi" and "wifi" or "usb", size = 16 }),
				ui.label({ text = dev.label, flexGrow = 1 }),
				ui.button({
					glyph = "edit", variant = "ghost", controlSize = "sm",
					tooltip = noctalia.tr("panel.rename"),
					onClick = function()
						renameDev = dev.id
						renameVal = persistence.loadName(dev.id) or ""
						render()
					end,
				}),
				ui.box({ width = 12, height = 12, radius = 6,
					fill = dev.online and "green" or "surface_variant" }),
				isSel and ui.glyph({ name = "check", size = 16 }) or ui.spacer({}),
			}))
		end
	end

	if #devices == 0 then
		table.insert(rows, ui.label({
			text = noctalia.tr("panel.no_device"), color = "surface_variant",
		}))
	end

	-- ─── 参数区（仅当选中设备时显示）───
	if selectedDevice then
		table.insert(rows, ui.separator({ thickness = 1, spacing = 8 }))

		-- 分辨率
		table.insert(rows, ui.row({ gap = 8, align = "center" }, {
			ui.label({ text = noctalia.tr("panel.max_size"), width = 80 }),
			ui.slider({
				min = 256, max = 4096, step = 64,
				value = params.max_size or 1920,
				onChange = function(v)
					params.max_size = tonumber(v)
					persistence.saveParams(selectedDevice, params)
					ipcRestartWithParams()
					render()
				end,
				flexGrow = 1,
			}),
			ui.label({ text = tostring(params.max_size or 1920), width = 50 }),
		}))

		-- 码率
		table.insert(rows, ui.row({ gap = 8, align = "center" }, {
			ui.label({ text = noctalia.tr("panel.bit_rate"), width = 80 }),
			ui.slider({
				min = 1, max = 100, step = 1,
				value = params.bit_rate or 8,
				onChange = function(v)
					params.bit_rate = tonumber(v)
					persistence.saveParams(selectedDevice, params)
					ipcRestartWithParams()
					render()
				end,
				flexGrow = 1,
			}),
			ui.label({ text = tostring(params.bit_rate or 8), width = 50 }),
		}))

		-- 帧率
		table.insert(rows, ui.row({ gap = 8, align = "center" }, {
			ui.label({ text = noctalia.tr("panel.max_fps"), width = 80 }),
			ui.slider({
				min = 1, max = 120, step = 1,
				value = params.max_fps or 60,
				onChange = function(v)
					params.max_fps = tonumber(v)
					persistence.saveParams(selectedDevice, params)
					ipcRestartWithParams()
					render()
				end,
				flexGrow = 1,
			}),
			ui.label({ text = tostring(params.max_fps or 60), width = 50 }),
		}))

		-- 熄屏投屏
		table.insert(rows, ui.row({ gap = 8, align = "center" }, {
			ui.label({ text = noctalia.tr("panel.turn_screen_off"), width = 80 }),
			ui.toggle({
				checked = params.turn_screen_off or false,
				onChange = function(v)
					params.turn_screen_off = (v == "true")
					persistence.saveParams(selectedDevice, params)
					ipcRestartWithParams()
					render()
				end,
				flexGrow = 1,
			}),
		}))

		-- 录屏
		table.insert(rows, ui.row({ gap = 8, align = "center" }, {
			ui.label({ text = noctalia.tr("panel.record"), width = 80 }),
			ui.toggle({
				checked = params.record or false,
				onChange = function(v)
					params.record = (v == "true")
					persistence.saveParams(selectedDevice, params)
					ipcRestartWithParams()
					render()
				end,
				flexGrow = 1,
			}),
		}))

		table.insert(rows, ui.separator({ thickness = 1, spacing = 8 }))

		-- ─── 操作按钮 ───
		table.insert(rows, ui.row({ gap = 8 }, {
			ui.button({
				text = noctalia.tr("panel.start"), variant = "primary", glyph = "player-play",
				onClick = "onStart", flexGrow = 1,
			}),
			ui.button({
				text = noctalia.tr("panel.stop"), variant = "destructive", glyph = "player-stop",
				onClick = "onStop", flexGrow = 1,
			}),
		}))

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

	-- ─── 配对区（始终显示，新增无线设备用）───
	table.insert(rows, ui.separator({ thickness = 1, spacing = 8 }))
	table.insert(rows, ui.label({
		text = noctalia.tr("panel.pair_title"), fontWeight = "bold",
	}))
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
	table.insert(rows, ui.button({
		text = noctalia.tr("panel.pair_btn"), variant = "secondary", glyph = "link",
		onClick = "onPair", flexGrow = 1,
	}))

	panel.render(ui.scroll({ gap = 10, padding = 16 }, rows))
end

-- ─── 回调 ───
function onStart()
	if not selectedDevice then return end
	ipc("start", { device_id = selectedDevice })
	panel.close()
end

function onStop()
	if not selectedDevice then return end
	ipc("stop", { device_id = selectedDevice })
end

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
		panel.close()
	end
end

-- 回车快捷：任一输入框回车即尝试配对
function onPairSubmit()
	onPair()
end

-- input 值变化时实时捕获（uncontrolled input，需自己存值）
function onPairAddr(v) pairAddr = v end
function onPairCode(v) pairCode = v end

function onRenameSubmit()
	if renameDev then
		ipc("rename", { device_id = renameDev, name = renameVal })
		renameDev = nil
		renameVal = ""
		-- 刷新由 state watch 自动触发 render
	end
end

function onRenameInput(v) renameVal = v end
