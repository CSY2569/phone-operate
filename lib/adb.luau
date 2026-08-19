-- lib/adb.luau
-- adb 交互封装。所有命令走 noctalia.runAsync（数组形式，需 plugin_api 24）。
-- adb pair 需要 stdin，runAsync 不支持写 stdin，改用 shell 串形式（走 /bin/sh -c，支持管道）。
local M = {}

-- adb devices -L 输出示例：
--   cf56f01f               device usb:5-1 product:piano model:25091RP04C
--   192.168.1.3:5555       device product:piano
function M.listDevicesAsync(cb)
	noctalia.runAsync({ "adb", "devices", "-L" }, function(result)
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
	noctalia.runAsync({ "adb", "connect", address }, function(result)
		-- "connected to ..." 或 "already connected" 算成功
		local ok = result.exitCode == 0 and result.stdout:match("connected") ~= nil
		cb(ok, result.stdout)
	end)
end

-- adb pair IP:PORT，通过 shell 管道喂配对码
-- 配对码限定 6 位纯数字，避免 shell 注入；address 为 IP:端口，基本安全
function M.pairAsync(address, code, cb)
	local cmd = string.format("echo '%s' | adb pair %s", code, address)
	noctalia.runAsync(cmd, function(result)
		local ok = result.exitCode == 0 and result.stdout:match("successfully") ~= nil
		cb(ok, result.stdout)
	end)
end

-- adb disconnect <device_id>
function M.disconnect(device_id)
	noctalia.runAsync({ "adb", "disconnect", device_id })
end

-- adb -s <id> usb（切回 USB 模式）
function M.usbMode(device_id)
	noctalia.runAsync({ "adb", "-s", device_id, "usb" })
end

return M
