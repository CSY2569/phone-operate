-- widget.luau
-- bar widget：状态图标。绿 = 正在投屏（至少一台 scrcpy 运行中），灰 = 未投屏。
-- 注意语义是"是否正在投屏"而非"有无设备"，订阅 KEY_RUNNING。
local state = require("./lib/state.luau")
local ipc = require("./lib/ipc.luau")

local running = false

local function renderWidget()
	barWidget.setGlyph("device-mobile")
	if running then
		barWidget.setGlyphColor("green")
		barWidget.setTooltip(noctalia.tr("widget.tooltip.running"))
	else
		barWidget.setGlyphColor("surface_variant")
		barWidget.setTooltip(noctalia.tr("widget.tooltip.idle"))
	end
end

-- 订阅 service 发布的运行状态
noctalia.state.watch(state.KEY_RUNNING, function(run)
	-- run 是 { device_id = true } 表
	local any = false
	for _ in pairs(run) do any = true; break end
	running = any
	renderWidget()
end)

function update()
	renderWidget()
end

function onClick()
	noctalia.togglePanel("icefish/phone-operate:main")
end

function onRightClick()
	-- 未投屏时：用最近设备直接启动 scrcpy
	if not running then
		local devs = noctalia.state.get(state.KEY_DEVICES) or {}
		if #devs > 0 then
			ipc.send("start", { device_id = devs[1].id })
		end
	end
end
