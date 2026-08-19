-- service.luau
-- 后台 service：设备轮询 + 自动 connect + scrcpy 进程管理 + 状态发布。
-- 顶层代码在加载时运行一次；update() 周期执行；onIpc 接收 panel/widget/launcher 的请求。
local persistence = require("./lib/persistence.luau")
local adb = require("./lib/adb.luau")
local scrcpy = require("./lib/scrcpy.luau")
local state = require("./lib/state.luau")
local models = require("./lib/models.luau")
local shell = require("./lib/shell.luau")

local devices = {}     -- 当前设备列表（内存模型）
local running = {}     -- device_id -> true（已启动的 scrcpy 集合，PID 无法获取）
local lastNetState = nil
local netCheckCounter = 0

-- ─── 工具：运行状态仅变化时发布（避免每轮询触发 widget/panel 重渲染）───
local lastRunningJson = nil
local function publishRunning()
	local json = noctalia.json.encode(running)
	if json ~= lastRunningJson then
		lastRunningJson = json
		noctalia.state.set(state.KEY_RUNNING, running)
	end
end

-- ─── 工具：IPC payload 兼容 string/table ───
-- 参考文档未明确 onIpc payload 是否预解码，此处两者兼容。
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

-- ─── 工具：adb 输出与历史记录合并 ───
-- adb 输出 = 在线设备；历史里不在 adb 输出的标 online=false 灰显。
local function mergeWithHistory(adbDevices)
	local merged = {}
	local seen = {}

	for _, dev in ipairs(adbDevices) do
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

-- ─── 设备列表刷新（仅内容变化时发布，避免每轮询全量触发 panel 重渲染）───
local lastDevicesJson = nil
function refreshDevices()
	adb.listDevicesAsync(function(adbDevices)
		local merged = mergeWithHistory(adbDevices)
		-- 为每台设备生成 label：用户自定义名称 > 原始型号
		for _, dev in ipairs(merged) do
			local customName = persistence.loadName(dev.id)
			dev.label = models.label(dev.model, customName)
		end
		devices = merged
		local json = noctalia.json.encode(devices)
		if json ~= lastDevicesJson then
			lastDevicesJson = json
			noctalia.state.set(state.KEY_DEVICES, devices)
		end
	end)
end

-- ─── 网络检查：WiFi/以太网是否拿到 IP ───
local function checkNetworkAsync(cb)
	-- 字符串形式走 /bin/sh -c，管道生效；无需 sh -c 包裹
	noctalia.runAsync("ip -4 addr show | grep -q 'inet ' && echo ok || echo no", function(result)
		local ok = result.exitCode == 0 and result.stdout:match("ok") ~= nil
		cb(ok)
	end)
end

-- ─── 延迟重试 connect：最多 3 次，间隔 5s / 10s / 20s ───
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

-- ─── 自动 connect 入口 ───
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

-- ─── 网络监听：状态从断开 -> 就绪时重新触发自动 connect ───
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

-- ─── 录屏文件清理：超过最大保留数则删最旧的 ───
function cleanupRecordings()
	local maxFiles = noctalia.getConfig("record_max_files") or 10
	local dir = noctalia.pluginDataDir()
	-- 字符串形式走 /bin/sh -c，管道生效；dir 经 shell.quote 转义防路径含空格
	noctalia.runAsync(string.format(
		"ls -1t %s/rec_*.mp4 2>/dev/null | tail -n +%d | xargs -r rm -f",
		shell.quote(dir), maxFiles + 1
	), function(result)
		if result.exitCode ~= 0 and result.stderr ~= "" then
			noctalia.log("录屏清理异常: " .. result.stderr)
		end
	end)
end

-- ─── 清理 running 表中已退出的 scrcpy 记录（pgrep 校验）───
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
			if not alive then
				running[device_id] = nil
			end
			checked = checked + 1
			if checked >= #pending then
				publishRunning()
			end
		end)
	end
end

-- ─── 启动时：加载历史 + 自动 connect（带网络监听）───
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

-- ─── 周期更新：轮询 adb devices + 网络监听 + 僵尸进程清理 ───
function update()
	refreshDevices()
	-- 每 5 个轮询周期检查一次网络状态（约 15s，取决于 poll_interval_ms）
	netCheckCounter = netCheckCounter + 1
	if netCheckCounter >= 5 then
		monitorNetwork()
		netCheckCounter = 0
	end
	reapRunning()
end

-- 用户改设置时：不重启 service，只更新轮询间隔
function onConfigChanged()
	noctalia.setUpdateInterval(noctalia.getConfig("poll_interval_ms") or 3000)
end

-- ─── IPC 接口（panel/widget/launcher 通过 noctalia msg plugin ... 调用）───
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
		-- 用户在 panel 改了参数：杀掉旧进程，用新参数重启
		scrcpy.stop(p.device_id)
		local params = p.params or persistence.loadParams(p.device_id)
		persistence.saveParams(p.device_id, params)
		local dev = findDevice(p.device_id)
		if dev then
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
		-- 手动刷新设备列表（panel 头部「刷新」按钮）
		refreshDevices()
	elseif event == "stop_all" then
		-- 全部停止投屏（panel 头部「全部停止」按钮）
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
	end
end

-- 插件禁用/卸载/重载时：不杀 scrcpy（用户的投屏不应被打断）
function onExit(_signal, reason)
	if reason == "uninstall" then
		noctalia.notify("Phone Operate", noctalia.tr("notify.uninstalled"))
	end
end
