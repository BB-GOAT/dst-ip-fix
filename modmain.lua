GLOBAL.setmetatable(env, {
    __index = function(t, k)
        return GLOBAL.rawget(GLOBAL, k)
    end
})

----------------------------------------------------------------参数转发与旧回调隔离--------------------------------------------------------------------------------

-- 保留参数中间的 nil，转发原版函数时不丢失密码、netid 或额外参数。
local function PackArgs(...)
    return { n = select("#", ...), ... }
end

local function WrapCallbackObject(object, overrides)
    return setmetatable({}, {
        __index = function(_, key)
            if overrides[key] then
                return overrides[key]
            end
            local value = object[key]
            if type(value) == "function" then
                return function(_, ...)
                    return value(object, ...)
                end
            end
            return value
        end
    })
end

-- 临时环境只用于绑定原版新建的闭包，原函数环境在调用后恢复。
local function CallWithCallbackContext(fn, overrides, ...)
    local old_env = getfenv(fn)
    setfenv(fn, setmetatable(overrides, { __index = old_env }))
    local result = PackArgs(pcall(fn, ...))
    setfenv(fn, old_env)
    if not result[1] then
        error(result[2], 0)
    end
    return unpack(result, 2, result.n)
end

----------------------------------------------------------------日志与纠正规则--------------------------------------------------------------------------------

local DATA_FILE = "mod_config_data/ip-fix-setting.json"

local local_mode = not modinfo.folder_name:find("workshop%-") -- 本地测试模式
local server_modid = local_mode and 'dst-ip-fix-server' or "workshop-3487026153"
local MIGRATION_TOKEN_KEY = "dst_ip_fix_token"
local DEBUG_print = GetModConfigData("DEBUG_print") and function(...)
    print("[强制纠正IP端口]", ...)
end or function(...) end
local Toast = function(message, ...)
    if rawget(_G, "BBGOAT_utils") then
        _G.BBGOAT_utils.Toast(message, ...)
    else
        print(message)
    end
end

print("[强制纠正IP端口] 客户端已加载，调试日志：", GetModConfigData("DEBUG_print") and "开启" or "关闭")
DEBUG_print("运行模式：", local_mode and "本地模组" or "创意工坊", "服务端模组ID：", server_modid)

local function TrimString(value)
    if type(value) ~= "string" then
        return ""
    end
    return value:match("^%s*(.-)%s*$")
end

local function GetSession(value)
    if type(value) == "string" and value:find("%S") then
        return value
    end
end

local function NormalizePort(value)
    local number = tonumber(value)
    if number and number == math.floor(number) and number >= 1 and number <= 65535 then
        return number
    end
end

local function NormalizeHost(value)
    value = TrimString(value)
    if value ~= "" and not value:find("[%s/%c]") then
        return value
    end
end

local function IsPrivateIP(ip)
    ip = TrimString(ip):lower()
    if ip == "localhost" or ip == "::1" then
        return true
    end
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if not a or not b or not c or not d or a > 255 or b > 255 or c > 255 or d > 255 then
        return false
    end
    if a == 10 or a == 127 then
        return true
    end
    if a == 172 and b >= 16 and b <= 31 then
        return true
    end
    if a == 192 and b == 168 then
        return true
    end
    if a == 169 and b == 254 then
        return true
    end
    return false
end

-- 空白规则表示关闭；半条规则或非法端口会拒绝整次更新，避免部分新旧配置混合。
local function NormalizeConfig(raw)
    if type(raw) ~= "table" then
        DEBUG_print("纠正规则无效：配置不是表")
        return nil
    end
    local config = {}
    for _, kind in ipairs({ "ip", "port" }) do
        for i = 1, kind == "ip" and 3 or 9 do
            local source_key, target_key = "original_" .. kind .. "_" .. i, "fix_" .. kind .. "_" .. i
            local source, target = raw[source_key], raw[target_key]
            local source_empty = not source or TrimString(tostring(source)) == ""
            local target_empty = not target or TrimString(tostring(target)) == ""
            if source_empty ~= target_empty then
                DEBUG_print("纠正规则不完整：", source_key, target_key)
                return nil
            end
            if not source_empty then
                if kind == "ip" then
                    source = NormalizeHost(source)
                    target = NormalizeHost(target)
                else
                    source = NormalizePort(source)
                    target = NormalizePort(target)
                end
                if not source or not target then
                    DEBUG_print("纠正规则值无效：", source_key, target_key)
                    return nil
                end
                config[source_key], config[target_key] = source, target
            end
        end
    end
    return config
end

local function fix_ip_port(config, ip, port)
    if not config then
        return ip, port, false
    end
    if IsPrivateIP(ip) then
        DEBUG_print("目标为内网或本地地址，跳过纠正：", ip, port)
        return ip, port, false
    end
    local fixed_ip, fixed_port = ip, port
    -- 每组只匹配原始输入一次，域名也可以显式匹配，禁止链式重复替换。
    for i = 1, 3 do
        local source = config["original_ip_" .. i]
        if source and (source == ip or source == "0.0.0.0") then
            fixed_ip = config["fix_ip_" .. i]
            break
        end
    end
    for i = 1, 9 do
        if config["original_port_" .. i] == NormalizePort(port) and config["original_port_" .. i] then
            fixed_port = config["fix_port_" .. i]
            break
        end
    end
    local changed = fixed_ip ~= ip or NormalizePort(fixed_port) ~= NormalizePort(port)
    return fixed_ip, fixed_port, changed
end

----------------------------------------------------------------读写文件--------------------------------------------------------------------------------

local RW_Data = {}
local cached_data = { version = 2, profiles = {} }
local data_loaded, data_loading = false, false
local load_callbacks, save_callbacks = {}, {}
local data_saving = false
local current_connection -- 本次连接对象；旧回调必须与它相同才允许继续。
local active_config -- 当前服务器已经下发的有效规则，不等同于历史缓存。
local pending_migration_context -- 旧实例准备交给下一实例的迁移数据。
local startup_migration_context -- 新实例参数携带的一次性迁移数据。

-- 每次合并已排队的保存请求；写入期间新增的请求留到下一次，文件不保存密码或票据。
local function ProcessSaveQueue()
    if not data_loaded or data_saving or #save_callbacks == 0 then
        return
    end
    data_saving = true
    local callbacks = save_callbacks
    save_callbacks = {}
    local encoded = json.encode(cached_data)
    TheSim:SetPersistentString(DATA_FILE, encoded, false, function(success)
        if success then
            DEBUG_print("缓存保存成功，本次合并保存次数：", #callbacks)
        else
            Toast("[强制纠正IP端口] 缓存保存失败，本次修改未写入磁盘，下次启动可能仍使用旧缓存", 8, "error")
        end
        for _, callback in ipairs(callbacks) do
            callback(success)
        end
        data_saving = false
        ProcessSaveQueue()
    end)
end

function RW_Data:SaveData(callback)
    save_callbacks[#save_callbacks + 1] = callback or function() end
    ProcessSaveQueue()
end

function RW_Data:LoadData(callback)
    if data_loaded then
        callback()
        return
    end
    load_callbacks[#load_callbacks + 1] = callback
    if data_loading then
        return
    end
    data_loading = true
    TheSim:GetPersistentString(DATA_FILE, function(success, content)
        if success and type(content) == "string" and content ~= "" then
            local ok, data = pcall(json.decode, content)
            if ok and type(data) == "table" and data.version == 2 and type(data.profiles) == "table" then
                -- 仅恢复服务器规则，旧版磁盘迁移记录不再读取或传递。
                cached_data = { version = 2, profiles = {} }
                local profile_count = 0
                for session, profile in pairs(data.profiles) do
                    local config = type(profile) == "table" and NormalizeConfig(profile.config)
                    if GetSession(session) and config then
                        cached_data.profiles[session] = { config = config, suspect = profile.suspect == true or nil }
                        profile_count = profile_count + 1
                    else
                        DEBUG_print("忽略无效的服务器缓存记录")
                    end
                end
                DEBUG_print("缓存读取完成，有效服务器记录数：", profile_count)
            else
                DEBUG_print("旧版或损坏的缓存不用于连接；成功连接后重新学习")
            end
        else
            DEBUG_print("缓存不存在、为空或读取失败，成功连接后重新学习")
        end
        data_loaded, data_loading = true, false
        local waiters = load_callbacks
        load_callbacks = {}
        for _, fn in ipairs(waiters) do
            fn()
        end
        ProcessSaveQueue()
    end)
end

----------------------------------------------------------------当前连接与有效配置--------------------------------------------------------------------------------

local function ClearConnection()
    current_connection, active_config = nil, nil
    pending_migration_context, startup_migration_context = nil, nil
end

local function BeginConnection(listing)
    ClearConnection()
    current_connection = {
        session = listing and GetSession(listing.session),
        ip = listing and listing.ip,
        port = listing and listing.port,
    }
    return current_connection
end

local function ReceiveConfig(connection, raw, has_mod)
    if not connection or current_connection ~= connection then
        DEBUG_print("忽略已失效连接的纠正规则")
        return
    end
    -- 本次服务器已作出配置响应，结束对历史规则的临时借用。
    connection.cached_config = nil
    connection.handshake = true
    connection.awaiting_listing = nil
    local config
    if has_mod then
        config = NormalizeConfig(raw)
        if not config then
            Toast("[强制纠正IP端口] 服务器纠正配置无效，本次更新未应用，请联系服主检查配置", 8, "warning")
            return
        end
    end
    active_config = config
    if config then
        local ip_rule_count, port_rule_count = 0, 0
        for i = 1, 3 do
            if config["original_ip_" .. i] then
                ip_rule_count = ip_rule_count + 1
            end
        end
        for i = 1, 9 do
            if config["original_port_" .. i] then
                port_rule_count = port_rule_count + 1
            end
        end
        DEBUG_print("当前服务器纠正规则已生效，IP规则数：", ip_rule_count, "端口规则数：", port_rule_count)
        if not connection.session then
            DEBUG_print("本次连接没有列表session，仅保留当前规则用于迁移，不写入服务器缓存")
        end
    else
        DEBUG_print("服务器完整配置未包含目标服务端模组，清理本次规则；预期模组ID：", server_modid)
    end
    if not connection.session then
        return
    end
    RW_Data:LoadData(function()
        if current_connection == connection then
            cached_data.profiles[connection.session] = config and { config = config } or nil
            if config then
                DEBUG_print("按本次列表session更新服务器缓存")
            end
            RW_Data:SaveData()
        end
    end)
end

----------------------------------------------------------------恢复迁移前的启动数据--------------------------------------------------------------------------------

-- 实例参数由原版整表序列化，配置快照可以同步恢复，不依赖磁盘回调或再次 StartClient。
local settings = Settings or {}
local startup_context = settings.dst_ip_fix_context
settings.dst_ip_fix_context = nil
if type(startup_context) == "table" and startup_context.token == settings[MIGRATION_TOKEN_KEY]
    and startup_context.token and startup_context.reset_action == settings.reset_action then
    if settings.reset_action == RESET_ACTION.LOAD_FILE and startup_context.save_name == settings.save_name then
        active_config = NormalizeConfig(startup_context.config)
        current_connection = { session = active_config and GetSession(startup_context.session) or nil, handshake = true }
        settings[MIGRATION_TOKEN_KEY] = nil
        DEBUG_print("地图加载实例恢复当前规则：", active_config and "成功" or "规则无效")
    elseif settings.reset_action == RESET_ACTION.JOIN_SERVER and startup_context.ip == settings.serverIp
        and NormalizePort(startup_context.port) == NormalizePort(settings.serverPort) then
        startup_migration_context = startup_context
        DEBUG_print("启动参数包含本次入服交接数据，等待 StartClient 续接")
    end
end

----------------------------------------------------------------连接入口与缓存失效回退--------------------------------------------------------------------------------

local oldStartClient = NetworkProxy.StartClient
local oldJoinServerResponse = NetworkProxy.JoinServerResponse
local oldDisconnect = NetworkProxy.Disconnect
local TryOriginalServer -- StartClient 同步失败时也需要使用原始地址回退。
local calling_original_network = false
local function CallOriginalNetwork(fn, ...)
    local previous = calling_original_network
    calling_original_network = true
    local result = PackArgs(pcall(fn, ...))
    calling_original_network = previous
    if not result[1] then
        error(result[2], 0)
    end
    return unpack(result, 2, result.n)
end

-- 普通 StartClient（包括 c_connect）永不查询历史缓存。
NetworkProxy.StartClient = function(self, ip, port, id, password, netid, ...)
    if calling_original_network then
        return oldStartClient(self, ip, port, id, password, netid, ...)
    end
    -- 快速加载模组可能跳过实例重建；在 BeginConnection 清理前消费本次迁移目标。
    local context = pending_migration_context or startup_migration_context
    local restoring = context and context.ip == ip and NormalizePort(context.port) == NormalizePort(port)
    startup_migration_context = nil
    if Settings then
        Settings[MIGRATION_TOKEN_KEY] = nil
    end
    local connection = BeginConnection({ ip = ip, port = port })
    connection.route = "direct"
    connection.awaiting_listing = true
    if restoring then
        active_config = context.config and NormalizeConfig(context.config) or nil
        connection.session = GetSession(context.session)
        connection.cached_config = context.cached_config
        connection.route = "migration"
        connection.migration = true
        if context.original_ip and context.original_port then
            connection.ip, connection.port = context.original_ip, context.original_port
            -- 仅内存保留原版 StartClient 参数，包括迁移票据、netid 和中间的 nil。
            connection.start_args = PackArgs(id, password, netid, ...)
            -- 在目标实例真正发起连接时提示，避免迁移重建实例立即清掉提示。
            Toast(string.format("[强制纠正IP端口] 正在纠正分片IP端口并连接：\n%s:%s → %s:%s",
                connection.ip, tostring(connection.port), ip, tostring(port)), 20, "info")
        end
        DEBUG_print("StartClient续接本次迁移，恢复有效配置：", active_config and "成功" or "尚未下发", "目标：", ip, port)
    else
        DEBUG_print("StartClient普通直连，原样连接，不应用历史缓存：", ip, port)
    end
    local started = oldStartClient(self, ip, port, id, password, netid, ...)
    if restoring and not started then
        if TryOriginalServer(connection) then
            -- 已安排原始目标重试，调用方不应再按启动失败退出迁移。
            return true
        end
        OnNetworkDisconnect("ID_DST_USER_CONNECTION_FAILED", true)
    end
    return started
end

local join_context
local joining_from_list = false
local oldJoinServer = JoinServer

local function BindJoinServerResponse(connection)
    return function(_, ...)
        if current_connection ~= connection then
            return false
        end
        join_context = connection
        return TheNet:JoinServerResponse(...)
    end
end

local function BeginListConnection(listing)
    if current_connection and current_connection.awaiting_listing then
        -- 玩家改选另一台服务器时，取消尚未完成的原生直连事务。
        CallOriginalNetwork(oldJoinServerResponse, TheNet, true)
    end
    return BeginConnection(listing)
end

GLOBAL.JoinServer = function(listing, ...)
    local connection = current_connection
    if not joining_from_list and connection and connection.route == "fallback_pending" then
        DEBUG_print("正在回退，忽略旧直连的迟到ping回调")
        CallOriginalNetwork(oldJoinServerResponse, TheNet, true)
        return false
    end
    if not joining_from_list and connection and connection.awaiting_listing then
        -- StartClient 收到 ping 后会由原生回调这里；这是同次连接，不能再查缓存或重开连接。
        DEBUG_print("收到原生ping的服务器条目，继续当前连接，不再次纠正，路线：", connection.route,
            "响应地址：", listing and listing.ip, listing and listing.port)
    else
        DEBUG_print("从服务器列表发起加入，目标：", listing and listing.ip, listing and listing.port,
            "session：", listing and GetSession(listing.session) or "缺失")
        connection = BeginListConnection(listing)
    end
    -- 原版密码框/警告框的回调同样绑定本次意图，迟到的 A 回调不能消费 B 的上下文。
    return CallWithCallbackContext(oldJoinServer, {
        ShowConnectingToGamePopup = function()
            if current_connection == connection then
                return ShowConnectingToGamePopup()
            end
        end,
        TheFrontEnd = WrapCallbackObject(TheFrontEnd, {
            PopScreen = function(_, ...)
                if current_connection == connection then
                    return TheFrontEnd:PopScreen(...)
                end
            end,
            PushScreen = function(_, ...)
                if current_connection == connection then
                    return TheFrontEnd:PushScreen(...)
                end
            end,
            GetActiveScreen = function(_)
                if current_connection == connection then
                    return TheFrontEnd:GetActiveScreen()
                end
            end,
        }),
        TheNet = WrapCallbackObject(TheNet, {
            JoinServerResponse = BindJoinServerResponse(connection),
        }),
    }, listing, ...)
end

-- 真正的列表按钮提供明确的新连接意图，即使另一条直连正在等待 ping，也必须重新选服。
AddClassPostConstruct("screens/redux/serverlistingscreen", function(self)
    local old_Join = self.Join
    self.Join = function(self, ...)
        return CallWithCallbackContext(old_Join, {
            JoinServer = function(...)
                local previous = joining_from_list
                joining_from_list = true
                local result = PackArgs(pcall(GLOBAL.JoinServer, ...))
                joining_from_list = previous
                if not result[1] then
                    error(result[2], 0)
                end
                return unpack(result, 2, result.n)
            end,
        }, self, ...)
    end
end)

AddClassPostConstruct("screens/redux/quickjoinscreen", function(self)
    local old_JoinGame = self.JoinGame
    self.JoinGame = function(self, ...)
        local connection = BeginListConnection()
        return CallWithCallbackContext(old_JoinGame, {
            TheNet = WrapCallbackObject(TheNet, {
                GetServerListingFromActualIndex = function(_, index)
                    local listing = TheNet:GetServerListingFromActualIndex(index)
                    if current_connection == connection and listing then
                        connection.session, connection.ip, connection.port = GetSession(listing.session), listing.ip, listing.port
                        DEBUG_print("快速加入目标：", listing.ip, listing.port, "session：", connection.session or "缺失")
                    end
                    return listing
                end,
                JoinServerResponse = BindJoinServerResponse(connection),
            }),
        }, self, ...)
    end
end)

local function JoinOriginalServer(connection)
    if current_connection ~= connection then
        return false
    end
    connection.route = "original"
    DEBUG_print("调用原版列表入口，目标：", connection.ip, connection.port)
    local join_args = connection.join_args
    return CallOriginalNetwork(oldJoinServerResponse, unpack(join_args, 1, join_args.n))
end

TryOriginalServer = function(connection)
    if current_connection ~= connection or connection.handshake or not connection.start_args
        or (connection.route ~= "cached" and connection.route ~= "migration") then
        return false
    end
    if not NormalizeHost(connection.ip) or not NormalizePort(connection.port) then
        DEBUG_print("缺少有效的原始IP或端口，无法自动回退")
        return false
    end
    local profile = connection.route == "cached" and connection.session and cached_data.profiles[connection.session]
    connection.route = "fallback_pending"
    connection.awaiting_listing = nil
    if profile then
        profile.suspect = true
        RW_Data:SaveData()
    end
    -- 先取消纠正连接；大厅复用本次原版加入参数，迁移沿用原始端点和票据。
    CallOriginalNetwork(oldJoinServerResponse, TheNet, true)
    CallOriginalNetwork(oldDisconnect, TheNet, false)
    TheGlobalInstance:DoTaskInTime(0, function()
        if current_connection ~= connection then
            return
        end
        local next_current = {
            session = connection.session,
            ip = connection.ip,
            port = connection.port,
            route = "original",
            awaiting_listing = true,
            migration = connection.migration,
            start_args = connection.start_args,
            join_args = connection.join_args,
            cached_config = connection.cached_config,
        }
        current_connection = next_current
        local started
        if next_current.join_args then
            Toast("[强制纠正IP端口] 纠正地址连接失败，正在回退原版大厅连接", 8, "warning")
            started = JoinOriginalServer(next_current)
        else
            Toast(string.format("[强制纠正IP端口] 纠正地址连接失败，正在回退分片原始地址：\n%s:%s",
                next_current.ip, tostring(next_current.port)), 20, "warning")
            started = CallOriginalNetwork(oldStartClient, TheNet, next_current.ip, next_current.port,
                unpack(next_current.start_args, 1, next_current.start_args.n))
        end
        if not started then
            OnNetworkDisconnect("ID_DST_USER_CONNECTION_FAILED", next_current.migration == true)
        end
    end)
    return true
end

NetworkProxy.JoinServerResponse = function(self, cancelled, ...)
    if calling_original_network then
        return oldJoinServerResponse(self, cancelled, ...)
    end
    if cancelled then
        DEBUG_print("原版通知取消加入，清理本次连接")
        join_context = nil
        ClearConnection()
        return oldJoinServerResponse(self, cancelled, ...)
    end
    local connection = join_context
    join_context = nil
    if not connection or current_connection ~= connection then
        DEBUG_print("加入入口没有有效的列表上下文，交给原版，不查询历史缓存")
        BeginConnection()
        return oldJoinServerResponse(self, cancelled, ...)
    end
    if connection.awaiting_listing then
        return CallOriginalNetwork(oldJoinServerResponse, self, cancelled, ...)
    end
    local join_args = PackArgs(self, cancelled, ...)
    -- 仅本次连接保留原版大厅参数，回退时原样重放，保留 P2P 路线；不写入配置缓存。
    connection.join_args = join_args
    connection.start_args = PackArgs(0, join_args[4]) -- 仅内存保留原版密码输入，回退时原样转发。
    RW_Data:LoadData(function()
        if current_connection ~= connection then
            return
        end
        local profile = connection.session and cached_data.profiles[connection.session]
        -- 只引用已有缓存；配置下发前的原生转分片也属于本次入服，不额外保存文件。
        connection.cached_config = profile and profile.config
        if not connection.session then
            DEBUG_print("列表session缺失，无法匹配缓存，使用原版入口")
        elseif not profile then
            DEBUG_print("本次session没有已学习的缓存，使用原版入口")
        else
            DEBUG_print("命中本次session缓存，缓存状态：", profile.suspect and "上次连接失败，等待新配置验证" or "正常")
        end
        local ip, port, changed = fix_ip_port(profile and profile.config, connection.ip, connection.port)
        if changed then
            connection.route = "cached"
            connection.awaiting_listing = true
            Toast(string.format("[强制纠正IP端口] 正在按缓存纠正IP端口并连接：\n%s:%s → %s:%s",
                connection.ip, tostring(connection.port), ip, tostring(port)), 20, "info")
            -- 密码来自原版输入框；StartClient 的后续原生 ping 回调只能续接本次连接。
            local started = CallOriginalNetwork(oldStartClient, self, ip, port, unpack(connection.start_args, 1, connection.start_args.n))
            if not started then
                DEBUG_print("缓存目标StartClient未能启动，准备回退")
                TryOriginalServer(connection)
            end
        elseif not JoinOriginalServer(connection) then
            OnNetworkDisconnect("ID_DST_USER_CONNECTION_FAILED", false)
        end
    end)
    return true
end

NetworkProxy.Disconnect = function(self, ...)
    if not calling_original_network then
        join_context = nil
        ClearConnection()
    end
    return oldDisconnect(self, ...)
end

local oldOnNetworkDisconnect = OnNetworkDisconnect
local connection_failure_messages = {
    ID_CONNECTION_ATTEMPT_FAILED = true,
    ID_DST_DESTINATION_CONNECTION_ATTEMPT_FAILED = true,
    ID_DST_USER_CONNECTION_FAILED = true,
    ID_DST_STEAM_NET_CONNECTION_TIMEOUT = true,
    ID_NAT_PUNCHTHROUGH_FAILED = true,
    ID_NAT_TARGET_NOT_CONNECTED = true,
    ID_NAT_TARGET_UNRESPONSIVE = true,
}
local connection_closed_messages = { ID_DISCONNECTION_NOTIFICATION = true, ID_CONNECTION_LOST = true }
GLOBAL.OnNetworkDisconnect = function(message, should_reset, force_immediate_reset, ...)
    DEBUG_print("收到网络断开通知：", message, "当前路线：", current_connection and current_connection.route or "无缓存连接路线")
    if not force_immediate_reset and current_connection and current_connection.route == "fallback_pending"
        and (connection_failure_messages[message] or connection_closed_messages[message]) then
        DEBUG_print("正在回退，忽略旧连接关闭通知")
        return
    end
    if not force_immediate_reset and connection_failure_messages[message] and current_connection and TryOriginalServer(current_connection) then
        return
    end
    if not force_immediate_reset and connection_failure_messages[message] and current_connection then
        Toast("[强制纠正IP端口] 服务器连接失败，请检查服务器状态、连接地址或网络", 10, "error")
    end
    ClearConnection()
    return oldOnNetworkDisconnect(message, should_reset, force_immediate_reset, ...)
end

----------------------------------------------------------------接收服务器模组配置--------------------------------------------------------------------------------

-- 原版 DownloadMods 的异步闭包必须携带发起时的连接对象，不能回调时再读取当前选服。
-- Lua 5.1 子闭包继承创建时的环境；调用结束恢复原函数环境，不永久替换游戏全局对象。
local oldDownloadMods = DownloadMods
GLOBAL.DownloadMods = function(listing, ...)
    local connection = current_connection
    if not connection then
        connection = BeginConnection()
    end
    connection.handshake = true
    connection.awaiting_listing = nil
    if not listing.mods_enabled then
        ReceiveConfig(connection, nil, false)
    end
    local scope = {}
    scope.KnownModIndex = WrapCallbackObject(KnownModIndex, {
        SetTempModConfigData = function(_, data, ...)
            if current_connection ~= connection then
                return
            end
            local result = PackArgs(KnownModIndex:SetTempModConfigData(data, ...))
            ReceiveConfig(connection, data[server_modid], data[server_modid] ~= nil)
            return unpack(result, 1, result.n)
        end,
    })
    scope.TheSim = WrapCallbackObject(TheSim, {
        StartDownloadTempMods = function(_, callback, ...)
            DEBUG_print("需要下载服务器模组，等待原版下载回调")
            return TheSim:StartDownloadTempMods(function(...)
                if current_connection == connection then
                    return callback(...)
                end
                DEBUG_print("忽略旧连接的模组下载回调")
            end, ...)
        end,
    })
    return CallWithCallbackContext(oldDownloadMods, scope, listing, ...)
end

----------------------------------------------------------------分片迁移与跨实例交接--------------------------------------------------------------------------------

local oldMigrateToServer, oldStartNextInstance = MigrateToServer, StartNextInstance
GLOBAL.MigrateToServer = function(ip, port, password, netid, ...)
    DEBUG_print("收到分片迁移请求，原始目标：", ip, port, "当前有效配置：", active_config and "存在" or "不存在")
    local connection = current_connection
    local cached_config = connection and connection.cached_config
    if not active_config and cached_config then
        DEBUG_print("配置尚未下发，借用本次入服缓存纠正迁移目标")
    end
    local fixed_ip, fixed_port, changed = fix_ip_port(active_config or cached_config, ip, port)
    pending_migration_context = {
        ip = fixed_ip,
        port = fixed_port,
        -- 仅在目标被纠正时记录原始入口，跨实例后仍可准确回退到本次迁移目的地。
        original_ip = changed and ip or nil,
        original_port = changed and port or nil,
        config = active_config,
        cached_config = not active_config and cached_config or nil,
        session = connection and connection.session,
    }
    return oldMigrateToServer(fixed_ip, fixed_port, password, netid, ...)
end

GLOBAL.StartNextInstance = function(params, ...)
    -- 配置尚未下发时，也交接本次缓存引用或来源 session，供目标世界收到配置后更新缓存。
    local context = pending_migration_context
    if params and params.reset_action == RESET_ACTION.LOAD_FILE and current_connection
        and current_connection.handshake and active_config then
        -- 成功加入后下载地图也会重建实例，此时不会再次调用 StartClient。
        context = { config = active_config, session = current_connection.session, save_name = params.save_name }
        DEBUG_print("地图加载重建实例，交接当前服务器规则")
    elseif not context or not (context.config or context.cached_config or context.session)
        or not params or params.reset_action ~= RESET_ACTION.JOIN_SERVER
        or params.serverIp ~= context.ip or NormalizePort(params.serverPort) ~= NormalizePort(context.port) then
        DEBUG_print("实例切换不携带有效迁移配置，交给原版")
        ClearConnection()
        return oldStartNextInstance(params, ...)
    end
    context.reset_action = params.reset_action
    context.token = tostring({}) .. ":" .. tostring(GetTimeReal())
    params[MIGRATION_TOKEN_KEY] = context.token
    params.dst_ip_fix_context = context
    -- 同步沿用原版实例切换链；快速加载模组可能截断重建，稍后消费内存中的迁移目标。
    DEBUG_print("通过本次实例参数交接配置，继续原版实例切换：", params.reset_action)
    return oldStartNextInstance(params, ...)
end

----------------------------------------------------------------回主菜单与手动重置--------------------------------------------------------------------------------

AddClassPostConstruct("screens/redux/mainscreen", function()
    if not InGamePlay() then
        join_context = nil
        ClearConnection()
    end
end)
rawset(GLOBAL, "c_reset_ip_port_fix_conf", function()
    ClearConnection()
    RW_Data:LoadData(function()
        cached_data = { version = 2, profiles = {} }
        RW_Data:SaveData(function(success)
            -- 失败提示由保存队列统一显示，避免同一次失败重复弹出。
            if success then
                Toast("[强制纠正IP端口] 已重置缓存数据", 5, "success")
            end
        end)
    end)
end)
