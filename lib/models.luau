-- lib/models.luau
-- 设备显示名称管理：用户可自定义，fallback 到 adb 输出的原始型号。
local M = {}

-- 返回设备显示名称
-- model: adb devices -L 输出的 model: 字段（如 25091RP04C）
-- customName: 用户通过 panel 设置的名称（可选，nil 表示未设）
-- 优先级：customName > model > "Unknown"
function M.label(model, customName)
	if customName and customName ~= "" then
		return customName
	elseif model and model ~= "" then
		return model
	end
	return "Unknown"
end

return M
