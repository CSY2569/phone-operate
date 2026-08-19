-- service.luau
-- 后台 service：统一管理两来源设备 —— adb/scrcpy（投屏）与 KDE Connect（响铃/ping/媒体/短信）。
-- 顶层代码加载时运行一次；update() 周期执行；onIpc 接收 panel/widget/launcher 的请求。
local persistence = require("./lib/persistence.luau")
local adb = require("./lib/adb.luau")
local scrcpy = require("./lib/scrcpy.luau")
local kde = require("./lib/kdeconnect.luau")
local state = require("./lib/state.luau")
local models = require("./lib/models.luau")
local shell = require("./lib/shell.luau")

local devices = {}     -- 统一设备列表（adb + kde），source 区分来源
local adbDevices = {}  -- adb 来源设备
local kdeDevices = {}  -- KDE Connect 来源设备
local running = {}     -- device_id -> true（已启动的 scrcpy 集合，PID 无法获取）
local lastNetState = nil
local netCheckCounter = 0

-- ─── 工具：运行状态仅变化时发布 ───
local lastRunningJson = nil
local function publishRunning()
	local json = noctalia.json.encode(running)
	if json ~= lastRunningJson then
		lastRunningJson = json
		noctalia.state.set(state.KEY_RUNNING, running)
	end
end

-- ─── 工具：IPC payload 兼容 string/table ───
local function decodePayload(p)
	if type(p) == "string" then
		local t = noctalia.json.decode(p)
		return t or {}
	elseif type(p) == "table" then
		return p
	end
	return {}
end

-- ─── 工具：按 id 查设备 ───
local function findDevice(id)
	for _, dev in ipairs(devices) do
		if dev.id == id then return dev end
	end
	return nil
end

-- ─── 工具：去掉 kde 设备 id 的 "kde:" 前缀 ───
local function kdeRawId(device_id)
	if type(device_id) == "string" and device_id:sub(1, 4) == "kde:" then
		return device_id:sub(5)
	end
	return device_id
end

-- ─── 工具：adb 输出与历史记录合并 ───
local function mergeWithHistory(adbDevicesOut)
	local merged = {}
	local seen = {}
	for _, dev in ipairs(adbDevicesOut) do
		dev.online = true
		table.insert(merged, dev)
		seen[dev.id] = true
	end
	for _, h in ipairs(persistence.loadHistory()) do
		if not seen[h.id] then
			table.insert(merged, {
				id = h.id,
				state = "offline",
				transport = h.transport or "wifi",
				model = h.label or h.id,
				online = false,
			})
		end
	end
	return merged
end

-- ─── 设备合并：adb 与 KDE Connect 按设备合并（不按类型分列）───
-- 规则：adb 显示名 == kde 名（忽略大小写/空白）；或 adb、kde 各仅一台时兜底合并。
local function mergeDevices()
	local merged = {}
	local usedKde = {}

	local function norm(s)
		return string.lower(s or ""):gsub("%s+", "")
	end

	local nAdb = #adbDevices
	local nKde = #kdeDevices

	for _, ad in ipairs(adbDevices) do
		local matchIdx = nil
		if nAdb == 1 and nKde == 1 then
			matchIdx = 1 -- 单设备兜底
		else
			for i, kd in ipairs(kdeDevices) do
				if not usedKde[i] and ad.label and ad.label ~= "" and norm(kd.label) == norm(ad.label) then
					matchIdx = i
					break
				end
			end
		end

		local dev = {
			id = ad.id,
			adb_id = ad.id,
			source = "adb",
			label = ad.label,
			model = ad.model,
			transport = ad.transport,
			adb_online = ad.online,
			online = ad.online,
		}
		if matchIdx then
			local kd = kdeDevices[matchIdx]
			usedKde[matchIdx] = true
			dev.source = "both"
			dev.kde_id = kd.kdeid
			dev.isPaired = kd.isPaired
			dev.isReachable = kd.isReachable
			dev.kde_online = kd.online
			dev.batteryCharge = kd.batteryCharge
			dev.batteryCharging = kd.batteryCharging
			dev.media = kd.media
			dev.online = ad.online or kd.online
			if (not ad.label) or ad.label == "" then dev.label = kd.label end
		end
		table.insert(merged, dev)
	end

	for i, kd in ipairs(kdeDevices) do
		if not usedKde[i] then
			table.insert(merged, {
				id = "kde:" .. kd.kdeid,
				kde_id = kd.kdeid,
				source = "kde",
				label = kd.label,
				model = kd.label,
				transport = "kde",
				isPaired = kd.isPaired,
				isReachable = kd.isReachable,
				kde_online = kd.online,
				online = kd.online,
				batteryCharge = kd.batteryCharge,
				batteryCharging = kd.batteryCharging,
				media = kd.media,
			})
		end
	end

	return merged
end

-- ─── 统一设备列表发布（仅变化时，避免每轮询触发 panel 重渲染）───
local lastDevicesJson = nil
local function publishDevices()
	local merged = mergeDevices()
	devices = merged
	local json = noctalia.json.encode(merged)
	if json ~= lastDevicesJson then
		lastDevicesJson = json
		noctalia.state.set(state.KEY_DEVICES, merged)
	end
end

-- ─── adb 设备刷新 ───
function refreshAdbDevices()
	adb.listDevicesAsync(function(adbDevicesOut)
		adbDevices = mergeWithHistory(adbDevicesOut)
		for _, dev in ipairs(adbDevices) do
			dev.source = "adb"
			local customName = persistence.loadName(dev.id)
			dev.label = models.label(dev.model, customName)
		end
		publishDevices()
	end)
end

-- ─── KDE Connect 设备刷新 ───
local function kdeFind(rawId)
	for _, d in ipairs(kdeDevices) do
		if d.kdeid == rawId then return d end
	end
	return nil
end

local function fetchKdeExtras(rawId)
	kde.batteryAsync(rawId, function(b)
		if b then
			local rec = kdeFind(rawId)
			if rec then
				rec.batteryCharge = b.charge
				rec.batteryCharging = b.isCharging
				publishDevices()
			end
		end
	end)
	kde.mprisAsync(rawId, function(m)
		if m then
			local rec = kdeFind(rawId)
			if rec then
				rec.media = m
				publishDevices()
			end
		end
	end)
end

function refreshKdeDevices()
	kde.isAvailable(function(avail)
		if not avail then
			if #kdeDevices > 0 then kdeDevices = {}; publishDevices() end
			return
		end
		kde.listDevicesAsync(function(ids)
			if #ids == 0 then
				if #kdeDevices > 0 then kdeDevices = {}; publishDevices() end
				return
			end
			local list = {}
			local done = 0
			for _, rawId in ipairs(ids) do
				kde.deviceInfoAsync(rawId, function(info)
					local rec = {
						id = "kde:" .. rawId,
						kdeid = rawId,
						source = "kde",
						label = (info and info.name) or rawId,
						model = (info and info.name) or rawId,
						transport = "kde",
						isPaired = (info and info.isPaired) or false,
						isReachable = (info and info.isReachable) or false,
						online = (info and info.isReachable and info.isPaired) or false,
					}
					list[#list + 1] = rec
					done = done + 1
					if done >= #ids then
						table.sort(list, function(a, b) return a.kdeid < b.kdeid end)
						kdeDevices = list
						publishDevices()
						for _, d in ipairs(list) do
							if d.online then fetchKdeExtras(d.kdeid) end
						end
					end
				end)
			end
		end)
	end)
end

-- ─── 合并刷新入口（对外统一）───
function refreshDevices()
	refreshAdbDevices()
	refreshKdeDevices()
end

-- ─── 网络检查 ───
local function checkNetworkAsync(cb)
	noctalia.runAsync("ip -4 addr show | grep -q 'inet ' && echo ok || echo no", function(result)
		local ok = result.exitCode == 0 and result.stdout:match("ok") ~= nil
		cb(ok)
	end)
end

-- ─── 延迟重试 connect ───
local function retryConnect(device_id, label, attempt)
	attempt = attempt or 1
	if attempt > 3 then
		noctalia.notify("Phone Operate", noctalia.tr("notify.retry_exhausted", { name = label }))
		return
	end
	local delays = { [1] = 5, [2] = 10, [3] = 20 }
	noctalia.runAsync("sleep " .. tostring(delays[attempt]), function()
		adb.connectAsync(device_id, function(ok)
			if ok then
				refreshDevices()
				noctalia.log("重试连接成功: " .. device_id .. " (第 " .. attempt .. " 次)")
			else
				retryConnect(device_id, label, attempt + 1)
			end
		end)
	end)
end

local function autoConnect(entry)
	if entry.transport ~= "wifi" then return end
	adb.connectAsync(entry.id, function(ok)
		if ok then
			refreshDevices()
		else
			retryConnect(entry.id, entry.label or entry.id, 1)
		end
	end)
end

local function monitorNetwork()
	checkNetworkAsync(function(ok)
		if lastNetState == false and ok then
			noctalia.notify("Phone Operate", noctalia.tr("notify.network_recovered"))
			noctalia.log("网络恢复，重新尝试自动连接")
			for _, entry in ipairs(persistence.loadHistory()) do
				autoConnect(entry)
			end
		end
		lastNetState = ok
	end)
end

-- ─── 录屏文件清理 ───
function cleanupRecordings()
	local maxFiles = noctalia.getConfig("record_max_files") or 10
	local dir = noctalia.pluginDataDir()
	noctalia.runAsync(string.format(
		"ls -1t %s/rec_*.mp4 2>/dev/null | tail -n +%d | xargs -r rm -f",
		shell.quote(dir), maxFiles + 1
	), function(result)
		if result.exitCode ~= 0 and result.stderr ~= "" then
			noctalia.log("录屏清理异常: " .. result.stderr)
		end
	end)
end

-- ─── 清理 running 表中已退出的 scrcpy 记录 ───
local function reapRunning()
	local pending = {}
	for device_id, _ in pairs(running) do
		pending[#pending + 1] = device_id
	end
	if #pending == 0 then
		publishRunning()
		return
	end
	local checked = 0
	for _, device_id in ipairs(pending) do
		scrcpy.isRunning(device_id, function(alive)
			if not alive then running[device_id] = nil end
			checked = checked + 1
			if checked >= #pending then publishRunning() end
		end)
	end
end

-- ─── 启动：加载历史 + 自动 connect ───
local history = persistence.loadHistory()

checkNetworkAsync(function(netOk)
	if netOk then
		for _, entry in ipairs(history) do
			autoConnect(entry)
		end
	else
		noctalia.log("网络未就绪，等待网络恢复后自动连接")
	end
end)

noctalia.setUpdateInterval(noctalia.getConfig("poll_interval_ms") or 3000)
refreshDevices()

-- ─── 周期更新 ───
function update()
	refreshDevices()
	netCheckCounter = netCheckCounter + 1
	if netCheckCounter >= 5 then
		monitorNetwork()
		netCheckCounter = 0
	end
	reapRunning()
end

function onConfigChanged()
	noctalia.setUpdateInterval(noctalia.getConfig("poll_interval_ms") or 3000)
end

-- ─── IPC 接口 ───
function onIpc(event, payload)
	local p = decodePayload(payload)

	if event == "start" then
		local dev = findDevice(p.device_id)
		if not dev then return end
		local params = persistence.loadParams(p.device_id)
		scrcpy.start(dev, params)
		running[p.device_id] = true
		publishRunning()
		if params.record then
			cleanupRecordings()
		end
		noctalia.notify("Phone Operate", noctalia.tr("notify.started", { name = dev.label }))
	elseif event == "stop" then
		scrcpy.stop(p.device_id)
		running[p.device_id] = nil
		publishRunning()
		local dev = findDevice(p.device_id)
		noctalia.notify("Phone Operate", noctalia.tr("notify.stopped", { name = dev and dev.label or p.device_id }))
	elseif event == "restart_with_params" then
		local wasRunning = running[p.device_id] ~= nil
		if wasRunning then scrcpy.stop(p.device_id) end
		local params = p.params or persistence.loadParams(p.device_id)
		persistence.saveParams(p.device_id, params)
		local dev = findDevice(p.device_id)
		if dev and wasRunning then
			scrcpy.start(dev, params)
			running[p.device_id] = true
		end
		publishRunning()
	elseif event == "connect" then
		adb.connectAsync(p.address, function(ok)
			if ok then
				persistence.addHistory(p.address, p.label or p.address, "wifi")
			end
			refreshDevices()
		end)
	elseif event == "pair" then
		adb.pairAsync(p.address, p.code, function(ok)
			if ok then
				noctalia.notify("Phone Operate", noctalia.tr("notify.pair_success"))
			end
		end)
	elseif event == "disconnect" then
		adb.disconnect(p.device_id)
		running[p.device_id] = nil
		publishRunning()
		local dev = findDevice(p.device_id)
		noctalia.notify("Phone Operate", noctalia.tr("notify.disconnected", { name = dev and dev.label or p.device_id }))
		refreshDevices()
	elseif event == "refresh" then
		refreshDevices()
	elseif event == "stop_all" then
		for device_id, _ in pairs(running) do
			scrcpy.stop(device_id)
			local dev = findDevice(device_id)
			noctalia.notify("Phone Operate", noctalia.tr("notify.stopped", { name = dev and dev.label or device_id }))
		end
		running = {}
		publishRunning()
	elseif event == "usb_mode" then
		adb.usbMode(p.device_id)
		refreshDevices()
	elseif event == "rename" then
		persistence.saveName(p.device_id, p.name)
		refreshDevices()
	-- ── KDE Connect 操作 ──
	elseif event == "ring" then
		kde.ring(kdeRawId(p.device_id))
	elseif event == "ping" then
		kde.ping(kdeRawId(p.device_id), p.message)
	elseif event == "clipboard" then
		kde.sendClipboard(kdeRawId(p.device_id))
	elseif event == "share_text" then
		kde.shareText(kdeRawId(p.device_id), p.text)
	elseif event == "browse" then
		kde.browse(kdeRawId(p.device_id), function(ok, err)
			if not ok then
				noctalia.notifyError("Phone Operate", err or noctalia.tr("notify.browse_failed"))
			end
		end)
	elseif event == "sms_send" then
		kde.sendSms(kdeRawId(p.device_id), p.destination, p.text, function(res)
			if res and res.exitCode == 0 then
				noctalia.notify("Phone Operate", noctalia.tr("notify.sms_sent", { dest = p.destination or "" }))
			end
		end)
	elseif event == "kde_pair" then
		kde.pair(kdeRawId(p.device_id), function() refreshKdeDevices() end)
	elseif event == "kde_unpair" then
		kde.unpair(kdeRawId(p.device_id), function() refreshKdeDevices() end)
	elseif event == "media" then
		kde.mediaAction(kdeRawId(p.device_id), p.action, function()
			noctalia.runAsync("sleep 0.6", function() refreshKdeDevices() end)
		end)
	elseif event == "media_seek" then
		kde.mediaSeek(kdeRawId(p.device_id), tonumber(p.offset) or 0, function()
			noctalia.runAsync("sleep 0.3", function() refreshKdeDevices() end)
		end)
	elseif event == "media_set_volume" then
		kde.mediaSetVolume(kdeRawId(p.device_id), tonumber(p.volume) or 0, function()
			refreshKdeDevices()
		end)
	end
end

-- 插件禁用/卸载/重载时：不杀 scrcpy
function onExit(_signal, reason)
	if reason == "uninstall" then
		noctalia.notify("Phone Operate", noctalia.tr("notify.uninstalled"))
	end
end