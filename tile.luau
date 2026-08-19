-- tile.luau
-- 控制中心 tile（phone-connect 原版搬运）：连接数或选中设备电量。点击打开面板。

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

local function countReachable()
	local devices = noctalia.state.get("pc.devices") or {}
	local order = noctalia.state.get("pc.order") or {}
	local n = 0
	for _, id in ipairs(order) do
		local d = devices[id]
		if d and not adbCoveredByKde(d, devices)
			and d.isPaired and d.isReachable == true then n = n + 1 end
	end
	return n
end

local function render()
	local backend = noctalia.state.get("pc.backend") or { available = false }
	if not backend.available then
		shortcut.setIcon("phone-off")
		shortcut.setLabel(t("status.no_backend"))
		shortcut.setActive(false)
		shortcut.setEnabled(false)
		return
	end

	local n = countReachable()
	local d = selectedDevice()
	shortcut.setEnabled(true)

	if d and d.source ~= "adb" and d.isPaired and d.isReachable
		and type(d.batteryCharge) == "number" and d.batteryCharge >= 0 then
		shortcut.setIcon("device-mobile")
		shortcut.setLabel(tostring(d.batteryCharge) .. "%")
		shortcut.setActive(true)
	else
		shortcut.setIcon("device-mobile")
		shortcut.setLabel(n > 0 and (tostring(n) .. " " .. t("status.connected"))
			or t("status.no_devices"))
		shortcut.setActive(n > 0)
	end
end

function update()
	noctalia.setUpdateInterval(3000)
	render()
end

function onClick()
	noctalia.togglePanel(panelId())
end

noctalia.state.watch("pc.devices", render)
noctalia.state.watch("pc.order", render)
noctalia.state.watch("pc.selected", render)
noctalia.state.watch("pc.backend", render)
noctalia.state.watch("pc.trTable", render)

render()