-- launcher.luau
-- launcher_provider：启动器里输 scrcpy 搜设备，选中即启动。
local state = require("./lib/state.luau")
local ipc = require("./lib/ipc.luau")

function onQuery(text)
	local devs = noctalia.state.get(state.KEY_DEVICES) or {}
	local results = {}
	local lower = string.lower(text or "")
	for _, dev in ipairs(devs) do
		-- 只列 adb 设备（launcher 语义是选中即投屏，KDE 设备不能投屏）
		if dev.source == "adb" and (text == "" or string.find(string.lower(dev.label), lower, 1, true)) then
			local status = dev.online and noctalia.tr("panel.status_online") or noctalia.tr("panel.status_offline")
			table.insert(results, {
				id = dev.id,
				title = dev.label,
				subtitle = dev.transport .. " · " .. status,
				glyph = dev.transport == "wifi" and "wifi" or "usb",
			})
		end
	end
	if #results == 0 then
		launcher.setResults(text, {
			{ id = "none", title = noctalia.tr("panel.no_device"), glyph = "alert-triangle" },
		})
	else
		-- 必须回传 text 作为 query，晚到结果才能映射回查询
		launcher.setResults(text, results)
	end
end

function onActivate(id)
	if id == "none" then return end
	-- 选中即启动该设备的 scrcpy
	ipc.send("start", { device_id = id })
end
