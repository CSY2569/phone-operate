-- launcher.luau
-- launcher_provider：启动器里输 scrcpy 搜设备，选中即启动。
local state = require("./lib/state.luau")

function onQuery(text)
	local devs = noctalia.state.get(state.KEY_DEVICES) or {}
	local results = {}
	local lower = string.lower(text or "")
	for _, dev in ipairs(devs) do
		-- 简单包含匹配（设备列表通常不长）
		if text == "" or string.find(string.lower(dev.label), lower, 1, true) then
			local subtitle = dev.transport
			if dev.online then
				subtitle = subtitle .. " · online"
			else
				subtitle = subtitle .. " · offline"
			end
			table.insert(results, {
				id = dev.id,
				title = dev.label,
				subtitle = subtitle,
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
	noctalia.runAsync({
		"noctalia", "msg", "plugin", "icefish/phone-operate:core", "all",
		"start", noctalia.json.encode({ device_id = id }),
	})
end
