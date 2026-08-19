-- widget.luau
-- bar widget（phone-connect 原版搬运）：设备图标 + 可选名称 + 电池状态，
-- 颜色按状态（充电 primary / 低电 error / 离线暗）。点击打开面板，右键开设置。

local function t(key)
	local table = noctalia.state.get("pc.trTable") or {}
	return table[key] or key
end

local function panelId()
	local mode = noctalia.getConfig("panel_placement")
	if mode == "floating" then
		return "icefish/phone-operate:main_floating"
	elseif mode == "widget" then
		return "icefish/phone-operate:main_widget"
	end
	return "icefish/phone-operate:main"
end

local function glyphFor(d)
	if not d or not (d.isPaired and d.isReachable) then return "phone-off" end
	local tp = d.type
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

-- adb 设备是否已被某个 KDE 设备覆盖（IP 匹配关联了同一 adbId）。
-- 被覆盖的 adb 设备不再显示，统一由 KDE 设备卡管理。
local function adbCoveredByKde(d, devices)
	if not d or d.source ~= "adb" then return false end
	for _, other in pairs(devices) do
		if other.source ~= "adb" and other.adbId and other.adbId == d.adbId then
			return true
		end
	end
	return false
end

local function selectedDevice()
	local devices = noctalia.state.get("pc.devices") or {}
	local order = noctalia.state.get("pc.order") or {}
	local sel = noctalia.state.get("pc.selected")
	local id = sel
	if not id or not devices[id] or adbCoveredByKde(devices[id], devices) then
		id = nil
		for _, oid in ipairs(order) do
			if not adbCoveredByKde(devices[oid], devices) then
				id = oid
				break
			end
		end
	end
	if id then return devices[id] end
	return nil
end

local function render()
	local backend = noctalia.state.get("pc.backend") or { available = false }
	local d = selectedDevice()
	local enableCharging = noctalia.getConfig("enable_charging_animation")
	local showDeviceName = noctalia.getConfig("show_device_name") == true
	local batteryDisplay = noctalia.getConfig("battery_display") or "icon_and_percent"

	local children
	if not backend.available and not d then
		children = {
			ui.glyph({ name = "phone-off", size = 14, color = "on_surface/0.4" }),
			ui.label({ text = t("status.no_devices"), fontSize = 10,
				color = "on_surface/0.5" }),
		}
	elseif not d then
		children = {
			ui.glyph({ name = "phone-off", size = 14, color = "on_surface/0.4" }),
			ui.label({ text = t("status.no_devices"), fontSize = 10,
				color = "on_surface/0.5" }),
		}
	elseif d.source == "adb" then
		-- adb 设备：usb/wifi 图标 + 名称（无电池）
		local glyphColor = d.isReachable and "on_surface" or "on_surface/0.4"
		local kids = {
			ui.glyph({ name = d.transport == "wifi" and "wifi" or "usb", size = 14, color = glyphColor }),
		}
		if showDeviceName then
			table.insert(kids, ui.label({ text = d.name, fontSize = 11, color = glyphColor }))
		end
		if not d.isReachable then
			table.insert(kids, ui.label({ text = t("status.offline"),
				fontSize = 10, color = "on_surface/0.5" }))
		end
		children = kids
	else
		local reachable = d.isPaired == true and d.isReachable == true
		local charge = d.batteryCharge
		local charging = d.batteryCharging == true
		local hasCharge = type(charge) == "number" and charge >= 0

		local glyphColor = "on_surface"
		if reachable and charging and enableCharging then
			glyphColor = "primary"
		elseif not reachable then
			glyphColor = "on_surface/0.4"
		end

		local kids = { ui.glyph({ name = glyphFor(d), size = 14, color = glyphColor }) }
		if showDeviceName then
			local aliasMap = noctalia.state.get("pc.aliasMap") or {}
			local name = aliasMap[d.id] or d.name or "Your-Phone"
			table.insert(kids, ui.label({ text = name, fontSize = 11, color = glyphColor }))
		end

		if reachable and hasCharge then
			local batColor = "on_surface"
			if charging then batColor = "primary"
			elseif charge <= 20 then batColor = "error" end

			if batteryDisplay == "icon_and_percent" or batteryDisplay == "icon" then
				table.insert(kids, ui.glyph({ name = batteryGlyph(charge, charging),
					size = 12, color = batColor }))
			end
			if batteryDisplay == "icon_and_percent" or batteryDisplay == "percent" then
				table.insert(kids, ui.label({
					text = tostring(charge) .. "%", fontSize = 11,
					fontWeight = "medium", color = batColor,
				}))
			end
		elseif not reachable and d.isPaired then
			table.insert(kids, ui.label({ text = t("status.offline"),
				fontSize = 10, color = "on_surface/0.5" }))
		end
		children = kids
	end

	local container = barWidget.isVertical() and ui.column or ui.row
	barWidget.render(container({ gap = 5, align = "center" }, children))
end

function update()
	noctalia.setUpdateInterval(2000)
	render()
end

function onClick()
	noctalia.togglePanel(panelId())
end

function onRightClick()
	noctalia.openSettings()
end

noctalia.state.watch("pc.devices", render)
noctalia.state.watch("pc.order", render)
noctalia.state.watch("pc.selected", render)
noctalia.state.watch("pc.backend", render)
noctalia.state.watch("pc.aliasMap", render)
noctalia.state.watch("pc.trTable", render)

render()