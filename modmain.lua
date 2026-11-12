GLOBAL.setmetatable(env, {
    __index = function(t, k)
        return GLOBAL.rawget(GLOBAL, k)
    end
})

local need_init_client_config = true
local local_mode = not modinfo.folder_name:find("workshop%-") -- 本地测试模式
local client_modid = local_mode and "dst-ip-fix" or "workshop-3600067779" -- 客户端版模组ID
local try_num = 0

----------------------------------------------------------------首次连接缓存初始化--------------------------------------------------------------------------------------------------------------------------------

local DATA_FILE = "mod_config_data/ip-fix-setting.json"

local function Init_Client_Config(world)
    if not world then return end
    if _G.KnownModIndex:IsModEnabledAny(client_modid) then return end

    local shardstate = world.net and world.net.components.shardstate
    local session = shardstate and shardstate:GetMasterSessionId()
    if not session then return end

    local config = {}
    for _, kind in ipairs({ "ip", "port" }) do
        for i = 1, kind == "ip" and 3 or 9 do
            local source_key, target_key = "original_" .. kind .. "_" .. i, "fix_" .. kind .. "_" .. i
            config[source_key], config[target_key] = GetModConfigData(source_key), GetModConfigData(target_key)
        end
    end

    need_init_client_config = false

    TheSim:GetPersistentString(DATA_FILE, function(success, content)
        if TheWorld ~= world or not world:IsValid() then
            return
        end
        local data = { version = 2, profiles = {} }
        if success and type(content) == "string" and content ~= "" then
            local ok, saved = pcall(json.decode, content)
            if ok and type(saved) == "table" then
                if saved.version == 2 and type(saved.profiles) == "table" then
                    data = saved
                elseif saved.version and saved.version ~= 2 then
                    print("[强制纠正IP端口(服务端)] 缓存版本不兼容，跳过首次缓存初始化")
                    return
                end
            end
        end
        -- 只更新当前服务器；原始规则由客户端统一校验，不在服务端维护第二套纠正逻辑
        data.profiles[session] = { config = config }
        local encoded_data = json.encode(data)
        TheSim:SetPersistentString(DATA_FILE, encoded_data, false, function(success)
            if success then
                print("[强制纠正IP端口(服务端)] 首次连接缓存已保存，session：", session)
            else
                print("[强制纠正IP端口(服务端)] 首次连接缓存写入失败")
            end
        end)
    end)
end

----------------------------------------------------------------自动订阅和启用客户端模组--------------------------------------------------------------------------------------------------------------------------------

local function Auto_Enable_Mod()
    KnownModIndex:UpdateModInfo() -- 刷新模组列表
    if KnownModIndex:GetModInfo(client_modid) then
        if not KnownModIndex:IsModEnabled(client_modid) then
            print("[强制纠正IP端口(服务端)] 正在自动开启模组：强制纠正IP端口(客户端)")
            Init_Client_Config(TheWorld) -- 初始化客户端配置
            KnownModIndex:Enable(client_modid)
            KnownModIndex:Save()
        end
        return
    end

    -- 无模组的情况 --

    try_num = try_num + 1
    if try_num > 10 then
        print("[强制纠正IP端口(服务端)] 客户端模组尚未下载完成，请完成下载后启用")
        return
    end
    if local_mode then
        print("[强制纠正IP端口(服务端)] 未检测到本地版强制纠正IP端口模组，请手动安装并放在dst-ip-fix目录")
        return
    else
        TheSim:SubscribeToMod(client_modid)
    end

    -- 初始化客户端配置
    if need_init_client_config then
        Init_Client_Config(TheWorld)
    end

    TheGlobalInstance:DoTaskInTime(2, Auto_Enable_Mod)
end

-- 游戏初始化后检测是否安装/启用客户端模组
AddPrefabPostInit("world", function(inst)
    inst:DoTaskInTime(0, function()
        if TheNet:GetIsClient() then
            Auto_Enable_Mod()
        end
    end)
end)