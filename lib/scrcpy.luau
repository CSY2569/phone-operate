-- lib/scrcpy.luau
-- scrcpy 命令组装 + 进程管理。
-- 设计：插件只是参数组装器 + 进程启动器，视频解码/渲染全在 scrcpy 自己的 SDL 窗口里。
local M = {}

-- 组装 scrcpy 命令（参数数组形式，安全传递用户输入）
function M.buildArgs(device, params)
	local args = { "scrcpy" }

	-- 指定设备
	table.insert(args, "-s")
	table.insert(args, device.id)

	-- 分辨率上限
	if params.max_size then
		table.insert(args, "--max-size")
		table.insert(args, tostring(params.max_size))
	end

	-- 码率（用户输入 Mbps，转为 "8M" 格式）
	if params.bit_rate then
		table.insert(args, "--bit-rate")
		table.insert(args, tostring(params.bit_rate) .. "M")
	end

	-- 帧率上限
	if params.max_fps then
		table.insert(args, "--max-fps")
		table.insert(args, tostring(params.max_fps))
	end

	-- 熄屏投屏
	if params.turn_screen_off then
		table.insert(args, "--turn-screen-off")
	end

	-- 录屏（文件名带时间戳，存到 pluginDataDir）
	if params.record then
		local dir = noctalia.pluginDataDir()
		local ts = os.date("%Y%m%d_%H%M%S")
		table.insert(args, "--record")
		table.insert(args, dir .. "/rec_" .. ts .. ".mp4")
	end

	return args
end

-- 启动 scrcpy（fire-and-forget，runAsync 不带 callback 不捕获输出）
-- 注意：runAsync 不返回 PID（已知限制，见开发文档 §11.2）。
-- 进程生命周期由 service 层用 running[device_id]=true 追踪"已启动"集合，
-- stop 靠 pkill 匹配命令行。本函数不返回有意义的 PID。
function M.start(device, params)
	local args = M.buildArgs(device, params)
	noctalia.runAsync(args)
	return nil
end

-- 停止指定设备的 scrcpy：pkill 精确匹配命令行里的 "-s <device_id>"
function M.stop(device_id)
	noctalia.runAsync({ "pkill", "-f", "scrcpy.*-s " .. device_id })
end

-- 检查指定设备的 scrcpy 是否仍在运行（pgrep）
function M.isRunning(device_id, cb)
	noctalia.runAsync({ "pgrep", "-f", "scrcpy.*-s " .. device_id }, function(result)
		cb(result.exitCode == 0)
	end)
end

return M
