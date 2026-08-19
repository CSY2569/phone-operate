-- lib/kdeconnect.luau
-- KDE Connect 交互封装。全部命令走 noctalia.runAsync 字符串形式（/bin/sh -c），
-- 用户输入经 lib/shell.luau 的 shell.quote 转义。移植自 phone-connect 插件的 service。
local M = {}
local shell = require("./shell.luau")

local SVC = "org.kde.kdeconnect"
local DAEMON_PATH = "/modules/kdeconnect"
local DAEMON_IFACE = "org.kde.kdeconnect.daemon"
local DEV_IFACE = "org.kde.kdeconnect.device"
local PROPS_IFACE = "org.freedesktop.DBus.Properties"
local BATTERY_IFACE = "org.kde.kdeconnect.device.battery"
local MPRIS_IFACE = "org.kde.kdeconnect.device.mprisremote"

local function devicePath(id)
	return DAEMON_PATH .. "/devices/" .. id
end

-- ── gdbus 结果解析 ────────────────────────────────────────────────
local function parseGdbusValue(raw)
	if raw == nil then return nil end
	raw = raw:gsub("^%s+", ""):gsub("%s+$", "")
	local inner = raw:match("^%(<(.+)>%,?%)?$")
	if inner then
		if inner == "true" then return true end
		if inner == "false" then return false end
		local n = tonumber(inner)
		if n then return n end
		local s = inner:match("^'(.*)'$") or inner:match('^"(.*)"$')
		if s then return s end
		return inner
	end
	local bare = raw:match("^%((.-)%,?%)$")
	if bare == nil then bare = raw end
	bare = bare:gsub("%s+$", ""):gsub(",%s*$", "")
	if bare == "true" then return true end
	if bare == "false" then return false end
	local n = tonumber(bare)
	if n then return n end
	local s = bare:match("^'(.*)'$") or bare:match('^"(.*)"$')
	if s then return s end
	return bare
end

local function parseGdbusStringArray(raw)
	if raw == nil then return {} end
	local arr = raw:match("%[(.-)%]")
	if arr == nil then return {} end
	local out = {}
	for item in arr:gmatch("'([^']*)'") do
		table.insert(out, item)
	end
	return out
end

local function parseVariantInner(v)
	if v == "true" then return true end
	if v == "false" then return false end
	local n = tonumber(v)
	if n then return n end
	local s = v:match("^'(.*)'$") or v:match('^"(.*)"$')
	if s ~= nil then return s end
	if v:sub(1, 1) == "[" then
		local arr = {}
		for item in v:gmatch("'([^']*)'") do table.insert(arr, item) end
		for item in v:gmatch('"([^"]*)"') do table.insert(arr, item) end
		return arr
	end
	return v
end

-- 解析 gdbus Properties.GetAll 的 a{sv} 字典：({'key': <value>,},)
local function parseGdbusVariantDict(raw)
	local out = {}
	if raw == nil then return out end
	for key, vraw in raw:gmatch("'([^']+)'%s*:%s*(%b<>)") do
		out[key] = parseVariantInner(vraw:sub(2, -2))
	end
	return out
end

-- ── gdbus 命令构造 ────────────────────────────────────────────────
local function gdbusGetAll(devPath, iface)
	return table.concat({
		"gdbus call --session",
		"--dest", shell.quote(SVC),
		"--object-path", shell.quote(devPath),
		"--method", shell.quote(PROPS_IFACE .. ".GetAll"),
		shell.quote(iface),
	}, " ")
end

local function gdbusDeviceMethod(id, method, cb)
	noctalia.runAsync(
		"gdbus call --session --dest " .. SVC
			.. " --object-path " .. devicePath(id)
			.. " --method " .. DEV_IFACE .. "." .. method,
		function(res)
			if res and res.exitCode ~= 0 then
				noctalia.log("[phone-operate] kde " .. method .. " failed: " .. (res.stderr or ""))
			end
			if cb then cb(res) end
		end)
end

-- 调用设备子接口方法（sub 如 sftp/mprisremote/sms）
local function gdbusSubMethod(id, sub, method, extraArgs, cb)
	local path = devicePath(id) .. "/" .. sub
	local iface = "org.kde.kdeconnect.device." .. sub
	local cmd = "gdbus call --session --dest " .. SVC
		.. " --object-path " .. shell.quote(path)
		.. " --method " .. shell.quote(iface .. "." .. method)
	if extraArgs and extraArgs ~= "" then cmd = cmd .. " " .. extraArgs end
	noctalia.runAsync(cmd, function(res)
		if res and res.exitCode ~= 0 then
			noctalia.log("[phone-operate] kde " .. sub .. "." .. method .. " failed: " .. (res.stderr or ""))
		end
		if cb then cb(res) end
	end)
end

-- 子接口方法返回单个值并解析
local function gdbusSubMethodValue(id, sub, method, cb)
	gdbusSubMethod(id, sub, method, "", function(res)
		if not res or res.exitCode ~= 0 then cb(nil); return end
		cb(parseGdbusValue(res.stdout or ""))
	end)
end

local function runCli(args, cb)
	noctalia.runAsync("kdeconnect-cli " .. args, function(res)
		if res and res.exitCode ~= 0 then
			noctalia.log("[phone-operate] kdeconnect-cli failed: " .. (res.stderr or ""))
		end
		if cb then cb(res) end
	end)
end

-- ── 后端可用性 ───────────────────────────────────────────────────
function M.isAvailable(cb)
	noctalia.runAsync(
		"gdbus call --session --dest org.freedesktop.DBus "
			.. "--object-path /org/freedesktop/DBus "
			.. "--method org.freedesktop.DBus.NameHasOwner "
			.. shell.quote(SVC),
		function(res)
			local owned = false
			if res and res.exitCode == 0 then
				owned = parseGdbusValue(res.stdout or "") == true
			end
			cb(owned)
		end)
end

-- ── 设备发现 ─────────────────────────────────────────────────────
function M.listDevicesAsync(cb)
	noctalia.runAsync(
		"gdbus call --session --dest " .. SVC
			.. " --object-path " .. DAEMON_PATH
			.. " --method " .. DAEMON_IFACE .. ".devices false false",
		function(res)
			if not res or res.exitCode ~= 0 then cb({}); return end
			cb(parseGdbusStringArray(res.stdout or ""))
		end)
end

-- 设备基本属性：name / isReachable / isPaired / pairState
function M.deviceInfoAsync(id, cb)
	noctalia.runAsync(gdbusGetAll(devicePath(id), DEV_IFACE), function(res)
		if not res or res.exitCode ~= 0 then cb(nil); return end
		local p = parseGdbusVariantDict(res.stdout or "")
		cb({
			name = p.name,
			isReachable = p.isReachable,
			isPaired = p.isPaired,
			pairState = p.pairState,
		})
	end)
end

-- 电量：charge / isCharging
function M.batteryAsync(id, cb)
	noctalia.runAsync(gdbusGetAll(devicePath(id) .. "/battery", BATTERY_IFACE), function(res)
		if not res or res.exitCode ~= 0 then cb(nil); return end
		local p = parseGdbusVariantDict(res.stdout or "")
		cb({ charge = p.charge, isCharging = p.isCharging })
	end)
end

-- MPRIS 媒体信息
function M.mprisAsync(id, cb)
	noctalia.runAsync(gdbusGetAll(devicePath(id) .. "/mprisremote", MPRIS_IFACE), function(res)
		if not res or res.exitCode ~= 0 then cb(nil); return end
		local p = parseGdbusVariantDict(res.stdout or "")
		cb({
			isPlaying = p.isPlaying,
			title = p.title,
			artist = p.artist,
			album = p.album,
			volume = p.volume,
			length = p.length,
			position = p.position,
			canSeek = p.canSeek,
		})
	end)
end

-- ── 动作 ─────────────────────────────────────────────────────────
function M.ring(id, cb)
	runCli("--ring -d " .. shell.quote(id), cb)
end

function M.ping(id, msg, cb)
	if msg and msg ~= "" then
		runCli("--ping-msg " .. shell.quote(msg) .. " -d " .. shell.quote(id), cb)
	else
		runCli("--ping -d " .. shell.quote(id), cb)
	end
end

function M.sendSms(id, dest, text, cb)
	local args = "--send-sms " .. shell.quote(text or "")
		.. " --destination " .. shell.quote(dest or "")
		.. " -d " .. shell.quote(id)
	runCli(args, cb)
end

function M.sendClipboard(id, cb)
	runCli("--send-clipboard -d " .. shell.quote(id), cb)
end

-- 浏览：挂载 SFTP 并 xdg-open 挂载点
function M.browse(id, cb)
	local function tryOpen()
		gdbusSubMethodValue(id, "sftp", "mountPoint", function(mp)
			if not mp or mp == "" then
				if cb then cb(false, "no mount point") end
				return
			end
			noctalia.runAsync("xdg-open " .. shell.quote(mp))
			if cb then cb(true) end
		end)
	end
	gdbusSubMethodValue(id, "sftp", "isMounted", function(mounted)
		if mounted then
			tryOpen()
		else
			gdbusSubMethodValue(id, "sftp", "mountAndWait", function(ok)
				if ok then tryOpen() elseif cb then cb(false, "mount failed") end
			end)
		end
	end)
end

function M.pair(id, cb)
	gdbusDeviceMethod(id, "requestPairing", cb)
end

function M.acceptPairing(id, cb)
	gdbusDeviceMethod(id, "acceptPairing", cb)
end

function M.unpair(id, cb)
	gdbusDeviceMethod(id, "unpair", cb)
end

-- 媒体控制：action = Play|Pause|PlayPause|Next|Previous|Stop
function M.mediaAction(id, action, cb)
	gdbusSubMethod(id, "mprisremote", "sendAction", shell.quote(action or "PlayPause"), cb)
end

-- 设置播放位置（直接设 position 属性，seek 方法不可靠）
function M.mediaSeek(id, offset, cb)
	local path = devicePath(id) .. "/mprisremote"
	noctalia.runAsync(
		"gdbus call --session --dest " .. SVC
			.. " --object-path " .. shell.quote(path)
			.. " --method " .. shell.quote(PROPS_IFACE .. ".Set")
			.. " " .. MPRIS_IFACE .. " position "
			.. shell.quote("<int32 " .. tostring(offset) .. ">"),
		cb)
end

-- 设置音量
function M.mediaSetVolume(id, vol, cb)
	local path = devicePath(id) .. "/mprisremote"
	noctalia.runAsync(
		"gdbus call --session --dest " .. SVC
			.. " --object-path " .. shell.quote(path)
			.. " --method " .. shell.quote(PROPS_IFACE .. ".Set")
			.. " " .. shell.quote(MPRIS_IFACE) .. " volume "
			.. shell.quote("<int32 " .. tostring(vol) .. ">"),
		cb)
end

return M