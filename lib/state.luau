-- lib/state.luau
-- entries 间不共享 Lua 内存，通过 noctalia.state 交换。统一 state key 常量。
local M = {}

-- 设备列表 key：service 发布，widget/panel/launcher 订阅
-- 值结构：{ {id="192.168.1.3:5555", label="Mi 14", transport="wifi", online=true, model="..."}, ... }
M.KEY_DEVICES = "devices"

-- 当前活动设备 id（最后操作的那台）
M.KEY_ACTIVE = "active_device"

-- scrcpy 运行状态：{ ["<device_id>"] = true, ... }
M.KEY_RUNNING = "running"

return M
