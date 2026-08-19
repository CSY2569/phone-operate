-- lib/adb.luau
-- adb 交互封装。所有命令走 noctalia.runAsync 字符串形式（/bin/sh -c）。
-- 数组形式需未发布的 plugin_api=24，故不用；用户输入经 shell.quote 转义。
local M = {}
local shell = require("./shell.luau")

-- adb devices -l 输出示例（注意是小写 -l；大写 -L 旧版 adb 不支持会报错）：
--   cf56f01f               device usb:5-1 product:piano model:25091RP04C transport_id:1
--   192.168.1.3:5555       device product:piano
function M.listDevicesAsync(cb)
	noctalia.runAsync("adb devices -l", function(result)
		local out = {}
		if result.exitCode == 0 then
			for line in result.stdout:gmatch("[^\n]+") do
				-- 跳过 "List of devices attached" 标题与空行
				if not line:match("^List of devices") and not line:match("^%s*$") then
					local serial, devState = line:match("^(%S+)%s+(%S+)")
					if serial and devState == "device" then
						local transport = line:match("usb:") and "usb" or "wifi"
						local model = line:match("model:(%S+)") or serial
						-- customName / label 由 service 层从 persistence 加载后合并
						table.insert(out, {
							id = serial,
							state = devState,
							transport = transport,
							model = model,
							online = true,
						})
					end
				end
			end
		end
		cb(out)
	end)
end

-- adb connect IP:PORT
function M.connectAsync(address, cb)
	noctalia.runAsync("adb connect " .. shell.quote(address), function(result)
		-- "connected to ..." 或 "already connected" 算成功
		local ok = result.exitCode == 0 and result.stdout:match("connected") ~= nil
		cb(ok, result.stdout)
	end)
end

-- adb pair IP:PORT，通过 shell 管道喂配对码
-- 配对码限定 6 位纯数字，避免注入；address 经 shell.quote 转义
function M.pairAsync(address, code, cb)
	local cmd = string.format("echo %s | adb pair %s",
		shell.quote(code), shell.quote(address))
	noctalia.runAsync(cmd, function(result)
		local ok = result.exitCode == 0 and result.stdout:match("successfully") ~= nil
		cb(ok, result.stdout)
	end)
end

-- adb disconnect <device_id>
function M.disconnect(device_id)
	noctalia.runAsync("adb disconnect " .. shell.quote(device_id))
end

-- adb -s <id> usb（切回 USB 模式）
function M.usbMode(device_id)
	noctalia.runAsync("adb -s " .. shell.quote(device_id) .. " usb")
end

return M
