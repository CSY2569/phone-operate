-- widget.luau
-- bar widget：状态图标。颜色用 Noctalia 主题角色 token（primary=投屏中强调色，surface_variant=空闲），
-- 由主题解析、可被主题更改。tooltip 带投屏设备计数。
local state = require("./lib/state.luau")
local ipc = require("./lib/ipc.luau")

local runningCount = 0

local function renderWidget()
	barWidget.setGlyph("device-mobile")
	if runningCount > 0 then
		barWidget.setGlyphColor("primary")
		barWidget.setTooltip(noctalia.tr("widget.tooltip.running_count", { count = runningCount }))
	else
		barWidget.setGlyphColor("surface_variant")
		barWidget.setTooltip(noctalia.tr("widget.tooltip.idle"))
	end
end

-- 订阅 service 发布的运行状态
noctalia.state.watch(state.KEY_RUNNING, function(run)
	runningCount = 0
	for _ in pairs(run or {}) do runningCount = runningCount + 1 end
	renderWidget()
end)

function update()
	renderWidget()
end

function onClick()
	noctalia.togglePanel("icefish/phone-operate:main")
end

function onRightClick()
	-- 未投屏时：用第一台在线 adb 设备直接启动 scrcpy
	if runningCount == 0 then
		local devs = noctalia.state.get(state.KEY_DEVICES) or {}
		for _, dev in ipairs(devs) do
			if dev.source == "adb" and dev.online then
				ipc.send("start", { device_id = dev.id })
				return
			end
		end
	end
end
