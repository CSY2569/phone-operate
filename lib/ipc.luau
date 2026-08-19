-- lib/ipc.luau
-- 向 service 发 IPC：noctalia msg plugin <id>:core all <event> <json>。
-- 用 shell 字符串形式（runAsync 数组形式需未发布的 plugin_api=24）。
local M = {}
local shell = require("./shell.luau")

local PLUGIN_ID = "icefish/phone-operate"
local SERVICE_ENTRY = PLUGIN_ID .. ":core"

function M.send(event, payload)
	local json = noctalia.json.encode(payload)
	local cmd = string.format("noctalia msg plugin %s all %s %s",
		SERVICE_ENTRY, event, shell.quote(json))
	noctalia.runAsync(cmd)
end

return M
