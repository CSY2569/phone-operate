-- lib/persistence.luau
-- 参数 / 历史设备 / 自定义名称的持久化，存到 noctalia.pluginDataDir()/data.json
local M = {}

local function dataFile()
	return noctalia.pluginDataDir() .. "/data.json"
end

local function loadAll()
	local raw = noctalia.readFile(dataFile())
	if raw then
		local t = noctalia.json.decode(raw)
		if t then return t end
	end
	return { devices = {}, params = {}, names = {} }
end

local function saveAll(data)
	noctalia.writeFile(dataFile(), noctalia.json.encode(data))
end

-- 历史设备：{ {id, label, transport}, ... }
function M.loadHistory()
	local data = loadAll()
	return data.devices or {}
end

function M.addHistory(address, label, transport)
	local data = loadAll()
	data.devices = data.devices or {}
	for _, d in ipairs(data.devices) do
		if d.id == address then return end
	end
	table.insert(data.devices, { id = address, label = label, transport = transport })
	saveAll(data)
end

function M.removeHistory(address)
	local data = loadAll()
	data.devices = data.devices or {}
	for i, d in ipairs(data.devices) do
		if d.id == address then
			table.remove(data.devices, i)
			break
		end
	end
	saveAll(data)
end

-- 每设备参数：{ ["192.168.1.3:5555"] = { max_size=1920, bit_rate=8, ... }, ... }
-- 未覆盖时 fallback 到插件级 settings 默认值
function M.loadParams(device_id)
	local data = loadAll()
	local fallback = {
		max_size = noctalia.getConfig("max_size"),
		bit_rate = noctalia.getConfig("bit_rate"),
		max_fps = noctalia.getConfig("max_fps"),
		turn_screen_off = noctalia.getConfig("turn_screen_off"),
		record = noctalia.getConfig("record"),
	}
	local saved = data.params and data.params[device_id]
	if saved then
		-- 合并：saved 覆盖 fallback，缺的字段用默认值补
		for k, v in pairs(fallback) do
			if saved[k] == nil then saved[k] = v end
		end
		return saved
	end
	return fallback
end

function M.saveParams(device_id, params)
	local data = loadAll()
	data.params = data.params or {}
	data.params[device_id] = params
	saveAll(data)
end

-- 每设备自定义名称：{ ["192.168.1.3:5555"] = "我的手机", ... }
function M.loadName(device_id)
	local data = loadAll()
	return data.names and data.names[device_id] or nil
end

function M.saveName(device_id, name)
	local data = loadAll()
	data.names = data.names or {}
	if name and name ~= "" then
		data.names[device_id] = name
	else
		data.names[device_id] = nil -- 清空则删 key
	end
	saveAll(data)
end

return M
