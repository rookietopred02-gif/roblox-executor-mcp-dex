--// Wait for game to load \\--
if not game:IsLoaded() then
    game.Loaded:Wait()
end

--// Variables \\--
local BridgeURL = getgenv().BridgeURL or ... or "localhost:16384"
local DEX_SCRIPT_URL = "https://github.com/LorekeeperZinnia/Dex/releases/download/1.0.0/out.lua"
local DEX_BRIDGE_KEY = "__ROBLOX_EXECUTOR_MCP_DEX_BRIDGE"
local DEX_BRIDGE_VERSION = "dex-bridge-2"

--// Functions \\--
local LuaEncode = loadstring(game:HttpGet("https://raw.githubusercontent.com/chadhyatt/LuaEncode/refs/heads/master/src/LuaEncode.lua"))()
local cloneref = cloneref or function(x) return x end
local decompile = decompile or function(x) return "-- Unable to get script content." end
local getnilinstances = getnilinstances or function() return {} end
local getscriptbytecode = getscriptbytecode or function(x) error("Unable to get script bytecode.") end

--// Services \\--
local RobloxReplicatedStorage = cloneref(game:GetService("RobloxReplicatedStorage"))
local MarketplaceService = cloneref(game:GetService("MarketplaceService"))
local CoreGui = cloneref(game:GetService("CoreGui"))
local CorePackages = cloneref(game:GetService("CorePackages"))
local HttpService = cloneref(game:GetService("HttpService"))
local LogService = cloneref(game:GetService("LogService"))
local Players = cloneref(game:GetService("Players"))

--// Compatibility Check \\--
local WebSocketAvailable = (
    typeof(WebSocket) ~= "nil" and
    typeof(WebSocket.connect) == "function"
) and (getgenv().DisableWebSocket ~= true)

--// Registration Info \\--
local function GetRegistrationInfo()
    local player = Players.LocalPlayer
    local placeName = "Unknown"
    pcall(function()
        local productInfo = MarketplaceService:GetProductInfo(game.PlaceId)
        placeName = productInfo.Name
    end)
    return {
        type = "register",
        username = player and player.Name or "Unknown",
        userId = player and player.UserId or 0,
        placeId = game.PlaceId,
        jobId = game.JobId,
        placeName = placeName,
    }
end

--// Base Bridge Class \\--
local BaseBridge = {}; do
    BaseBridge.__index = BaseBridge
    
    function BaseBridge:BindToType(type, callback)
        self.Callbacks[type] = callback
    end
    
    function BaseBridge:HandleMessage(data)
        if self.Callbacks[data.type] then
            local success, result = pcall(function()
                return self.Callbacks[data.type](data)
            end)
    
            if success and result == nil then
                return nil
            end
    
            return self:FormatResponse(result, data.id, not success)
        end
        return nil
    end
    
    function BaseBridge:FormatResponse(message, id, isError)
        if isError then
            return {
                error = tostring(message),
                success = false,
                id = id
            }
        end
        
        local output = message
        if typeof(output) ~= "table" then
            output = { output }
        end
    
        return {
            output = LuaEncode(output, {
                Prettify = true
            }),
            success = true,
            id = id
        }
    end
    
    function BaseBridge:IsAlive()
        local success, result = pcall(function()
            local response
            local thread = task.spawn(function()
                local success, data = pcall(request, {
                    Url = "http://" .. BridgeURL,
                    Method = "GET"
                })

                if success then
                    response = data
                end
            end)

            local start = os.clock()
            repeat task.wait() until response ~= nil or os.clock() - start > 5

            if response == nil then
                task.cancel(thread)
                return false
            end
    
            -- 426 = Upgrade Required (WebSocket), 200 = HTTP mode
            if response.StatusCode == 426 or response.StatusCode == 200 then
                return true
            end
    
            return false
        end)
    
        if not success then
            return false
        end
    
        return result
    end
end

--// WebSocket Bridge \\--
local WebSocketBridge = setmetatable({}, {__index = BaseBridge}); do
    WebSocketBridge.__index = WebSocketBridge
    
    function WebSocketBridge.new()
        local self = setmetatable({}, WebSocketBridge)
    
        --// Yield until the server is alive \\--
        while not self:IsAlive() do
            task.wait(0.1)
        end
    
        --// Connect to the server \\--
        self.WebSocket = WebSocket.connect("ws://" .. BridgeURL)
        self.Connected = true
        self.Callbacks = {}
        self.ClientId = nil

        --// Send registration \\--
        self.WebSocket:Send(HttpService:JSONEncode(GetRegistrationInfo()))

        self.AliveThread = task.spawn(function()
            while task.wait(1) do
                if self:IsAlive() or not self.Connected then
                    continue
                end
                
                self.Connected = false
                break
            end
    
            pcall(function()
                self.WebSocket:Close()
            end)
        end)
    
        --// On Message \\--
        self.WebSocket.OnMessage:Connect(function(message)
            local data = HttpService:JSONDecode(message)

            --// Handle registration response \\--
            if data.type == "registered" then
                self.ClientId = data.clientId
                return
            end

            local response = self:HandleMessage(data)
            if response then
                self.WebSocket:Send(HttpService:JSONEncode(response))
            end
        end)
    
        --// On Close \\--
        self.WebSocket.OnClose:Connect(function()
            self.Connected = false
        end)
    
        return self
    end
    
    function WebSocketBridge:WaitForDisconnect()
        while self.Connected do
            task.wait(0.1)
        end
    end
end

--// HTTP Polling Bridge \\--
local HTTPBridge = setmetatable({}, {__index = BaseBridge}); do
    HTTPBridge.__index = HTTPBridge
    
    function HTTPBridge.new()
        local self = setmetatable({}, HTTPBridge)
    
        --// Yield until the server is alive \\--
        while not self:IsAlive() do
            task.wait(0.1)
        end
    
        self.Connected = true
        self.Callbacks = {}
        self.PollInterval = 0.1
        self.ClientId = nil

        --// Register with the server \\--
        pcall(function()
            local regResponse = request({
                Url = "http://" .. BridgeURL .. "/register",
                Method = "POST",
                Headers = { ["Content-Type"] = "application/json" },
                Body = HttpService:JSONEncode(GetRegistrationInfo()),
            })
            if regResponse.StatusCode == 200 and regResponse.Body then
                local regData = HttpService:JSONDecode(regResponse.Body)
                self.ClientId = regData.clientId
            end
        end)
    
        --// Start polling thread \\--
        self.PollThread = task.spawn(function()
            local consecutiveFailures = 0
            
            while self.Connected do
                local success, _ = pcall(function()
                    local pollUrl = "http://" .. BridgeURL .. "/poll"
                    if self.ClientId then
                        pollUrl = pollUrl .. "?clientId=" .. self.ClientId
                    end
                    local response = request({
                        Url = pollUrl,
                        Method = "GET"
                    })

                    --// Server might be down \\--
                    if response.StatusCode ~= 204 and response.StatusCode ~= 200 then
                        consecutiveFailures += 1
                        if consecutiveFailures >= 3 then
                            self.Connected = false
                        end

                        return
                    end
                    
                    consecutiveFailures = 0
    
                    --// Handle response \\--
                    if response.Body and response.Body ~= "" then
                        local data = HttpService:JSONDecode(response.Body)
                        if data == nil or data.type == nil then return end
                        
                        local result = self:HandleMessage(data)
                        if result == nil then return end
                        
                        --// Send response back \\--
                        request({
                            Url = "http://" .. BridgeURL .. "/respond",
                            Method = "POST",
                            Headers = {
                                ["Content-Type"] = "application/json"
                            },
                            Body = HttpService:JSONEncode(result)
                        })
                    end
                end)
    
                if not success then
                    consecutiveFailures += 1
                    if consecutiveFailures >= 3 then
                        self.Connected = false
                    end
                end
    
                task.wait(self.PollInterval)
            end
        end)
    
        return self
    end
    
    function HTTPBridge:WaitForDisconnect()
        while self.Connected do
            task.wait(0.1)
        end
    end
end

--// Create Bridge \\--
local function CreateBridge()
    if WebSocketAvailable then
        local success, bridge = pcall(function()
            return WebSocketBridge.new()
        end)
        
        if success then
            return bridge
        end
    end

    return HTTPBridge.new()
end

--// Script Source Mapping \\--
local ScriptSourcesMap = {
    HasFinishedMapping = false
}

local ScriptInstanceMap = setmetatable({}, { __mode = "v" })
local SourcesToMap, MappedSources = 0, 0

local function MapScriptSource(script)
    local debugId = script:GetDebugId()
    if ScriptSourcesMap[debugId] then return end

    for attempt = 1, 10 do
        local success, decompOutput = pcall(decompile, script)
        if not success then
            task.wait(0.5)
            continue
        end
    
        ScriptSourcesMap[debugId] = decompOutput
        MappedSources += 1
        break
    end

    ScriptInstanceMap[debugId] = script
    script.Destroying:Once(function()
        ScriptInstanceMap[debugId] = nil
    end)
end

local function GetScriptByDebugId(debugId)
    local CachedInstance = ScriptInstanceMap[debugId]
    if CachedInstance then
        return CachedInstance
    end

    for _, script in game:QueryDescendants("LuaSourceContainer") do
        if script:IsA("Script") and script.RunContext == Enum.RunContext.Server then continue end
        if script:GetDebugId() ~= debugId then continue end
        
        ScriptInstanceMap[debugId] = script
        return script
    end

    for _, script in getnilinstances() do
        if script:IsA("LuaSourceContainer") and not script:IsA("Script") and script.RunContext == Enum.RunContext.Client then
            if script:GetDebugId() ~= debugId then continue end
            
            ScriptInstanceMap[debugId] = script
            return script
        end
    end

    return nil
end

do
    local function ShouldMapScript(script)        
        local IsServerScript = script:IsA("Script") and script.RunContext == Enum.RunContext.Server
        if IsServerScript then return false end

        local IsRobloxScript = script.RobloxLocked or script:IsDescendantOf(CoreGui) or script:IsDescendantOf(CorePackages)
        if IsRobloxScript then return false end

        local IsAlreadyMapped = ScriptSourcesMap[script:GetDebugId()]
        if IsAlreadyMapped then return false end

        local HasBytecode = pcall(getscriptbytecode, script)
        if not HasBytecode then return false end

        return true
    end

    game.DescendantAdded:Connect(function(script)
        if not script:IsA("LuaSourceContainer") then
            return
        end

        if not ShouldMapScript(script) then return end
        MapScriptSource(script)
    end)

    local CategoriesToMap = {
        game:QueryDescendants("LuaSourceContainer"),
        getnilinstances()
    }

    --// Map script sources \\--
    task.spawn(function()
        local ValidScripts = {}
        for _, category in CategoriesToMap do
            for _, script in category do
                if not script:IsA("LuaSourceContainer") then continue end
                if not ShouldMapScript(script) then continue end

                table.insert(ValidScripts, script)
            end
        end

        SourcesToMap = #ValidScripts

        for idx, scriptObject in ValidScripts do
            task.defer(MapScriptSource, scriptObject)
            if idx % 250 == 0 then task.wait(0.1) end
        end

        ScriptSourcesMap.HasFinishedMapping = true
    end)
end

--// Parse Query \\--
local function ConvertEscapes(str)
    local ConvertedStr = str:gsub("\\n", "\n"):gsub("\\r", "\r"):gsub("\\t", "\t")
    return ConvertedStr
end

local function GetLineInfo(source)
    local lineStarts = {1}
    local i = 1
    while true do
        local found = source:find("\n", i, true)
        if not found then break end
        table.insert(lineStarts, found + 1)
        i = found + 1
    end
    return lineStarts
end

local function GetLineNumber(lineStarts, pos)
    local low, high = 1, #lineStarts
    local res = 1
    while low <= high do
        local mid = math.floor((low + high) / 2)
        if lineStarts[mid] <= pos then
            res = mid
            low = mid + 1
        else
            high = mid - 1
        end
    end
    return res
end

local function ParseQuery(query)
    local stringMatchQueries = {}
    do  
        local queries = {}
        local isEscaping = false
        local currentQuery = ""
        
        for idx, query in query:split("|") do
            local lastChar = string.sub(query, #query)

            --// Handle escaping \\--
            if lastChar == "\\" then
                local escapedQuery = string.sub(query, 1, #query - 1)
                if isEscaping then
                    currentQuery ..= escapedQuery .. "|"
                else
                    isEscaping = true
                    currentQuery = escapedQuery .. "|"
                end
                continue
            elseif isEscaping then
                isEscaping = false
                currentQuery ..= query
            else
                currentQuery = query
            end

            --// Check for AND queries (split by &) \\--
            if currentQuery:find("&") then
                local andParts = currentQuery:split("&")
                local andQueries = {}
                
                for _, part in andParts do
                    if part ~= "" then
                        table.insert(andQueries, part)
                    end
                end
                
                if #andQueries > 1 then
                    table.insert(queries, { AndQueries = andQueries })
                elseif #andQueries == 1 then
                    table.insert(queries, andQueries[1])
                end
            else
                table.insert(queries, currentQuery)
            end
        end

        for _, query in queries do
            if typeof(query) == "string" then
                if query == "" then continue end
                table.insert(stringMatchQueries, ConvertEscapes(query))
            elseif typeof(query) == "table" and query.AndQueries then
                local convertedAnd = {}
                for _, andQuery in query.AndQueries do
                    table.insert(convertedAnd, ConvertEscapes(andQuery))
                end
                table.insert(stringMatchQueries, { AndQueries = convertedAnd })
            end
        end
    end

    return stringMatchQueries
end

--// Dex Helpers \\--
local function FindDexMainMenu()
    local mainMenu = CoreGui:FindFirstChild("MainMenu")
    if mainMenu and mainMenu:IsA("ScreenGui") then
        return mainMenu, "CoreGui"
    end

    local localPlayer = Players.LocalPlayer
    local playerGui = localPlayer and localPlayer:FindFirstChildOfClass("PlayerGui")
    if playerGui then
        mainMenu = playerGui:FindFirstChild("MainMenu")
        if mainMenu and mainMenu:IsA("ScreenGui") then
            return mainMenu, "PlayerGui"
        end
    end

    return nil, nil
end

local function GetDexMenuOpenState(mainMenu)
    if not mainMenu or not mainMenu:IsA("ScreenGui") then
        return nil, nil, nil
    end

    local openButton = mainMenu:FindFirstChild("OpenButton", true)
    if not openButton or not openButton:IsA("TextButton") then
        return nil, nil, nil
    end

    local buttonText = tostring(openButton.Text or "")
    if buttonText == "X" then
        return true, buttonText, openButton
    end
    if buttonText == "Dex" then
        return false, buttonText, openButton
    end

    return nil, buttonText, openButton
end

local function TryToggleDexMenu(openButton, requestedOpen)
    if not openButton or not openButton:IsA("GuiButton") then
        return false, "none"
    end

    local function IsRequestedState()
        local text = tostring(openButton.Text or "")
        if requestedOpen then
            return text == "X"
        end
        return text == "Dex"
    end

    if IsRequestedState() then
        return true, "none"
    end

    local activateCalled = pcall(function()
        openButton:Activate()
    end)

    if activateCalled then
        local waitStart = os.clock()
        while os.clock() - waitStart < 1 do
            if IsRequestedState() then
                return true, "activate"
            end
            task.wait()
        end
    end

    if getconnections then
        local gotConnections, connections = pcall(getconnections, openButton.MouseButton1Click)
        if gotConnections and typeof(connections) == "table" then
            for _, connection in connections do
                pcall(function()
                    if connection and connection.Fire then
                        connection:Fire()
                    end
                end)
            end

            local waitStart = os.clock()
            while os.clock() - waitStart < 1 do
                if IsRequestedState() then
                    return true, "getconnections"
                end
                task.wait()
            end
        end
    end

    return IsRequestedState(), activateCalled and "activate" or "none"
end

local DexSourceCache = nil
local DexBridgeRuntimeState = {
    status = "fallback",
    message = "Dex bridge has not been initialized yet. Call ensure-dex first."
}

local function GetBridgeEnv()
    if getgenv then
        return getgenv()
    end
    return _G
end

local function SetDexBridgeRuntimeState(status, message)
    DexBridgeRuntimeState.status = status
    DexBridgeRuntimeState.message = message
end

local function GetDexBridge()
    local bridge = GetBridgeEnv()[DEX_BRIDGE_KEY]
    if typeof(bridge) == "table" then
        return bridge
    end
    return nil
end

local function GetDexBridgeStatus()
    local bridge = GetDexBridge()
    if bridge then
        local bridgeStatus = bridge.status
        if bridgeStatus ~= "ready" and bridgeStatus ~= "fallback" and bridgeStatus ~= "patch_failed" then
            bridgeStatus = bridge.ready and "ready" or "fallback"
        end
        return bridge, bridgeStatus, tostring(bridge.message or "Dex bridge state available.")
    end

    return nil, DexBridgeRuntimeState.status, DexBridgeRuntimeState.message
end

local function ClampInt(value, minValue, maxValue, fallback)
    local n = tonumber(value)
    if n == nil then
        n = fallback
    end
    n = math.floor(n)
    if n < minValue then n = minValue end
    if n > maxValue then n = maxValue end
    return n
end

local function Paginate(list, startIndex, limit, maxLimit, defaultLimit)
    local pageStart = ClampInt(startIndex, 1, math.max(1, #list), 1)
    local pageLimit = ClampInt(limit, 1, maxLimit, defaultLimit)
    local pageEnd = math.min(#list, pageStart + pageLimit - 1)
    local results = {}

    for i = pageStart, pageEnd do
        results[#results + 1] = list[i]
    end

    return {
        total = #list,
        startIndex = pageStart,
        limit = pageLimit,
        returned = #results,
        hasMore = pageEnd < #list,
        results = results
    }
end

local function ContainsCaseInsensitive(haystack, needle)
    if needle == "" then
        return true
    end
    return string.find(string.lower(tostring(haystack or "")), string.lower(needle), 1, true) ~= nil
end

local function BuildSimpleInstancePath(obj)
    if typeof(obj) ~= "Instance" then
        return "<non-instance>"
    end

    if obj == game then
        return "game"
    end

    local pathParts = {}
    local current = obj

    while current and current ~= game do
        local currentName = current.Name
        if string.match(currentName, "^[%a_][%w_]*$") then
            table.insert(pathParts, 1, "." .. currentName)
        else
            table.insert(pathParts, 1, "[" .. string.format("%q", currentName) .. "]")
        end
        current = current.Parent
    end

    if current ~= game then
        return tostring(obj)
    end

    return "game" .. table.concat(pathParts)
end

local function SafePathFromInstance(obj)
    if typeof(obj) ~= "Instance" then
        return "<non-instance>"
    end

    local bridge = GetDexBridge()
    local explorer = bridge and bridge.apps and bridge.apps.Explorer
    if typeof(explorer) == "table" and typeof(explorer.GetInstancePath) == "function" then
        local ok, path = pcall(explorer.GetInstancePath, obj)
        if ok and typeof(path) == "string" and path ~= "" then
            return path
        end
    end

    return BuildSimpleInstancePath(obj)
end

local function ResolveInstancePath(instancePath)
    if typeof(instancePath) ~= "string" or instancePath == "" then
        return nil, "instancePath is empty."
    end

    local ok, resolved = pcall(function()
        return loadstring("return " .. instancePath)()
    end)
    if not ok then
        return nil, "Failed to resolve instancePath: " .. tostring(resolved)
    end

    if typeof(resolved) ~= "Instance" then
        return nil, "instancePath did not resolve to an Instance."
    end

    return resolved, nil
end

local function ResolveDexTargetInstance(instancePath, selectionIndex)
    if typeof(instancePath) == "string" and instancePath ~= "" then
        return ResolveInstancePath(instancePath)
    end

    local bridge, bridgeStatus = GetDexBridgeStatus()
    if bridgeStatus ~= "ready" or not bridge then
        return nil, "Dex bridge is not ready. Call ensure-dex first or provide instancePath."
    end

    local explorer = bridge.apps and bridge.apps.Explorer
    local mcp = explorer and explorer.__MCP
    if typeof(mcp) ~= "table" or typeof(mcp.GetSelectionNodes) ~= "function" then
        return nil, "Dex selection reader is unavailable. Provide instancePath."
    end

    local okSelection, selectionNodes = pcall(mcp.GetSelectionNodes)
    if not okSelection or typeof(selectionNodes) ~= "table" then
        return nil, "Failed to read Dex selection. Provide instancePath."
    end

    if #selectionNodes == 0 then
        return nil, "Dex selection is empty. Select an instance in Dex or provide instancePath."
    end

    local resolvedIndex = ClampInt(selectionIndex, 1, #selectionNodes, 1)
    local selectedNode = selectionNodes[resolvedIndex]
    if typeof(selectedNode) ~= "table" or typeof(selectedNode.Obj) ~= "Instance" then
        return nil, "Dex selection entry is invalid. Provide instancePath."
    end

    return selectedNode.Obj, nil
end

local function ReplaceOnce(source, pattern, replacement)
    local count = 0
    local updated = string.gsub(source, pattern, function()
        count = count + 1
        return replacement
    end, 1)
    return updated, count
end

local function PatchDexSource(rawSource)
    if typeof(rawSource) ~= "string" or rawSource == "" then
        return nil, "Dex source is empty."
    end

    if string.find(rawSource, DEX_BRIDGE_KEY, 1, true) then
        return rawSource, nil
    end

    local explorerBridgeSnippet = [[
	Explorer.__MCP = Explorer.__MCP or {}
	Explorer.__MCP.Version = "dex-bridge-2"

	Explorer.__MCP.GetSelectionNodes = function()
		local result = {}
		if not selection or not selection.List then
			return result
		end
		for i = 1,#selection.List do
			result[#result+1] = selection.List[i]
		end
		return result
	end

	Explorer.__MCP.GetSelectionCount = function()
		return (selection and selection.List and #selection.List) or 0
	end

	Explorer.__MCP.GetSearchText = function()
		local searchBar = Explorer.GuiElems and Explorer.GuiElems.SearchBar
		if searchBar and searchBar.Text then
			return tostring(searchBar.Text)
		end
		return ""
	end

	Explorer.__MCP.GetTreeRows = function(options)
		options = options or {}
		local includeAll = options.includeAll == true
		local includeSearchOnly = options.includeSearchOnly == true
		local includeNilRoot = options.includeNilRoot ~= false
		local rows = {}

		local function walk(root, depth)
			if not root then return end
			for i = 1,#root do
				local node = root[i]
				if node and not node.Del then
					local isExpanded = expanded and expanded[node] and true or false
					local isSearchResult = searchResults and searchResults[node] and true or false
					if (not includeSearchOnly) or isSearchResult then
						rows[#rows+1] = {
							Node = node,
							Depth = depth,
							Expanded = isExpanded,
							HasChildren = #node > 0,
							IsSearchResult = isSearchResult,
							IsNilRoot = false
						}
					end
					if #node > 0 and (includeAll or isExpanded) then
						walk(node, depth + 1)
					end
				end
			end
		end

		walk(nodes and nodes[game], 0)

		if includeNilRoot and nilNode and nodes and nodes[nilNode.Obj] then
			local isExpanded = expanded and expanded[nilNode] and true or false
			local isSearchResult = searchResults and searchResults[nilNode] and true or false
			if (not includeSearchOnly) or isSearchResult then
				rows[#rows+1] = {
					Node = nilNode,
					Depth = 0,
					Expanded = isExpanded,
					HasChildren = #nilNode > 0,
					IsSearchResult = isSearchResult,
					IsNilRoot = true
				}
			end
			if #nilNode > 0 and (includeAll or isExpanded) then
				walk(nilNode, 1)
			end
		end

		return rows
	end

	Explorer.__MCP.GetNodeForObject = function(obj)
		if not nodes then return nil end
		return nodes[obj]
	end

	local function _mcpCloneSelectionNodes()
		local result = {}
		if not selection or not selection.List then
			return result
		end
		for i = 1,#selection.List do
			result[#result + 1] = selection.List[i]
		end
		return result
	end

	local function _mcpSetSelectionByNodes(newNodes)
		if not selection then
			return
		end
		if selection.SetTable then
			selection:SetTable(newNodes)
			return
		end
		if selection.Clear then
			selection:Clear()
		end
		if selection.Add then
			for i = 1,#newNodes do
				selection:Add(newNodes[i])
			end
		end
	end

	local function _mcpResolveNodesForObjects(objects)
		local resolved = {}
		for i = 1,#objects do
			local obj = objects[i]
			if typeof(obj) ~= "Instance" then
				continue
			end
			local node = nodes and nodes[obj]
			if node then
				resolved[#resolved + 1] = node
			end
		end
		return resolved
	end

	Explorer.__MCP.GetSelectionObjects = function()
		local result = {}
		local list = _mcpCloneSelectionNodes()
		for i = 1,#list do
			local node = list[i]
			if typeof(node) == "table" and typeof(node.Obj) == "Instance" then
				result[#result + 1] = node.Obj
			end
		end
		return result
	end

	Explorer.__MCP.ClearSelection = function()
		if selection and selection.Clear then
			selection:Clear()
		end
		return true
	end

	Explorer.__MCP.SelectObjects = function(objects, mode)
		mode = mode or "replace"
		local resolvedNodes = _mcpResolveNodesForObjects(objects or {})

		if mode == "replace" then
			_mcpSetSelectionByNodes(resolvedNodes)
		elseif mode == "add" then
			if selection and selection.Add then
				for i = 1,#resolvedNodes do
					if not selection.Map[resolvedNodes[i]] then
						selection:Add(resolvedNodes[i])
					end
				end
			end
		elseif mode == "remove" then
			if selection and selection.Remove then
				for i = 1,#resolvedNodes do
					if selection.Map[resolvedNodes[i]] then
						selection:Remove(resolvedNodes[i])
					end
				end
			else
				local removeMap = {}
				for i = 1,#resolvedNodes do
					removeMap[resolvedNodes[i]] = true
				end
				local keep = {}
				local old = _mcpCloneSelectionNodes()
				for i = 1,#old do
					if not removeMap[old[i]] then
						keep[#keep + 1] = old[i]
					end
				end
				_mcpSetSelectionByNodes(keep)
			end
		else
			return false, "Invalid selection mode: " .. tostring(mode)
		end

		local current = _mcpCloneSelectionNodes()
		if #current > 0 then
			pcall(Explorer.MakeNodeVisible, current[1], true)
			pcall(Explorer.ViewNode, current[1])
		end
		return true, #current
	end

	Explorer.__MCP.SearchSet = function(query)
		if Explorer.DoSearch then
			Explorer.DoSearch(tostring(query or ""))
		end
		return true
	end

	Explorer.__MCP.SearchClear = function()
		if Explorer.ClearSearch then
			Explorer.ClearSearch()
		end
		return true
	end

	Explorer.__MCP.ExpandAll = function()
		local sList = _mcpCloneSelectionNodes()
		local function recur(node)
			expanded[node] = true
			for i = 1,#node do
				if #node[i] > 0 then
					recur(node[i])
				end
			end
		end
		for i = 1,#sList do
			recur(sList[i])
		end
		pcall(Explorer.ForceUpdate)
		return true, #sList
	end

	Explorer.__MCP.CollapseAll = function()
		local sList = _mcpCloneSelectionNodes()
		local function recur(node)
			expanded[node] = nil
			for i = 1,#node do
				if #node[i] > 0 then
					recur(node[i])
				end
			end
		end
		for i = 1,#sList do
			recur(sList[i])
		end
		pcall(Explorer.ForceUpdate)
		return true, #sList
	end

	Explorer.__MCP.SelectChildren = function()
		local sList = _mcpCloneSelectionNodes()
		local newSelection = {}
		local count = 1
		for i = 1,#sList do
			local node = sList[i]
			for ind = 1,#node do
				local cNode = node[ind]
				if ind == 1 then
					pcall(Explorer.MakeNodeVisible, cNode, true)
				end
				newSelection[count] = cNode
				count = count + 1
			end
		end
		_mcpSetSelectionByNodes(newSelection)
		if #newSelection > 0 then
			pcall(Explorer.ViewNode, newSelection[1])
		end
		return true, #newSelection
	end

	Explorer.__MCP.JumpToParent = function()
		local sList = _mcpCloneSelectionNodes()
		local newSelection = {}
		local count = 1
		for i = 1,#sList do
			local node = sList[i]
			if node.Parent then
				newSelection[count] = node.Parent
				count = count + 1
			end
		end
		_mcpSetSelectionByNodes(newSelection)
		if #newSelection > 0 then
			pcall(Explorer.ViewNode, newSelection[1])
		end
		return true, #newSelection
	end

	Explorer.__MCP.Rename = function(name)
		local first = selection and selection.List and selection.List[1]
		if not first or typeof(first.Obj) ~= "Instance" then
			return false, "Selection is empty."
		end
		name = tostring(name or "")
		if name == "" then
			return false, "Rename value is empty."
		end
		local ok, err = pcall(function()
			first.Obj.Name = name
		end)
		if not ok then
			return false, tostring(err)
		end
		return true, name
	end

	Explorer.__MCP.Copy = function()
		local clone = game.Clone
		local sList,newClipboard = _mcpCloneSelectionNodes(),{}
		local count = 1
		for i = 1,#sList do
			local inst = sList[i].Obj
			local s,cloned = pcall(clone,inst)
			if s and cloned then
				newClipboard[count] = cloned
				count = count + 1
			end
		end
		clipboard = newClipboard
		return true, #newClipboard
	end

	Explorer.__MCP.Cut = function()
		local destroy,clone = game.Destroy,game.Clone
		local sList,newClipboard = _mcpCloneSelectionNodes(),{}
		local count = 1
		for i = 1,#sList do
			local inst = sList[i].Obj
			local s,cloned = pcall(clone,inst)
			if s and cloned then
				newClipboard[count] = cloned
				count = count + 1
			end
			pcall(destroy,inst)
		end
		clipboard = newClipboard
		if selection and selection.Clear then
			selection:Clear()
		end
		return true, #newClipboard
	end

	Explorer.__MCP.PasteInto = function(targetObjects)
		local targets = targetObjects or {}
		if #targets == 0 then
			local sList = _mcpCloneSelectionNodes()
			for i = 1,#sList do
				targets[#targets + 1] = sList[i].Obj
			end
		end
		if #targets == 0 then
			return false, "No target provided for paste."
		end

		local newSelection = {}
		local count = 1
		for i = 1,#targets do
			local target = targets[i]
			for c = 1,#clipboard do
				local cloned = clipboard[c]:Clone()
				if cloned then
					cloned.Parent = target
					local clonedNode = nodes[cloned]
					if clonedNode then
						newSelection[count] = clonedNode
						count = count + 1
					end
				end
			end
		end
		_mcpSetSelectionByNodes(newSelection)
		if #newSelection > 0 then
			pcall(Explorer.ViewNode, newSelection[1])
		end
		return true, #newSelection
	end

	Explorer.__MCP.Duplicate = function()
		local clone = game.Clone
		local sList = _mcpCloneSelectionNodes()
		local newSelection = {}
		local count = 1
		for i = 1,#sList do
			local node = sList[i]
			local inst = node.Obj
			local instPar = node.Parent and node.Parent.Obj
			pcall(Explorer.MakeNodeVisible, node, true)
			local s,cloned = pcall(clone,inst)
			if s and cloned then
				cloned.Parent = instPar
				local clonedNode = nodes[cloned]
				if clonedNode then
					newSelection[count] = clonedNode
					count = count + 1
				end
			end
		end
		_mcpSetSelectionByNodes(newSelection)
		if #newSelection > 0 then
			pcall(Explorer.ViewNode, newSelection[1])
		end
		return true, #newSelection
	end

	Explorer.__MCP.Delete = function()
		local destroy = game.Destroy
		local sList = _mcpCloneSelectionNodes()
		local removed = 0
		for i = 1,#sList do
			if pcall(destroy, sList[i].Obj) then
				removed = removed + 1
			end
		end
		if selection and selection.Clear then
			selection:Clear()
		end
		return true, removed
	end

	Explorer.__MCP.Group = function()
		local sList = _mcpCloneSelectionNodes()
		if #sList == 0 then
			return false, "Selection is empty."
		end
		local model = Instance.new("Model", sList[#sList].Obj.Parent)
		for i = 1,#sList do
			pcall(function()
				sList[i].Obj.Parent = model
			end)
		end
		if nodes[model] then
			if selection and selection.Set then
				selection:Set(nodes[model])
			end
			pcall(Explorer.ViewNode, nodes[model])
		end
		return true, model
	end

	Explorer.__MCP.Ungroup = function()
		local newSelection = {}
		local count = 1
		local isa = game.IsA
		local sList = _mcpCloneSelectionNodes()

		local function ungroup(node)
			local par = node.Parent and node.Parent.Obj
			if not par then
				return
			end
			local ch = {}
			for i = 1,#node do
				local n = node[i]
				newSelection[count] = n
				ch[#ch + 1] = n
				count = count + 1
			end
			for i = 1,#ch do
				pcall(function()
					ch[i].Obj.Parent = par
				end)
			end
			node.Obj:Destroy()
		end

		for i = 1,#sList do
			local v = sList[i]
			if isa(v.Obj, "Model") then
				ungroup(v)
			end
		end

		_mcpSetSelectionByNodes(newSelection)
		if #newSelection > 0 then
			pcall(Explorer.ViewNode, newSelection[1])
		end
		return true, #newSelection
	end

	Explorer.__MCP.Reparent = function(newParent)
		if typeof(newParent) ~= "Instance" then
			return false, "newParent is not an Instance."
		end
		local sList = _mcpCloneSelectionNodes()
		local moved = 0
		for i = 1,#sList do
			if pcall(function() sList[i].Obj.Parent = newParent end) then
				moved = moved + 1
			end
		end
		return true, moved
	end

	Explorer.__MCP.InsertObject = function(className, parentObj)
		className = tostring(className or "")
		if className == "" then
			return false, "className is empty."
		end
		local targetParent = parentObj
		if typeof(targetParent) ~= "Instance" then
			local sList = _mcpCloneSelectionNodes()
			targetParent = sList[1] and sList[1].Obj or game
		end
		local ok, objOrErr = pcall(Instance.new, className)
		if not ok then
			return false, tostring(objOrErr)
		end
		objOrErr.Parent = targetParent
		local node = nodes[objOrErr]
		if node then
			_mcpSetSelectionByNodes({node})
			pcall(Explorer.ViewNode, node)
		end
		return true, objOrErr
	end

	Explorer.__MCP.CopyPath = function()
		local sList = _mcpCloneSelectionNodes()
		local paths = {}
		for i = 1,#sList do
			paths[#paths + 1] = Explorer.GetInstancePath(sList[i].Obj)
		end
		if env.setclipboard and #paths > 0 then
			if #paths == 1 then
				env.setclipboard(paths[1])
			else
				local lines = {"{"}
				for i = 1,#paths do
					lines[#lines + 1] = "\t" .. paths[i] .. ","
				end
				lines[#lines + 1] = "}"
				env.setclipboard(table.concat(lines, "\n"))
			end
		end
		return true, paths
	end

	Explorer.__MCP.TeleportTo = function()
		local sList = _mcpCloneSelectionNodes()
		local isa = game.IsA
		local hrp = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
		if not hrp then
			return false, "HumanoidRootPart is unavailable."
		end
		for i = 1,#sList do
			local node = sList[i]
			if isa(node.Obj, "BasePart") then
				hrp.CFrame = node.Obj.CFrame + Settings.Explorer.TeleportToOffset
				return true, node.Obj
			elseif isa(node.Obj, "Model") then
				if node.Obj.PrimaryPart then
					hrp.CFrame = node.Obj.PrimaryPart.CFrame + Settings.Explorer.TeleportToOffset
					return true, node.Obj.PrimaryPart
				end
				local part = node.Obj:FindFirstChildWhichIsA("BasePart", true)
				if part then
					hrp.CFrame = part.CFrame + Settings.Explorer.TeleportToOffset
					return true, part
				end
			end
		end
		return false, "No BasePart/Model target in selection."
	end

	Explorer.__MCP.ViewObject = function()
		local sList = _mcpCloneSelectionNodes()
		local isa = game.IsA
		for i = 1,#sList do
			local node = sList[i]
			if isa(node.Obj, "BasePart") or isa(node.Obj, "Model") then
				workspace.CurrentCamera.CameraSubject = node.Obj
				return true, node.Obj
			end
		end
		return false, "No BasePart/Model target in selection."
	end

	Explorer.__MCP.ViewScript = function()
		local scr = selection and selection.List and selection.List[1] and selection.List[1].Obj
		if scr and ScriptViewer and ScriptViewer.ViewScript then
			ScriptViewer.ViewScript(scr)
			return true, scr
		end
		return false, "No script selected."
	end

	Explorer.__MCP.SelectCharacter = function()
		local newSelection = {}
		local count = 1
		local sList = _mcpCloneSelectionNodes()
		local isa = game.IsA
		for i = 1,#sList do
			local node = sList[i]
			if isa(node.Obj, "Player") and nodes[node.Obj.Character] then
				newSelection[count] = nodes[node.Obj.Character]
				count = count + 1
			end
		end
		_mcpSetSelectionByNodes(newSelection)
		if #newSelection > 0 then
			pcall(Explorer.ViewNode, newSelection[1])
		end
		return true, #newSelection
	end

	Explorer.__MCP.RefreshNil = function()
		if Explorer.RefreshNilInstances then
			Explorer.RefreshNilInstances()
		end
		return true
	end

	Explorer.__MCP.HideNil = function()
		if Explorer.HideNilInstances then
			Explorer.HideNilInstances()
		end
		return true
	end

	Explorer.__MCP.CallFunction = function(args)
		local first = selection and selection.List and selection.List[1] and selection.List[1].Obj
		if typeof(first) ~= "Instance" then
			return false, "No selected instance."
		end
		args = args or {}
		if first:IsA("BindableFunction") then
			local ok, result = pcall(function()
				return first:Invoke(unpack(args))
			end)
			return ok, result
		end
		if first:IsA("RemoteFunction") then
			local ok, result = pcall(function()
				return first:InvokeServer(unpack(args))
			end)
			return ok, result
		end
		return false, "Selected object is not callable."
	end

	Explorer.__MCP.GetLuaReferences = function()
		return true, {}
	end

	Explorer.__MCP.SaveInstance = function(filePath)
		if not writefile then
			return false, "writefile is unavailable."
		end
		local targets = Explorer.__MCP.GetSelectionObjects()
		if #targets == 0 then
			return false, "Selection is empty."
		end
		local lines = {}
		for i = 1,#targets do
			lines[#lines + 1] = Explorer.GetInstancePath(targets[i])
		end
		local resolved = tostring(filePath or ("dex/saved/selection_paths_" .. tostring(os.time()) .. ".txt"))
		writefile(resolved, table.concat(lines, "\n"))
		return true, resolved
	end

	Explorer.__MCP.ViewConnections = function()
		return true, {}
	end

	Explorer.__MCP.ViewAPI = function()
		local first = selection and selection.List and selection.List[1] and selection.List[1].Obj
		if typeof(first) ~= "Instance" then
			return false, "No selected instance."
		end
		local classData = API and API.Classes and API.Classes[first.ClassName]
		return true, classData
	end
]]

    local propertiesBridgeSnippet = [[
	Properties.__MCP = Properties.__MCP or {}
	Properties.__MCP.Version = "dex-bridge-2"

	Properties.__MCP.BuildRowsForObject = function(obj, options)
		options = options or {}
		if typeof(obj) ~= "Instance" then
			return {}, "Target object is not an Instance."
		end
		if not Explorer or not Explorer.Selection then
			return {}, "Explorer selection is unavailable."
		end

		local includeTags = options.includeTags ~= false
		local search = tostring(options.search or "")
		local searchLower = string.lower(search)

		local selectionRef = Explorer.Selection
		local oldList = selectionRef.List
		local oldMap = selectionRef.Map
		local tempNode = {Obj = obj, Class = obj.ClassName}

		selectionRef.List = {tempNode}
		selectionRef.Map = {[tempNode] = true}

		local ok, err = pcall(function()
			Properties.ShowExplorerProps()
		end)

		local rows = {}
		if ok then
			for i = 1,#viewList do
				local prop = viewList[i]
				if prop and not prop.CategoryName and not prop.SpecialRow then
					local displayName = prop.DisplayName or prop.Name or ""
					local valueOk, valueOrErr = pcall(function()
						return Properties.GetPropVal(prop, obj)
					end)

					local row = {
						Category = prop.Category or "Data",
						Name = prop.Name or displayName,
						DisplayName = displayName,
						Class = prop.Class or obj.ClassName,
						ValueType = prop.ValueType and prop.ValueType.Name or "unknown",
						Value = valueOk and valueOrErr or nil,
						Readable = valueOk,
						ReadableValue = valueOk and tostring(valueOrErr) or "<unreadable>",
						SubName = prop.SubName
					}
					if includeTags then
						row.Tags = prop.Tags or {}
					end

					if search == ""
						or string.find(string.lower(tostring(row.Name or "")), searchLower, 1, true)
						or string.find(string.lower(tostring(row.DisplayName or "")), searchLower, 1, true)
						or string.find(string.lower(tostring(row.Category or "")), searchLower, 1, true) then
						rows[#rows+1] = row
					end
				end
			end
		end

		selectionRef.List = oldList
		selectionRef.Map = oldMap
		pcall(function()
			Properties.ShowExplorerProps()
		end)

		if not ok then
			return {}, "Failed to build properties snapshot: " .. tostring(err)
		end

		return rows, nil
	end

	local function _mcpWithTempSelection(obj, callback)
		if typeof(obj) ~= "Instance" then
			return false, "Target object is not an Instance."
		end
		if not Explorer or not Explorer.Selection then
			return false, "Explorer selection is unavailable."
		end

		local selectionRef = Explorer.Selection
		local oldList = selectionRef.List
		local oldMap = selectionRef.Map
		local tempNode = (Explorer.__MCP and Explorer.__MCP.GetNodeForObject and Explorer.__MCP.GetNodeForObject(obj)) or {Obj = obj, Class = obj.ClassName}
		selectionRef.List = {tempNode}
		selectionRef.Map = {[tempNode] = true}

		local ok, a, b = pcall(callback, tempNode)

		selectionRef.List = oldList
		selectionRef.Map = oldMap
		pcall(function()
			Properties.ShowExplorerProps()
		end)

		if not ok then
			return false, tostring(a)
		end
		return true, a, b
	end

	local function _mcpParsePropertyValue(prop, payload)
		payload = payload or {}
		if payload.clear == true then
			return nil, true
		end
		if payload.value ~= nil then
			return payload.value, true
		end

		local raw = payload.valueRaw
		if raw == nil then
			return nil, false
		end

		if typeof(raw) ~= "string" then
			return raw, true
		end

		local parsed = Properties.StringToValue(prop, raw)
		if parsed ~= nil then
			return parsed, true
		end

		local enumClass, enumItem = string.match(raw, "^Enum%.([%w_]+)%.([%w_]+)$")
		if enumClass and enumItem and Enum[enumClass] and Enum[enumClass][enumItem] then
			return Enum[enumClass][enumItem], true
		end

		local vec3 = string.match(raw, "^Vector3%((.*)%)$")
		if vec3 then
			local vals = string.split(vec3, ",")
			local x = tonumber(vals[1]); local y = tonumber(vals[2]); local z = tonumber(vals[3])
			if x and y and z then
				return Vector3.new(x, y, z), true
			end
		end

		local vec2 = string.match(raw, "^Vector2%((.*)%)$")
		if vec2 then
			local vals = string.split(vec2, ",")
			local x = tonumber(vals[1]); local y = tonumber(vals[2])
			if x and y then
				return Vector2.new(x, y), true
			end
		end

		local udim = string.match(raw, "^UDim%((.*)%)$")
		if udim then
			local vals = string.split(udim, ",")
			local s = tonumber(vals[1]); local o = tonumber(vals[2])
			if s and o then
				return UDim.new(s, o), true
			end
		end

		local udim2 = string.match(raw, "^UDim2%((.*)%)$")
		if udim2 then
			local vals = string.split(udim2, ",")
			local xScale = tonumber(vals[1]); local xOffset = tonumber(vals[2])
			local yScale = tonumber(vals[3]); local yOffset = tonumber(vals[4])
			if xScale and xOffset and yScale and yOffset then
				return UDim2.new(xScale, xOffset, yScale, yOffset), true
			end
		end

		local rgb = string.match(raw, "^Color3%.fromRGB%((.*)%)$")
		if rgb then
			local vals = string.split(rgb, ",")
			local r = tonumber(vals[1]); local g = tonumber(vals[2]); local b = tonumber(vals[3])
			if r and g and b then
				return Color3.fromRGB(r, g, b), true
			end
		end

		local hint = tostring(payload.valueTypeHint or "")
		if hint == "number" then
			local num = tonumber(raw)
			if num ~= nil then
				return num, true
			end
		elseif hint == "boolean" then
			if raw == "true" then return true, true end
			if raw == "false" then return false, true end
		end

		return nil, false
	end

	Properties.__MCP.ResolveProperty = function(obj, propName)
		propName = tostring(propName or "")
		if propName == "" then
			return nil, "Property name is empty."
		end

		local ok, propOrErr = _mcpWithTempSelection(obj, function()
			Properties.ShowExplorerProps()
			local needle = string.lower(propName)
			for i = 1,#viewList do
				local prop = viewList[i]
				if prop and not prop.CategoryName and not prop.SpecialRow then
					local n1 = string.lower(tostring(prop.Name or ""))
					local n2 = string.lower(tostring(prop.DisplayName or ""))
					if n1 == needle or n2 == needle then
						return prop
					end
				end
			end
			return nil
		end)

		if not ok then
			return nil, tostring(propOrErr)
		end
		if not propOrErr then
			return nil, "Property not found: " .. propName
		end
		return propOrErr, nil
	end

	Properties.__MCP.SetProperty = function(obj, propName, payload)
		local prop, err = Properties.__MCP.ResolveProperty(obj, propName)
		if not prop then
			return false, err
		end

		local setValue, parsed = _mcpParsePropertyValue(prop, payload)
		if not parsed then
			return false, "Unable to parse value for property '" .. tostring(propName) .. "'."
		end

		local ok, setErr = _mcpWithTempSelection(obj, function()
			Properties.SetProp(prop, setValue)
		end)
		if not ok then
			return false, tostring(setErr)
		end
		return true
	end

	Properties.__MCP.SetPropertiesBatch = function(obj, patches)
		local applied = 0
		local errors = {}
		for i = 1,#patches do
			local patch = patches[i]
			local ok, err = Properties.__MCP.SetProperty(obj, patch.name, patch)
			if ok then
				applied = applied + 1
			else
				errors[#errors + 1] = {index = i, name = patch.name, error = tostring(err)}
			end
		end
		return applied, errors
	end

	Properties.__MCP.SearchSet = function(text)
		Properties.SearchText = tostring(text or "")
		Properties.Update()
		Properties.Refresh()
		return true
	end

	Properties.__MCP.SearchClear = function()
		Properties.SearchText = ""
		Properties.Update()
		Properties.Refresh()
		return true
	end

	Properties.__MCP.ExpandCategory = function(categoryName, setExpanded)
		categoryName = tostring(categoryName or "")
		if categoryName == "" then
			return false, "categoryName is empty."
		end
		expanded["CAT_" .. categoryName] = (setExpanded ~= false) and true or nil
		Properties.Update()
		Properties.Refresh()
		return true
	end

	Properties.__MCP.ExpandProperty = function(fullName, setExpanded)
		fullName = tostring(fullName or "")
		if fullName == "" then
			return false, "fullName is empty."
		end
		expanded[fullName] = (setExpanded ~= false) and true or nil
		Properties.Update()
		Properties.Refresh()
		return true
	end

	Properties.__MCP.AttributeUpsert = function(obj, attributeName, attributeValue)
		attributeName = tostring(attributeName or "")
		if attributeName == "" then
			return false, "Attribute name is empty."
		end
		local ok, err = pcall(function()
			obj:SetAttribute(attributeName, attributeValue)
		end)
		if not ok then
			return false, tostring(err)
		end
		Properties.ShowExplorerProps()
		return true
	end

	Properties.__MCP.AttributeRemove = function(obj, attributeName)
		attributeName = tostring(attributeName or "")
		if attributeName == "" then
			return false, "Attribute name is empty."
		end
		local ok, err = pcall(function()
			obj:SetAttribute(attributeName, nil)
		end)
		if not ok then
			return false, tostring(err)
		end
		Properties.ShowExplorerProps()
		return true
	end

	Properties.__MCP.ToggleAttributesVisibility = function(visible)
		if visible == nil then
			Settings.Properties.ShowAttributes = not Settings.Properties.ShowAttributes
		else
			Settings.Properties.ShowAttributes = visible == true
		end
		Properties.ShowExplorerProps()
		return true, Settings.Properties.ShowAttributes
	end

	Properties.__MCP.SoundPreview = function(mode, soundObj)
		mode = tostring(mode or "stop")
		if mode == "play" then
			if typeof(soundObj) ~= "Instance" or not soundObj:IsA("Sound") then
				return false, "soundObj must be a Sound instance."
			end
			Properties.SetSoundPreview(soundObj)
			return true
		end
		if mode == "pause" or mode == "stop" then
			Properties.SetSoundPreview(false)
			return true
		end
		return false, "Unknown sound preview mode: " .. mode
	end
]]

    local scriptViewerBridgeSnippet = [[
	local __mcpOriginalViewScript = ScriptViewer.ViewScript
	ScriptViewer.__MCP = ScriptViewer.__MCP or {}
	ScriptViewer.__MCP.Version = "dex-bridge-2"
	ScriptViewer.__MCP.LastScript = nil
	ScriptViewer.__MCP.LastSource = nil

	local function _mcpCaptureCurrentText()
		if codeFrame then
			local okText, textValue = pcall(function()
				return codeFrame:GetText()
			end)
			if okText and typeof(textValue) == "string" then
				ScriptViewer.__MCP.LastSource = textValue
				return textValue
			end
		end
		return ScriptViewer.__MCP.LastSource
	end

	ScriptViewer.ViewScript = function(scr)
		ScriptViewer.__MCP.LastScript = scr
		__mcpOriginalViewScript(scr)
		_mcpCaptureCurrentText()
	end

	ScriptViewer.__MCP.OpenScript = function(scr)
		if typeof(scr) ~= "Instance" or not scr:IsA("LuaSourceContainer") then
			return false, "Target must be a LuaSourceContainer."
		end
		ScriptViewer.ViewScript(scr)
		return true
	end

	ScriptViewer.__MCP.GetCurrentText = function()
		return _mcpCaptureCurrentText()
	end

	ScriptViewer.__MCP.GetCurrentScript = function()
		return ScriptViewer.__MCP.LastScript
	end

	ScriptViewer.__MCP.CopyCurrentText = function()
		if not setclipboard then
			return false, "setclipboard is unavailable."
		end
		local source = ScriptViewer.__MCP.GetCurrentText()
		if typeof(source) ~= "string" or source == "" then
			return false, "Script Viewer buffer is empty."
		end
		setclipboard(source)
		return true, #source
	end

	ScriptViewer.__MCP.SaveCurrentText = function(filePath)
		if not writefile then
			return false, "writefile is unavailable."
		end
		local source = ScriptViewer.__MCP.GetCurrentText()
		if typeof(source) ~= "string" or source == "" then
			return false, "Script Viewer buffer is empty."
		end
		local resolvedPath = tostring(filePath or ("dex/saved/script_viewer_" .. tostring(os.time()) .. ".lua"))
		writefile(resolvedPath, source)
		return true, resolvedPath
	end
]]

    local patchedSource = rawSource

    local explorerCount
    patchedSource, explorerCount = ReplaceOnce(
        patchedSource,
        "return Explorer%s*end%s*%-%- TODO: Remove when open source",
        explorerBridgeSnippet .. "\n\treturn Explorer\nend\n\n-- TODO: Remove when open source"
    )
    if explorerCount == 0 then
        return nil, "Failed to patch Explorer module return block."
    end

    local propertiesCount
    patchedSource, propertiesCount = ReplaceOnce(
        patchedSource,
        "return Properties%s*end%s*%-%- TODO: Remove when open source",
        propertiesBridgeSnippet .. "\n\treturn Properties\nend\n\n-- TODO: Remove when open source"
    )
    if propertiesCount == 0 then
        return nil, "Failed to patch Properties module return block."
    end

    local scriptViewerCount
    patchedSource, scriptViewerCount = ReplaceOnce(
        patchedSource,
        "return ScriptViewer%s*end%s*%-%- TODO: Remove when open source",
        scriptViewerBridgeSnippet .. "\n\treturn ScriptViewer\nend\n\n-- TODO: Remove when open source"
    )
    if scriptViewerCount == 0 then
        return nil, "Failed to patch ScriptViewer module return block."
    end

    local bridgeFooter = string.format([[
do
	local __bridgeEnv = (getgenv and getgenv()) or _G
	local __bridge = __bridgeEnv[%q] or {}
	__bridgeEnv[%q] = __bridge

	__bridge.version = %q
	__bridge.main = Main
	__bridge.apps = Main and Main.Apps or nil
	__bridge.settings = Settings
	__bridge.api = API
	__bridge.rmd = RMD

	local __apps = __bridge.apps
	local __explorer = __apps and __apps.Explorer
	local __properties = __apps and __apps.Properties
	local __scriptViewer = __apps and __apps.ScriptViewer

	local __ready = typeof(__explorer) == "table"
		and typeof(__properties) == "table"
		and typeof(__scriptViewer) == "table"
		and typeof(__explorer.__MCP) == "table"
		and typeof(__properties.__MCP) == "table"
		and typeof(__scriptViewer.__MCP) == "table"

	__bridge.ready = __ready
	__bridge.status = __ready and "ready" or "fallback"
	__bridge.message = __ready and "Dex bridge initialized." or "Dex loaded, but bridge hooks were only partially initialized."

	__bridge.mainMCP = __bridge.mainMCP or {}
	local __mainMCP = __bridge.mainMCP

	local function __mcpResolveAppName(name)
		name = tostring(name or "")
		if name == "Explorer" then
			return "Explorer"
		end
		if name == "Properties" then
			return "Properties"
		end
		if name == "Script Viewer" or name == "ScriptViewer" or name == "Script_Viewer" then
			return "Script Viewer"
		end
		return nil
	end

	__mainMCP.GetMenuOpen = function()
		if not Main or not Main.MainGui then
			return nil
		end
		local openButton = Main.MainGui:FindFirstChild("OpenButton")
		if not openButton then
			return nil
		end
		return tostring(openButton.Text or "") == "X"
	end

	__mainMCP.SetMenuOpen = function(open)
		if not Main or typeof(Main.SetMainGuiOpen) ~= "function" then
			return false, "Main.SetMainGuiOpen is unavailable."
		end
		Main.SetMainGuiOpen(open == true)
		return true, __mainMCP.GetMenuOpen()
	end

	__mainMCP.SetAppOpen = function(appName, open)
		if not Main or typeof(Main.MenuApps) ~= "table" then
			return false, "Main menu app controls are unavailable."
		end
		local resolved = __mcpResolveAppName(appName)
		if not resolved then
			return false, "Unknown app name."
		end
		local control = Main.MenuApps[resolved]
		if typeof(control) ~= "table" then
			return false, "App control is unavailable: " .. tostring(resolved)
		end
		if open == true then
			if typeof(control.Enable) ~= "function" then
				return false, "Enable handler is unavailable for app: " .. tostring(resolved)
			end
			control.Enable()
		else
			if typeof(control.Disable) ~= "function" then
				return false, "Disable handler is unavailable for app: " .. tostring(resolved)
			end
			control.Disable()
		end
		return true, resolved
	end

	__mainMCP.FocusWindow = function(appName)
		local resolved = __mcpResolveAppName(appName)
		if not resolved then
			return false, "Unknown app name."
		end

		local appObj
		if resolved == "Explorer" then
			appObj = __explorer
		elseif resolved == "Properties" then
			appObj = __properties
		else
			appObj = __scriptViewer
		end

		local window = appObj and appObj.Window
		if not window then
			return false, "Window is unavailable for app: " .. tostring(resolved)
		end

		if typeof(window.ShowAndFocus) == "function" then
			window:ShowAndFocus()
		elseif typeof(window.Show) == "function" then
			window:Show()
		else
			return false, "Window focus/show handlers are unavailable for app: " .. tostring(resolved)
		end
		return true, resolved
	end

	__mainMCP.GetSettings = function(path)
		if typeof(Settings) ~= "table" then
			return nil, "Dex Settings table is unavailable."
		end
		if path == nil or path == "" then
			return Settings
		end

		local cur = Settings
		local parts = string.split(tostring(path), ".")
		for i = 1,#parts do
			local key = parts[i]
			if typeof(cur) ~= "table" then
				return nil, "Invalid settings path at '" .. tostring(key) .. "'."
			end
			cur = cur[key]
			if cur == nil then
				return nil, "Settings path not found: " .. tostring(path)
			end
		end
		return cur
	end

	__mainMCP.SetSetting = function(path, value)
		path = tostring(path or "")
		if path == "" then
			return false, "Settings path is empty."
		end
		if typeof(Settings) ~= "table" then
			return false, "Dex Settings table is unavailable."
		end

		local parts = string.split(path, ".")
		if #parts == 0 then
			return false, "Settings path is invalid."
		end

		local cur = Settings
		for i = 1,#parts - 1 do
			local key = parts[i]
			if typeof(cur[key]) ~= "table" then
				return false, "Settings path is invalid at '" .. tostring(key) .. "'."
			end
			cur = cur[key]
		end

		cur[parts[#parts]] = value
		return true
	end

	__mainMCP.ResetSettings = function()
		if not Main or typeof(Main.ResetSettings) ~= "function" then
			return false, "Main.ResetSettings is unavailable."
		end
		Main.ResetSettings()
		return true
	end
end
]], DEX_BRIDGE_KEY, DEX_BRIDGE_KEY, DEX_BRIDGE_VERSION)

    return patchedSource .. "\n\n" .. bridgeFooter, nil
end

local function FetchDexSource()
    if DexSourceCache then
        return DexSourceCache
    end

    local source = game:HttpGet(DEX_SCRIPT_URL)
    assert(typeof(source) == "string" and #source > 0, "Dex source download returned an empty payload.")
    DexSourceCache = source
    return source
end

local function RunDexInjectedSource()
    local okFetch, rawOrErr = pcall(FetchDexSource)
    if not okFetch then
        SetDexBridgeRuntimeState("patch_failed", "Failed to fetch Dex source: " .. tostring(rawOrErr))
        return false, tostring(rawOrErr)
    end

    local patchedSource, patchErr = PatchDexSource(rawOrErr)
    if not patchedSource then
        SetDexBridgeRuntimeState("patch_failed", "Failed to patch Dex source: " .. tostring(patchErr))
        return false, tostring(patchErr)
    end

    local chunk, compileErr = loadstring(patchedSource)
    if not chunk then
        SetDexBridgeRuntimeState("patch_failed", "Failed to compile patched Dex source: " .. tostring(compileErr))
        return false, tostring(compileErr)
    end

    local bridgeEnv = GetBridgeEnv()
    bridgeEnv[DEX_BRIDGE_KEY] = nil

    local okRun, runErr = pcall(chunk)
    if not okRun then
        SetDexBridgeRuntimeState("patch_failed", "Failed to execute patched Dex source: " .. tostring(runErr))
        return false, tostring(runErr)
    end

    local _, bridgeStatus, bridgeMessage = GetDexBridgeStatus()
    if bridgeStatus == "ready" then
        SetDexBridgeRuntimeState("ready", bridgeMessage)
    else
        SetDexBridgeRuntimeState("fallback", bridgeMessage)
    end

    return true, nil
end

local function BuildDexTreeRows(includeAll, includeSearchOnly)
    local bridge, bridgeStatus, bridgeMessage = GetDexBridgeStatus()
    local bridgeApps = bridge and bridge.apps
    local explorer = bridgeApps and bridgeApps.Explorer
    local mcp = explorer and explorer.__MCP

    if bridgeStatus == "ready" and typeof(mcp) == "table" and typeof(mcp.GetTreeRows) == "function" then
        local okRows, rowsOrErr = pcall(mcp.GetTreeRows, {
            includeAll = includeAll == true,
            includeSearchOnly = includeSearchOnly == true,
            includeNilRoot = true
        })
        if okRows and typeof(rowsOrErr) == "table" then
            local rows = {}
            for i = 1,#rowsOrErr do
                local rawRow = rowsOrErr[i]
                if typeof(rawRow) ~= "table" then continue end
                if typeof(rawRow.Node) ~= "table" then continue end
                if typeof(rawRow.Node.Obj) ~= "Instance" then continue end

                rows[#rows + 1] = {
                    kind = "dex",
                    Node = rawRow.Node,
                    Object = rawRow.Node.Obj,
                    Depth = tonumber(rawRow.Depth) or 0,
                    Expanded = rawRow.Expanded == true,
                    HasChildren = rawRow.HasChildren == true,
                    IsSearchResult = rawRow.IsSearchResult == true,
                    IsNilRoot = rawRow.IsNilRoot == true
                }
            end
            return rows, "ready", bridgeMessage
        end
    end

    local fallbackRows = {}
    local function walk(instance, depth)
        local children = instance:GetChildren()
        fallbackRows[#fallbackRows + 1] = {
            kind = "fallback",
            Node = nil,
            Object = instance,
            Depth = depth,
            Expanded = nil,
            HasChildren = #children > 0,
            IsSearchResult = nil,
            IsNilRoot = false
        }

        for i = 1,#children do
            walk(children[i], depth + 1)
        end
    end
    walk(game, 0)

    local fallbackStatus = (bridgeStatus == "patch_failed") and "patch_failed" or "fallback"
    local fallbackMessage = "Dex bridge tree reader unavailable. Returned fallback hierarchy snapshot."
    if bridgeMessage ~= nil and bridgeMessage ~= "" then
        fallbackMessage = fallbackMessage .. " " .. bridgeMessage
    end
    return fallbackRows, fallbackStatus, fallbackMessage
end

local function ConvertTreeRowToOutput(rawRow)
    local obj = rawRow.Object
    local debugId = nil
    local childCount = 0
    local okDebug, debugValue = pcall(function()
        return obj:GetDebugId()
    end)
    if okDebug then
        debugId = debugValue
    end
    local okChildCount, childCountValue = pcall(function()
        return #obj:GetChildren()
    end)
    if okChildCount then
        childCount = childCountValue
    end

    return {
        name = obj.Name,
        className = obj.ClassName,
        path = SafePathFromInstance(obj),
        debugId = debugId,
        depth = rawRow.Depth or 0,
        expanded = rawRow.Expanded,
        hasChildren = rawRow.HasChildren == true,
        childCount = childCount,
        isSearchResult = rawRow.IsSearchResult == true,
        isNilRoot = rawRow.IsNilRoot == true
    }
end

local function BuildFallbackPropertyRows(target, search, includeTags)
    local rows = {}
    local bridge = GetDexBridge()
    local api = bridge and bridge.api
    local found = {}

    if typeof(api) == "table" and typeof(api.Classes) == "table" then
        local classData = api.Classes[target.ClassName]
        while classData do
            local members = classData.Members
            if typeof(members) == "table" then
                for i = 1,#members do
                    local member = members[i]
                    if typeof(member) ~= "table" then continue end
                    if member.MemberType ~= "Property" then continue end

                    local propertyName = tostring(member.Name or "")
                    if propertyName == "" or found[propertyName] then
                        continue
                    end
                    found[propertyName] = true

                    local valueOk, valueOrErr = pcall(function()
                        return target[propertyName]
                    end)

                    local row = {
                        category = tostring(member.Category or "Data"),
                        name = propertyName,
                        displayName = propertyName,
                        type = (typeof(member.ValueType) == "table" and tostring(member.ValueType.Name or "unknown")) or tostring(member.ValueType or "unknown"),
                        value = valueOk and valueOrErr or nil,
                        readable = valueOk,
                        readableValue = valueOk and tostring(valueOrErr) or "<unreadable>",
                        source = "fallback_api"
                    }
                    if includeTags then
                        row.tags = member.Tags or {}
                    end

                    if search == ""
                        or ContainsCaseInsensitive(row.name, search)
                        or ContainsCaseInsensitive(row.displayName, search)
                        or ContainsCaseInsensitive(row.category, search)
                        or ContainsCaseInsensitive(row.type, search) then
                        rows[#rows + 1] = row
                    end
                end
            end

            classData = classData.Superclass
        end
    end

    if #rows == 0 then
        local attrs = {}
        local okAttrs, attrsData = pcall(function()
            return game.GetAttributes(target)
        end)
        if okAttrs and typeof(attrsData) == "table" then
            attrs = attrsData
        end

        local commonRows = {
            { category = "Data", name = "Name", type = "string", value = target.Name },
            { category = "Data", name = "ClassName", type = "string", value = target.ClassName },
            { category = "Data", name = "Parent", type = "Instance", value = target.Parent },
            { category = "Data", name = "Archivable", type = "boolean", value = target.Archivable },
            { category = "Attributes", name = "Attributes", type = "table", value = attrs },
        }

        for i = 1,#commonRows do
            local row = commonRows[i]
            row.displayName = row.name
            row.readable = true
            row.readableValue = tostring(row.value)
            row.source = "fallback_common"
            if includeTags then
                row.tags = {}
            end

            if search == ""
                or ContainsCaseInsensitive(row.name, search)
                or ContainsCaseInsensitive(row.displayName, search)
                or ContainsCaseInsensitive(row.category, search)
                or ContainsCaseInsensitive(row.type, search) then
                rows[#rows + 1] = row
            end
        end
    end

    return rows
end

local DEX_ACTIONS = {
    "explorer.select.replace",
    "explorer.select.add",
    "explorer.select.remove",
    "explorer.select.clear",
    "explorer.search.set",
    "explorer.search.clear",
    "explorer.expand.all",
    "explorer.collapse.all",
    "explorer.jump_to_parent",
    "explorer.select_children",
    "explorer.rename",
    "explorer.cut",
    "explorer.copy",
    "explorer.paste_into",
    "explorer.duplicate",
    "explorer.delete",
    "explorer.group",
    "explorer.ungroup",
    "explorer.reparent",
    "explorer.insert_object",
    "explorer.copy_path",
    "explorer.call_function",
    "explorer.get_lua_references",
    "explorer.save_instance",
    "explorer.view_connections",
    "explorer.view_api",
    "explorer.view_object",
    "explorer.view_script",
    "explorer.select_character",
    "explorer.refresh_nil",
    "explorer.hide_nil.toggle",
    "explorer.teleport_to",
    "properties.select_target",
    "properties.search.set",
    "properties.search.clear",
    "properties.set",
    "properties.set_batch",
    "properties.clear_value",
    "properties.expand_category",
    "properties.expand_property",
    "properties.attributes.add",
    "properties.attributes.edit",
    "properties.attributes.remove",
    "properties.attributes.toggle_visibility",
    "properties.sound_preview.play",
    "properties.sound_preview.pause",
    "properties.sound_preview.stop",
    "script_viewer.open",
    "script_viewer.get_text",
    "script_viewer.copy_text",
    "script_viewer.save_to_file",
    "main.menu.set_open",
    "main.app.set_open",
    "main.window.focus",
    "main.settings.get",
    "main.settings.set",
    "main.settings.reset",
}

local DEX_ACTION_SET = {}
for i = 1,#DEX_ACTIONS do
    DEX_ACTION_SET[DEX_ACTIONS[i]] = true
end

local DEX_ACTION_PAYLOAD_KEYS = {
    ["explorer.rename"] = {"name"},
    ["explorer.insert_object"] = {"className"},
    ["explorer.call_function"] = {"args"},
    ["explorer.save_instance"] = {"filePath"},
    ["explorer.reparent"] = {"newParentPath"},
    ["explorer.search.set"] = {"query"},
    ["properties.search.set"] = {"query"},
    ["properties.set"] = {"name", "value|valueRaw"},
    ["properties.set_batch"] = {"patches"},
    ["properties.clear_value"] = {"name"},
    ["properties.expand_category"] = {"categoryName"},
    ["properties.expand_property"] = {"fullName"},
    ["properties.attributes.add"] = {"name", "value"},
    ["properties.attributes.edit"] = {"name", "value"},
    ["properties.attributes.remove"] = {"name"},
    ["properties.attributes.toggle_visibility"] = {"visible?"},
    ["script_viewer.save_to_file"] = {"filePath?"},
    ["main.menu.set_open"] = {"open"},
    ["main.app.set_open"] = {"appName", "open"},
    ["main.window.focus"] = {"appName"},
    ["main.settings.get"] = {"path?"},
    ["main.settings.set"] = {"path", "value"},
}

local DEX_WRITE_ACTION_SET = {
    ["explorer.select.replace"] = true,
    ["explorer.select.add"] = true,
    ["explorer.select.remove"] = true,
    ["explorer.select.clear"] = true,
    ["explorer.search.set"] = true,
    ["explorer.search.clear"] = true,
    ["explorer.expand.all"] = true,
    ["explorer.collapse.all"] = true,
    ["explorer.jump_to_parent"] = true,
    ["explorer.select_children"] = true,
    ["explorer.rename"] = true,
    ["explorer.cut"] = true,
    ["explorer.copy"] = true,
    ["explorer.paste_into"] = true,
    ["explorer.duplicate"] = true,
    ["explorer.delete"] = true,
    ["explorer.group"] = true,
    ["explorer.ungroup"] = true,
    ["explorer.reparent"] = true,
    ["explorer.insert_object"] = true,
    ["explorer.copy_path"] = true,
    ["explorer.call_function"] = true,
    ["explorer.get_lua_references"] = true,
    ["explorer.save_instance"] = true,
    ["explorer.view_connections"] = true,
    ["explorer.view_api"] = true,
    ["explorer.view_object"] = true,
    ["explorer.view_script"] = true,
    ["explorer.select_character"] = true,
    ["explorer.refresh_nil"] = true,
    ["explorer.hide_nil.toggle"] = true,
    ["explorer.teleport_to"] = true,
    ["properties.select_target"] = true,
    ["properties.search.set"] = true,
    ["properties.search.clear"] = true,
    ["properties.set"] = true,
    ["properties.set_batch"] = true,
    ["properties.clear_value"] = true,
    ["properties.expand_category"] = true,
    ["properties.expand_property"] = true,
    ["properties.attributes.add"] = true,
    ["properties.attributes.edit"] = true,
    ["properties.attributes.remove"] = true,
    ["properties.attributes.toggle_visibility"] = true,
    ["properties.sound_preview.play"] = true,
    ["properties.sound_preview.pause"] = true,
    ["properties.sound_preview.stop"] = true,
    ["script_viewer.open"] = true,
    ["script_viewer.copy_text"] = true,
    ["script_viewer.save_to_file"] = true,
    ["main.menu.set_open"] = true,
    ["main.app.set_open"] = true,
    ["main.window.focus"] = true,
    ["main.settings.set"] = true,
    ["main.settings.reset"] = true,
}

local function IsDexWriteAction(action)
    return DEX_WRITE_ACTION_SET[action] == true
end

local function GetDexBridgeModules()
    local bridge, bridgeStatus, bridgeMessage = GetDexBridgeStatus()
    local bridgeReady = bridgeStatus == "ready" and bridge ~= nil
    local apps = bridge and bridge.apps
    local explorer = apps and apps.Explorer
    local properties = apps and apps.Properties
    local scriptViewer = apps and apps.ScriptViewer
    local mainMCP = bridge and bridge.mainMCP
    return {
        bridge = bridge,
        bridgeReady = bridgeReady,
        bridgeStatus = bridgeStatus,
        bridgeMessage = bridgeMessage,
        apps = apps,
        explorer = explorer,
        explorerMCP = explorer and explorer.__MCP,
        properties = properties,
        propertiesMCP = properties and properties.__MCP,
        scriptViewer = scriptViewer,
        scriptViewerMCP = scriptViewer and scriptViewer.__MCP,
        mainMCP = mainMCP,
    }
end

local function CaptureDexSnapshot()
    local modules = GetDexBridgeModules()
    local mainMenu, location = FindDexMainMenu()
    local menuOpen, menuButtonText = GetDexMenuOpenState(mainMenu)

    local selectionCount = 0
    local searchText = ""
    if typeof(modules.explorerMCP) == "table" and typeof(modules.explorerMCP.GetSelectionCount) == "function" then
        local okCount, count = pcall(modules.explorerMCP.GetSelectionCount)
        if okCount and tonumber(count) then
            selectionCount = tonumber(count)
        end
    end
    if typeof(modules.explorerMCP) == "table" and typeof(modules.explorerMCP.GetSearchText) == "function" then
        local okSearch, value = pcall(modules.explorerMCP.GetSearchText)
        if okSearch and typeof(value) == "string" then
            searchText = value
        end
    end

    return {
        loaded = mainMenu ~= nil,
        location = location,
        menuOpen = menuOpen,
        menuButtonText = menuButtonText,
        selectionCount = selectionCount,
        searchText = searchText,
        bridgeReady = modules.bridgeReady,
        bridgeStatus = modules.bridgeStatus,
        bridgeVersion = modules.bridge and modules.bridge.version or nil,
    }
end

local function DidSnapshotChange(before, after)
    if not before or not after then
        return false
    end
    return before.loaded ~= after.loaded
        or before.location ~= after.location
        or before.menuOpen ~= after.menuOpen
        or before.menuButtonText ~= after.menuButtonText
        or before.selectionCount ~= after.selectionCount
        or before.searchText ~= after.searchText
        or before.bridgeReady ~= after.bridgeReady
        or before.bridgeStatus ~= after.bridgeStatus
end

local function BuildDexActionResult(action, changed, message, modules, data, beforeSnapshot, afterSnapshot, errorCode)
    local status = errorCode and "error" or "ok"
    return {
        status = status,
        action = action,
        changed = changed == true,
        bridgeReady = modules.bridgeReady,
        bridgeStatus = modules.bridgeStatus,
        message = tostring(message or ""),
        data = data,
        before = beforeSnapshot,
        after = afterSnapshot,
        errorCode = errorCode,
    }
end

local function BuildDexActionError(action, errorCode, message, modules, beforeSnapshot, returnSnapshot, nextStep)
    local data = {}
    if typeof(nextStep) == "string" and nextStep ~= "" then
        data.nextStep = nextStep
    end
    local afterSnapshot = returnSnapshot and CaptureDexSnapshot() or nil
    return BuildDexActionResult(action, false, message, modules, data, beforeSnapshot, afterSnapshot, errorCode)
end

local function SummarizeInstance(obj)
    if typeof(obj) ~= "Instance" then
        return nil
    end
    local debugId = nil
    local okDebug, debugValue = pcall(function()
        return obj:GetDebugId()
    end)
    if okDebug then
        debugId = debugValue
    end
    return {
        name = obj.Name,
        className = obj.ClassName,
        path = SafePathFromInstance(obj),
        debugId = debugId,
    }
end

local function GetSelectedObjectsForAction(modules)
    local explorerMCP = modules.explorerMCP
    if typeof(explorerMCP) ~= "table" or typeof(explorerMCP.GetSelectionObjects) ~= "function" then
        return nil, "Dex selection API is unavailable."
    end
    local okSelection, objectsOrErr = pcall(explorerMCP.GetSelectionObjects)
    if not okSelection or typeof(objectsOrErr) ~= "table" then
        return nil, "Failed to read Dex selection."
    end
    return objectsOrErr, nil
end

local function ResolveObjectsFromActionRequest(req, modules, options)
    options = options or {}
    local allowEmpty = options.allowEmpty == true
    local fallbackToSelection = options.fallbackToSelection == true

    local objects = {}

    if typeof(req.instancePaths) == "table" and #req.instancePaths > 0 then
        for i = 1,#req.instancePaths do
            local rawPath = req.instancePaths[i]
            if typeof(rawPath) ~= "string" or rawPath == "" then
                return nil, "instancePaths contains an empty value."
            end
            local obj, err = ResolveInstancePath(rawPath)
            if not obj then
                return nil, err
            end
            objects[#objects + 1] = obj
        end
    elseif typeof(req.instancePath) == "string" and req.instancePath ~= "" then
        local obj, err = ResolveInstancePath(req.instancePath)
        if not obj then
            return nil, err
        end
        objects[#objects + 1] = obj
    elseif typeof(req.selectionIndices) == "table" and #req.selectionIndices > 0 then
        local selected, selErr = GetSelectedObjectsForAction(modules)
        if not selected then
            return nil, selErr
        end
        for i = 1,#req.selectionIndices do
            local idx = ClampInt(req.selectionIndices[i], 1, math.max(1, #selected), 1)
            local obj = selected[idx]
            if typeof(obj) == "Instance" then
                objects[#objects + 1] = obj
            end
        end
    elseif req.selectionIndex ~= nil then
        local selected, selErr = GetSelectedObjectsForAction(modules)
        if not selected then
            return nil, selErr
        end
        if #selected == 0 then
            return nil, "Dex selection is empty."
        end
        local idx = ClampInt(req.selectionIndex, 1, #selected, 1)
        local obj = selected[idx]
        if typeof(obj) == "Instance" then
            objects[#objects + 1] = obj
        end
    elseif fallbackToSelection then
        local selected, selErr = GetSelectedObjectsForAction(modules)
        if not selected then
            return nil, selErr
        end
        for i = 1,#selected do
            if typeof(selected[i]) == "Instance" then
                objects[#objects + 1] = selected[i]
            end
        end
    end

    if #objects == 0 and not allowEmpty then
        return nil, "No target instances resolved. Provide instancePath/instancePaths or select a target in Dex."
    end

    return objects, nil
end

local function EnsureBridgeMethod(container, methodName, subsystemLabel)
    if typeof(container) ~= "table" or typeof(container[methodName]) ~= "function" then
        return nil, subsystemLabel .. " bridge method '" .. tostring(methodName) .. "' is unavailable."
    end
    return container[methodName], nil
end

local function ExecuteDexAction(req)
    local action = tostring(req.action or "")
    local options = req.options or {}
    local returnSnapshot = options.returnSnapshot ~= false
    local requireBridgeReady = options.requireBridgeReady ~= false
    local payload = req.payload or {}
    if typeof(payload) ~= "table" then
        payload = {}
    end

    local modules = GetDexBridgeModules()
    local beforeSnapshot = returnSnapshot and CaptureDexSnapshot() or nil

    if action == "" then
        return BuildDexActionError(
            action,
            "invalid_action",
            "action is required.",
            modules,
            beforeSnapshot,
            returnSnapshot,
            "Choose an action from dex-list-capabilities."
        )
    end
    if not DEX_ACTION_SET[action] then
        return BuildDexActionError(
            action,
            "invalid_action",
            "Unsupported action: " .. action,
            modules,
            beforeSnapshot,
            returnSnapshot,
            "Call dex-list-capabilities to inspect supported actions."
        )
    end
    if requireBridgeReady and not modules.bridgeReady then
        return BuildDexActionError(
            action,
            "bridge_not_ready",
            "Dex bridge is not ready.",
            modules,
            beforeSnapshot,
            returnSnapshot,
            "Call ensure-dex first, then retry."
        )
    end
    if IsDexWriteAction(action) and not modules.bridgeReady then
        return BuildDexActionError(
            action,
            "bridge_not_ready",
            "This action requires bridgeStatus=ready.",
            modules,
            beforeSnapshot,
            returnSnapshot,
            "Call ensure-dex and confirm bridgeStatus=ready."
        )
    end

    local changed = false
    local message = "Action completed."
    local data = {}

    if string.sub(action, 1, 9) == "explorer." then
        local explorerMCP = modules.explorerMCP
        if typeof(explorerMCP) ~= "table" then
            return BuildDexActionError(action, "bridge_not_ready", "Dex Explorer bridge is unavailable.", modules, beforeSnapshot, returnSnapshot, "Call ensure-dex again.")
        end

        if action == "explorer.select.replace" or action == "explorer.select.add" or action == "explorer.select.remove" then
            local mode = string.sub(action, 17)
            local selectMethod, methodErr = EnsureBridgeMethod(explorerMCP, "SelectObjects", "Explorer")
            if not selectMethod then
                return BuildDexActionError(action, "action_failed", methodErr, modules, beforeSnapshot, returnSnapshot, "Re-run ensure-dex.")
            end
            local objects, resolveErr = ResolveObjectsFromActionRequest(req, modules, {allowEmpty = false})
            if not objects then
                return BuildDexActionError(action, "target_not_found", resolveErr, modules, beforeSnapshot, returnSnapshot, "Provide instancePath or choose a Dex selection.")
            end
            local okCall, methodResult = pcall(selectMethod, objects, mode)
            if not okCall then
                return BuildDexActionError(action, "action_failed", tostring(methodResult), modules, beforeSnapshot, returnSnapshot, "Verify targets are visible in Dex Explorer.")
            end
            changed = true
            message = "Explorer selection updated."
            data.mode = mode
            data.targetCount = #objects
            data.targets = {}
            for i = 1,#objects do
                data.targets[#data.targets + 1] = SummarizeInstance(objects[i])
            end
        elseif action == "explorer.select.clear" then
            local method, methodErr = EnsureBridgeMethod(explorerMCP, "ClearSelection", "Explorer")
            if not method then
                return BuildDexActionError(action, "action_failed", methodErr, modules, beforeSnapshot, returnSnapshot, "")
            end
            local okCall, resultOrErr = pcall(method)
            if not okCall then
                return BuildDexActionError(action, "action_failed", tostring(resultOrErr), modules, beforeSnapshot, returnSnapshot, "")
            end
            changed = resultOrErr == true
            message = "Explorer selection cleared."
        elseif action == "explorer.search.set" then
            local method, methodErr = EnsureBridgeMethod(explorerMCP, "SearchSet", "Explorer")
            if not method then
                return BuildDexActionError(action, "action_failed", methodErr, modules, beforeSnapshot, returnSnapshot, "")
            end
            local query = tostring(payload.query or payload.text or "")
            local okCall, resultOrErr = pcall(method, query)
            if not okCall or resultOrErr == false then
                return BuildDexActionError(action, "action_failed", okCall and tostring(resultOrErr) or tostring(resultOrErr), modules, beforeSnapshot, returnSnapshot, "")
            end
            changed = true
            message = "Explorer search updated."
            data.query = query
        elseif action == "explorer.search.clear" then
            local method, methodErr = EnsureBridgeMethod(explorerMCP, "SearchClear", "Explorer")
            if not method then
                return BuildDexActionError(action, "action_failed", methodErr, modules, beforeSnapshot, returnSnapshot, "")
            end
            local okCall, resultOrErr = pcall(method)
            if not okCall or resultOrErr == false then
                return BuildDexActionError(action, "action_failed", okCall and tostring(resultOrErr) or tostring(resultOrErr), modules, beforeSnapshot, returnSnapshot, "")
            end
            changed = true
            message = "Explorer search cleared."
        elseif action == "explorer.expand.all" or action == "explorer.collapse.all" then
            local methodName = action == "explorer.expand.all" and "ExpandAll" or "CollapseAll"
            local method, methodErr = EnsureBridgeMethod(explorerMCP, methodName, "Explorer")
            if not method then
                return BuildDexActionError(action, "action_failed", methodErr, modules, beforeSnapshot, returnSnapshot, "")
            end
            local okCall, okResult, methodErrMsg = pcall(method)
            if not okCall or okResult == false then
                return BuildDexActionError(action, "action_failed", tostring(methodErrMsg or okResult), modules, beforeSnapshot, returnSnapshot, "")
            end
            changed = true
            message = action == "explorer.expand.all" and "Explorer expanded all selected nodes." or "Explorer collapsed all selected nodes."
        elseif action == "explorer.jump_to_parent" or action == "explorer.select_children" then
            local methodName = action == "explorer.jump_to_parent" and "JumpToParent" or "SelectChildren"
            local method, methodErr = EnsureBridgeMethod(explorerMCP, methodName, "Explorer")
            if not method then
                return BuildDexActionError(action, "action_failed", methodErr, modules, beforeSnapshot, returnSnapshot, "")
            end
            local okCall, okResult, resultOrErr = pcall(method)
            if not okCall or okResult == false then
                return BuildDexActionError(action, "action_failed", tostring(resultOrErr or okResult), modules, beforeSnapshot, returnSnapshot, "")
            end
            changed = true
            message = action == "explorer.jump_to_parent" and "Explorer selection moved to parent." or "Explorer selected child nodes."
            data.count = tonumber(resultOrErr) or nil
        elseif action == "explorer.rename" then
            local method, methodErr = EnsureBridgeMethod(explorerMCP, "Rename", "Explorer")
            if not method then
                return BuildDexActionError(action, "action_failed", methodErr, modules, beforeSnapshot, returnSnapshot, "")
            end
            local name = tostring(payload.name or "")
            if name == "" then
                return BuildDexActionError(action, "invalid_payload", "payload.name is required.", modules, beforeSnapshot, returnSnapshot, "Provide payload.name for explorer.rename.")
            end
            local okCall, okResult, errOrName = pcall(method, name)
            if not okCall or okResult == false then
                return BuildDexActionError(action, "action_failed", tostring(errOrName), modules, beforeSnapshot, returnSnapshot, "")
            end
            changed = true
            message = "Explorer rename succeeded."
            data.name = errOrName or name
        elseif action == "explorer.cut" or action == "explorer.copy" or action == "explorer.duplicate" or action == "explorer.delete"
            or action == "explorer.group" or action == "explorer.ungroup" then
            local methodMap = {
                ["explorer.cut"] = "Cut",
                ["explorer.copy"] = "Copy",
                ["explorer.duplicate"] = "Duplicate",
                ["explorer.delete"] = "Delete",
                ["explorer.group"] = "Group",
                ["explorer.ungroup"] = "Ungroup",
            }
            local methodName = methodMap[action]
            local method, methodErr = EnsureBridgeMethod(explorerMCP, methodName, "Explorer")
            if not method then
                return BuildDexActionError(action, "action_failed", methodErr, modules, beforeSnapshot, returnSnapshot, "")
            end
            local okCall, okResult, info = pcall(method)
            if not okCall or okResult == false then
                return BuildDexActionError(action, "action_failed", tostring(info or okResult), modules, beforeSnapshot, returnSnapshot, "")
            end
            changed = true
            message = "Explorer action completed: " .. action
            if typeof(info) == "Instance" then
                data.result = SummarizeInstance(info)
            else
                data.result = info
            end
        elseif action == "explorer.paste_into" then
            local method, methodErr = EnsureBridgeMethod(explorerMCP, "PasteInto", "Explorer")
            if not method then
                return BuildDexActionError(action, "action_failed", methodErr, modules, beforeSnapshot, returnSnapshot, "")
            end
            local targets, resolveErr = ResolveObjectsFromActionRequest(req, modules, {allowEmpty = true, fallbackToSelection = false})
            if not targets then
                return BuildDexActionError(action, "target_not_found", resolveErr, modules, beforeSnapshot, returnSnapshot, "Provide target instancePath(s) or select destination in Dex.")
            end
            local okCall, okResult, pastedCount = pcall(method, targets)
            if not okCall or okResult == false then
                return BuildDexActionError(action, "action_failed", tostring(pastedCount or okResult), modules, beforeSnapshot, returnSnapshot, "")
            end
            changed = true
            message = "Explorer paste completed."
            data.pastedCount = tonumber(pastedCount) or 0
        elseif action == "explorer.reparent" then
            local method, methodErr = EnsureBridgeMethod(explorerMCP, "Reparent", "Explorer")
            if not method then
                return BuildDexActionError(action, "action_failed", methodErr, modules, beforeSnapshot, returnSnapshot, "")
            end
            local newParentPath = tostring(payload.newParentPath or payload.parentPath or "")
            if newParentPath == "" then
                return BuildDexActionError(action, "invalid_payload", "payload.newParentPath is required.", modules, beforeSnapshot, returnSnapshot, "Provide payload.newParentPath.")
            end
            local newParent, parentErr = ResolveInstancePath(newParentPath)
            if not newParent then
                return BuildDexActionError(action, "target_not_found", parentErr, modules, beforeSnapshot, returnSnapshot, "Use a valid parent instancePath.")
            end

            local targets, resolveErr = ResolveObjectsFromActionRequest(req, modules, {allowEmpty = true, fallbackToSelection = true})
            if not targets then
                return BuildDexActionError(action, "target_not_found", resolveErr, modules, beforeSnapshot, returnSnapshot, "")
            end
            if #targets > 0 and typeof(explorerMCP.SelectObjects) == "function" then
                pcall(explorerMCP.SelectObjects, targets, "replace")
            end

            local okCall, okResult, movedCount = pcall(method, newParent)
            if not okCall or okResult == false then
                return BuildDexActionError(action, "action_failed", tostring(movedCount or okResult), modules, beforeSnapshot, returnSnapshot, "")
            end
            changed = true
            message = "Explorer reparent completed."
            data.newParent = SummarizeInstance(newParent)
            data.movedCount = tonumber(movedCount) or 0
        elseif action == "explorer.insert_object" then
            local method, methodErr = EnsureBridgeMethod(explorerMCP, "InsertObject", "Explorer")
            if not method then
                return BuildDexActionError(action, "action_failed", methodErr, modules, beforeSnapshot, returnSnapshot, "")
            end
            local className = tostring(payload.className or "")
            if className == "" then
                return BuildDexActionError(action, "invalid_payload", "payload.className is required.", modules, beforeSnapshot, returnSnapshot, "Provide payload.className.")
            end
            local parentObj = nil
            if typeof(payload.parentPath) == "string" and payload.parentPath ~= "" then
                local pObj, pErr = ResolveInstancePath(payload.parentPath)
                if not pObj then
                    return BuildDexActionError(action, "target_not_found", pErr, modules, beforeSnapshot, returnSnapshot, "")
                end
                parentObj = pObj
            elseif typeof(req.instancePath) == "string" and req.instancePath ~= "" then
                local pObj, pErr = ResolveInstancePath(req.instancePath)
                if not pObj then
                    return BuildDexActionError(action, "target_not_found", pErr, modules, beforeSnapshot, returnSnapshot, "")
                end
                parentObj = pObj
            end
            local okCall, okResult, objOrErr = pcall(method, className, parentObj)
            if not okCall or okResult == false then
                return BuildDexActionError(action, "action_failed", tostring(objOrErr), modules, beforeSnapshot, returnSnapshot, "")
            end
            changed = true
            message = "Explorer inserted object."
            data.inserted = SummarizeInstance(objOrErr)
        elseif action == "explorer.copy_path" or action == "explorer.call_function" or action == "explorer.get_lua_references"
            or action == "explorer.save_instance" or action == "explorer.view_connections" or action == "explorer.view_api"
            or action == "explorer.view_object" or action == "explorer.view_script" or action == "explorer.select_character"
            or action == "explorer.refresh_nil" or action == "explorer.hide_nil.toggle" or action == "explorer.teleport_to" then
            local methodMap = {
                ["explorer.copy_path"] = "CopyPath",
                ["explorer.call_function"] = "CallFunction",
                ["explorer.get_lua_references"] = "GetLuaReferences",
                ["explorer.save_instance"] = "SaveInstance",
                ["explorer.view_connections"] = "ViewConnections",
                ["explorer.view_api"] = "ViewAPI",
                ["explorer.view_object"] = "ViewObject",
                ["explorer.view_script"] = "ViewScript",
                ["explorer.select_character"] = "SelectCharacter",
                ["explorer.refresh_nil"] = "RefreshNil",
                ["explorer.hide_nil.toggle"] = "HideNil",
                ["explorer.teleport_to"] = "TeleportTo",
            }
            local methodName = methodMap[action]
            local method, methodErr = EnsureBridgeMethod(explorerMCP, methodName, "Explorer")
            if not method then
                return BuildDexActionError(action, "action_failed", methodErr, modules, beforeSnapshot, returnSnapshot, "")
            end

            local arg1 = nil
            if action == "explorer.call_function" then
                arg1 = typeof(payload.args) == "table" and payload.args or {}
            elseif action == "explorer.save_instance" then
                arg1 = payload.filePath
            end

            local okCall, okResult, info = pcall(method, arg1)
            if not okCall or okResult == false then
                return BuildDexActionError(action, "action_failed", tostring(info or okResult), modules, beforeSnapshot, returnSnapshot, "")
            end
            changed = true
            message = "Explorer action completed: " .. action
            if typeof(info) == "Instance" then
                data.result = SummarizeInstance(info)
            else
                data.result = info
            end
        else
            return BuildDexActionError(action, "invalid_action", "Unsupported explorer action.", modules, beforeSnapshot, returnSnapshot, "")
        end
    elseif string.sub(action, 1, 11) == "properties." then
        local propertiesMCP = modules.propertiesMCP
        if typeof(propertiesMCP) ~= "table" then
            return BuildDexActionError(action, "bridge_not_ready", "Dex Properties bridge is unavailable.", modules, beforeSnapshot, returnSnapshot, "Call ensure-dex first.")
        end

        if action == "properties.search.set" or action == "properties.search.clear" then
            local methodName = action == "properties.search.set" and "SearchSet" or "SearchClear"
            local method, methodErr = EnsureBridgeMethod(propertiesMCP, methodName, "Properties")
            if not method then
                return BuildDexActionError(action, "action_failed", methodErr, modules, beforeSnapshot, returnSnapshot, "")
            end
            local query = tostring(payload.query or payload.text or "")
            local okCall, okResult = pcall(method, query)
            if not okCall or okResult == false then
                return BuildDexActionError(action, "action_failed", tostring(okResult), modules, beforeSnapshot, returnSnapshot, "")
            end
            changed = true
            message = action == "properties.search.set" and "Properties search updated." or "Properties search cleared."
            data.query = query
        elseif action == "properties.expand_category" or action == "properties.expand_property" then
            local methodName = action == "properties.expand_category" and "ExpandCategory" or "ExpandProperty"
            local method, methodErr = EnsureBridgeMethod(propertiesMCP, methodName, "Properties")
            if not method then
                return BuildDexActionError(action, "action_failed", methodErr, modules, beforeSnapshot, returnSnapshot, "")
            end
            local keyName = action == "properties.expand_category" and tostring(payload.categoryName or "") or tostring(payload.fullName or "")
            if keyName == "" then
                local missingName = action == "properties.expand_category" and "payload.categoryName" or "payload.fullName"
                return BuildDexActionError(action, "invalid_payload", missingName .. " is required.", modules, beforeSnapshot, returnSnapshot, "")
            end
            local setExpanded = payload.expanded
            local okCall, okResult, errOrValue = pcall(method, keyName, setExpanded)
            if not okCall or okResult == false then
                return BuildDexActionError(action, "action_failed", tostring(errOrValue or okResult), modules, beforeSnapshot, returnSnapshot, "")
            end
            changed = true
            message = "Properties expansion updated."
            data.key = keyName
            data.expanded = setExpanded
        elseif action == "properties.attributes.toggle_visibility" then
            local method, methodErr = EnsureBridgeMethod(propertiesMCP, "ToggleAttributesVisibility", "Properties")
            if not method then
                return BuildDexActionError(action, "action_failed", methodErr, modules, beforeSnapshot, returnSnapshot, "")
            end
            local okCall, okResult, visibleOrErr = pcall(method, payload.visible)
            if not okCall or okResult == false then
                return BuildDexActionError(action, "action_failed", tostring(visibleOrErr or okResult), modules, beforeSnapshot, returnSnapshot, "")
            end
            changed = true
            message = "Properties attribute visibility updated."
            data.visible = visibleOrErr
        elseif action == "properties.sound_preview.play" or action == "properties.sound_preview.pause" or action == "properties.sound_preview.stop" then
            local method, methodErr = EnsureBridgeMethod(propertiesMCP, "SoundPreview", "Properties")
            if not method then
                return BuildDexActionError(action, "action_failed", methodErr, modules, beforeSnapshot, returnSnapshot, "")
            end
            local mode = action == "properties.sound_preview.play" and "play" or (action == "properties.sound_preview.pause" and "pause" or "stop")
            local soundObj = nil
            if mode == "play" then
                local resolved, resolveErr = ResolveDexTargetInstance(payload.instancePath or req.instancePath, req.selectionIndex)
                if not resolved then
                    return BuildDexActionError(action, "target_not_found", resolveErr, modules, beforeSnapshot, returnSnapshot, "Provide instancePath to a Sound object.")
                end
                soundObj = resolved
            end
            local okCall, okResult, info = pcall(method, mode, soundObj)
            if not okCall or okResult == false then
                return BuildDexActionError(action, "action_failed", tostring(info or okResult), modules, beforeSnapshot, returnSnapshot, "")
            end
            changed = true
            message = "Properties sound preview updated."
            if typeof(soundObj) == "Instance" then
                data.sound = SummarizeInstance(soundObj)
            end
        else
            local target, resolveErr = ResolveDexTargetInstance(req.instancePath, req.selectionIndex)
            if not target then
                return BuildDexActionError(action, "target_not_found", resolveErr, modules, beforeSnapshot, returnSnapshot, "Provide instancePath or select a Dex item first.")
            end

            if action == "properties.select_target" then
                if typeof(modules.explorerMCP) == "table" and typeof(modules.explorerMCP.SelectObjects) == "function" then
                    pcall(modules.explorerMCP.SelectObjects, {target}, "replace")
                end
                changed = true
                message = "Properties target selected."
                data.target = SummarizeInstance(target)
            elseif action == "properties.set" or action == "properties.clear_value" then
                local method, methodErr = EnsureBridgeMethod(propertiesMCP, "SetProperty", "Properties")
                if not method then
                    return BuildDexActionError(action, "action_failed", methodErr, modules, beforeSnapshot, returnSnapshot, "")
                end
                local propName = tostring(payload.name or "")
                if propName == "" then
                    return BuildDexActionError(action, "invalid_payload", "payload.name is required.", modules, beforeSnapshot, returnSnapshot, "")
                end
                local patchPayload = payload
                if action == "properties.clear_value" then
                    patchPayload = {clear = true}
                end
                local okCall, okResult, errOrNil = pcall(method, target, propName, patchPayload)
                if not okCall or okResult == false then
                    return BuildDexActionError(action, "action_failed", tostring(errOrNil or okResult), modules, beforeSnapshot, returnSnapshot, "")
                end
                changed = true
                message = "Property updated."
                data.target = SummarizeInstance(target)
                data.name = propName
            elseif action == "properties.set_batch" then
                local method, methodErr = EnsureBridgeMethod(propertiesMCP, "SetPropertiesBatch", "Properties")
                if not method then
                    return BuildDexActionError(action, "action_failed", methodErr, modules, beforeSnapshot, returnSnapshot, "")
                end
                local patches = payload.patches
                if typeof(patches) ~= "table" then
                    return BuildDexActionError(action, "invalid_payload", "payload.patches must be an array.", modules, beforeSnapshot, returnSnapshot, "")
                end
                local okCall, applied, errors = pcall(method, target, patches)
                if not okCall then
                    return BuildDexActionError(action, "action_failed", tostring(applied), modules, beforeSnapshot, returnSnapshot, "")
                end
                changed = (tonumber(applied) or 0) > 0
                message = "Batch property update finished."
                data.target = SummarizeInstance(target)
                data.applied = tonumber(applied) or 0
                data.errors = errors or {}
            elseif action == "properties.attributes.add" or action == "properties.attributes.edit" then
                local method, methodErr = EnsureBridgeMethod(propertiesMCP, "AttributeUpsert", "Properties")
                if not method then
                    return BuildDexActionError(action, "action_failed", methodErr, modules, beforeSnapshot, returnSnapshot, "")
                end
                local name = tostring(payload.name or "")
                if name == "" then
                    return BuildDexActionError(action, "invalid_payload", "payload.name is required.", modules, beforeSnapshot, returnSnapshot, "")
                end
                local okCall, okResult, errOrNil = pcall(method, target, name, payload.value)
                if not okCall or okResult == false then
                    return BuildDexActionError(action, "action_failed", tostring(errOrNil or okResult), modules, beforeSnapshot, returnSnapshot, "")
                end
                changed = true
                message = "Attribute upsert completed."
                data.target = SummarizeInstance(target)
                data.name = name
            elseif action == "properties.attributes.remove" then
                local method, methodErr = EnsureBridgeMethod(propertiesMCP, "AttributeRemove", "Properties")
                if not method then
                    return BuildDexActionError(action, "action_failed", methodErr, modules, beforeSnapshot, returnSnapshot, "")
                end
                local name = tostring(payload.name or "")
                if name == "" then
                    return BuildDexActionError(action, "invalid_payload", "payload.name is required.", modules, beforeSnapshot, returnSnapshot, "")
                end
                local okCall, okResult, errOrNil = pcall(method, target, name)
                if not okCall or okResult == false then
                    return BuildDexActionError(action, "action_failed", tostring(errOrNil or okResult), modules, beforeSnapshot, returnSnapshot, "")
                end
                changed = true
                message = "Attribute removed."
                data.target = SummarizeInstance(target)
                data.name = name
            else
                return BuildDexActionError(action, "invalid_action", "Unsupported properties action.", modules, beforeSnapshot, returnSnapshot, "")
            end
        end
    elseif string.sub(action, 1, 14) == "script_viewer." then
        local scriptViewerMCP = modules.scriptViewerMCP
        if typeof(scriptViewerMCP) ~= "table" then
            return BuildDexActionError(action, "bridge_not_ready", "Dex Script Viewer bridge is unavailable.", modules, beforeSnapshot, returnSnapshot, "Call ensure-dex first.")
        end

        if action == "script_viewer.open" then
            local target, resolveErr = ResolveDexTargetInstance(req.instancePath, req.selectionIndex)
            if not target then
                return BuildDexActionError(action, "target_not_found", resolveErr, modules, beforeSnapshot, returnSnapshot, "Provide instancePath to a script instance.")
            end
            if not target:IsA("LuaSourceContainer") then
                return BuildDexActionError(action, "invalid_payload", "Target is not a script instance.", modules, beforeSnapshot, returnSnapshot, "")
            end
            local method, methodErr = EnsureBridgeMethod(scriptViewerMCP, "OpenScript", "ScriptViewer")
            if not method then
                return BuildDexActionError(action, "action_failed", methodErr, modules, beforeSnapshot, returnSnapshot, "")
            end
            local okCall, okResult, errOrNil = pcall(method, target)
            if not okCall or okResult == false then
                return BuildDexActionError(action, "action_failed", tostring(errOrNil or okResult), modules, beforeSnapshot, returnSnapshot, "")
            end
            changed = true
            message = "Script Viewer opened target script."
            data.target = SummarizeInstance(target)
        elseif action == "script_viewer.get_text" then
            local method, methodErr = EnsureBridgeMethod(scriptViewerMCP, "GetCurrentText", "ScriptViewer")
            if not method then
                return BuildDexActionError(action, "action_failed", methodErr, modules, beforeSnapshot, returnSnapshot, "")
            end
            local okCall, textOrErr = pcall(method)
            if not okCall then
                return BuildDexActionError(action, "action_failed", tostring(textOrErr), modules, beforeSnapshot, returnSnapshot, "")
            end
            changed = false
            message = "Script Viewer text retrieved."
            data.source = tostring(textOrErr or "")
            data.length = #data.source
        elseif action == "script_viewer.copy_text" then
            local method, methodErr = EnsureBridgeMethod(scriptViewerMCP, "CopyCurrentText", "ScriptViewer")
            if not method then
                return BuildDexActionError(action, "action_failed", methodErr, modules, beforeSnapshot, returnSnapshot, "")
            end
            local okCall, okResult, info = pcall(method)
            if not okCall or okResult == false then
                return BuildDexActionError(action, "action_failed", tostring(info or okResult), modules, beforeSnapshot, returnSnapshot, "")
            end
            changed = true
            message = "Script Viewer text copied to clipboard."
            data.copiedChars = tonumber(info) or nil
        elseif action == "script_viewer.save_to_file" then
            local method, methodErr = EnsureBridgeMethod(scriptViewerMCP, "SaveCurrentText", "ScriptViewer")
            if not method then
                return BuildDexActionError(action, "action_failed", methodErr, modules, beforeSnapshot, returnSnapshot, "")
            end
            local okCall, okResult, savedPath = pcall(method, payload.filePath)
            if not okCall or okResult == false then
                return BuildDexActionError(action, "action_failed", tostring(savedPath or okResult), modules, beforeSnapshot, returnSnapshot, "")
            end
            changed = true
            message = "Script Viewer text saved to file."
            data.filePath = tostring(savedPath)
        else
            return BuildDexActionError(action, "invalid_action", "Unsupported script_viewer action.", modules, beforeSnapshot, returnSnapshot, "")
        end
    elseif string.sub(action, 1, 5) == "main." then
        local mainMCP = modules.mainMCP
        if typeof(mainMCP) ~= "table" then
            return BuildDexActionError(action, "bridge_not_ready", "Dex main bridge is unavailable.", modules, beforeSnapshot, returnSnapshot, "Call ensure-dex first.")
        end

        if action == "main.menu.set_open" then
            local open = payload.open == true
            local method, methodErr = EnsureBridgeMethod(mainMCP, "SetMenuOpen", "Main")
            if not method then
                return BuildDexActionError(action, "action_failed", methodErr, modules, beforeSnapshot, returnSnapshot, "")
            end
            local okCall, okResult, menuOpenOrErr = pcall(method, open)
            if not okCall or okResult == false then
                return BuildDexActionError(action, "action_failed", tostring(menuOpenOrErr or okResult), modules, beforeSnapshot, returnSnapshot, "")
            end
            changed = true
            message = "Dex main menu state updated."
            data.requestedOpen = open
            data.menuOpen = menuOpenOrErr
        elseif action == "main.app.set_open" then
            local appName = tostring(payload.appName or payload.app or "")
            local open = payload.open == true
            if appName == "" then
                return BuildDexActionError(action, "invalid_payload", "payload.appName is required.", modules, beforeSnapshot, returnSnapshot, "")
            end
            local method, methodErr = EnsureBridgeMethod(mainMCP, "SetAppOpen", "Main")
            if not method then
                return BuildDexActionError(action, "action_failed", methodErr, modules, beforeSnapshot, returnSnapshot, "")
            end
            local okCall, okResult, resolvedOrErr = pcall(method, appName, open)
            if not okCall or okResult == false then
                return BuildDexActionError(action, "action_failed", tostring(resolvedOrErr or okResult), modules, beforeSnapshot, returnSnapshot, "")
            end
            changed = true
            message = "Dex app state updated."
            data.appName = tostring(resolvedOrErr or appName)
            data.open = open
        elseif action == "main.window.focus" then
            local appName = tostring(payload.appName or payload.app or "")
            if appName == "" then
                return BuildDexActionError(action, "invalid_payload", "payload.appName is required.", modules, beforeSnapshot, returnSnapshot, "")
            end
            local method, methodErr = EnsureBridgeMethod(mainMCP, "FocusWindow", "Main")
            if not method then
                return BuildDexActionError(action, "action_failed", methodErr, modules, beforeSnapshot, returnSnapshot, "")
            end
            local okCall, okResult, resolvedOrErr = pcall(method, appName)
            if not okCall or okResult == false then
                return BuildDexActionError(action, "action_failed", tostring(resolvedOrErr or okResult), modules, beforeSnapshot, returnSnapshot, "")
            end
            changed = true
            message = "Dex window focused."
            data.appName = tostring(resolvedOrErr or appName)
        elseif action == "main.settings.get" then
            local method, methodErr = EnsureBridgeMethod(mainMCP, "GetSettings", "Main")
            if not method then
                return BuildDexActionError(action, "action_failed", methodErr, modules, beforeSnapshot, returnSnapshot, "")
            end
            local okCall, value, errOrNil = pcall(method, payload.path)
            if not okCall or (value == nil and errOrNil ~= nil) then
                return BuildDexActionError(action, "action_failed", tostring(errOrNil or value), modules, beforeSnapshot, returnSnapshot, "")
            end
            changed = false
            message = "Dex settings retrieved."
            data.path = payload.path or ""
            data.value = value
        elseif action == "main.settings.set" then
            local path = tostring(payload.path or "")
            if path == "" then
                return BuildDexActionError(action, "invalid_payload", "payload.path is required.", modules, beforeSnapshot, returnSnapshot, "")
            end
            local method, methodErr = EnsureBridgeMethod(mainMCP, "SetSetting", "Main")
            if not method then
                return BuildDexActionError(action, "action_failed", methodErr, modules, beforeSnapshot, returnSnapshot, "")
            end
            local okCall, okResult, errOrNil = pcall(method, path, payload.value)
            if not okCall or okResult == false then
                return BuildDexActionError(action, "action_failed", tostring(errOrNil or okResult), modules, beforeSnapshot, returnSnapshot, "")
            end
            changed = true
            message = "Dex setting updated."
            data.path = path
            data.value = payload.value
        elseif action == "main.settings.reset" then
            local method, methodErr = EnsureBridgeMethod(mainMCP, "ResetSettings", "Main")
            if not method then
                return BuildDexActionError(action, "action_failed", methodErr, modules, beforeSnapshot, returnSnapshot, "")
            end
            local okCall, okResult, errOrNil = pcall(method)
            if not okCall or okResult == false then
                return BuildDexActionError(action, "action_failed", tostring(errOrNil or okResult), modules, beforeSnapshot, returnSnapshot, "")
            end
            changed = true
            message = "Dex settings reset."
        else
            return BuildDexActionError(action, "invalid_action", "Unsupported main action.", modules, beforeSnapshot, returnSnapshot, "")
        end
    else
        return BuildDexActionError(action, "invalid_action", "Unsupported action namespace.", modules, beforeSnapshot, returnSnapshot, "")
    end

    local afterSnapshot = returnSnapshot and CaptureDexSnapshot() or nil
    if changed == false and returnSnapshot then
        changed = DidSnapshotChange(beforeSnapshot, afterSnapshot)
    end
    return BuildDexActionResult(action, changed, message, modules, data, beforeSnapshot, afterSnapshot, nil)
end

local function ExecuteDexBatch(actions, stopOnError)
    if typeof(actions) ~= "table" then
        return {
            status = "error",
            successCount = 0,
            failureCount = 1,
            stopOnError = stopOnError ~= false,
            results = {{
                status = "error",
                action = "",
                changed = false,
                errorCode = "invalid_payload",
                message = "actions must be an array."
            }}
        }
    end

    local shouldStopOnError = stopOnError ~= false
    local results = {}
    local successCount = 0
    local failureCount = 0

    for i = 1,#actions do
        local step = actions[i]
        if typeof(step) ~= "table" then
            local err = {
                status = "error",
                action = "",
                changed = false,
                errorCode = "invalid_payload",
                message = "actions[" .. tostring(i) .. "] must be an object.",
            }
            results[#results + 1] = err
            failureCount = failureCount + 1
            if shouldStopOnError then
                break
            end
        else
            local actionReq = {
                action = step.action,
                instancePath = step.instancePath,
                instancePaths = step.instancePaths,
                selectionIndex = step.selectionIndex,
                selectionIndices = step.selectionIndices,
                payload = step.payload,
                options = step.options,
            }
            local result = ExecuteDexAction(actionReq)
            result.stepIndex = i
            results[#results + 1] = result
            if result.status == "ok" then
                successCount = successCount + 1
            else
                failureCount = failureCount + 1
                if shouldStopOnError then
                    break
                end
            end
        end
    end

    return {
        status = failureCount == 0 and "ok" or "error",
        successCount = successCount,
        failureCount = failureCount,
        stopOnError = shouldStopOnError,
        results = results,
    }
end

local function GetDexCapabilities()
    local modules = GetDexBridgeModules()
    local descriptors = {}
    for i = 1,#DEX_ACTIONS do
        local action = DEX_ACTIONS[i]
        descriptors[#descriptors + 1] = {
            action = action,
            requiresBridgeReady = IsDexWriteAction(action),
            requiredPayloadKeys = DEX_ACTION_PAYLOAD_KEYS[action] or {},
        }
    end

    return {
        status = "ok",
        bridgeReady = modules.bridgeReady,
        bridgeStatus = modules.bridgeStatus,
        bridgeVersion = modules.bridge and modules.bridge.version or nil,
        bridgeMessage = modules.bridgeMessage,
        actions = DEX_ACTIONS,
        descriptors = descriptors,
    }
end

--// Main Loop \\--
while true do
    local Bridge = CreateBridge()

    Bridge:BindToType("execute", function(data)
        loadstring(data.source)()
        setthreadidentity(8)
    end)

    Bridge:BindToType("get-console-output", function(data)
        local limit = data.limit or 50
        local logsOrder = data.logsOrder or "NewestFirst"

        local logs = LogService:GetLogHistory()
        local results = {}
        
        if logsOrder == "NewestFirst" then
            for i = #logs, 1, -1 do
                if #results >= limit then break end
                table.insert(results, logs[i])
            end
        else
            for _, log in logs do
                if #results >= limit then break end
                table.insert(results, log)
            end
        end

        return { count = #LogService:GetLogHistory(), limited = #LogService:GetLogHistory() > limit, results = results }
    end)

    Bridge:BindToType("get-data-by-code", function(data)
        local dataOutput = table.pack(loadstring(data.source)())
        setthreadidentity(8)

        return dataOutput
    end)

    Bridge:BindToType("get-script-content", function(data)
        local scriptInstance = loadstring(data.source)()
        setthreadidentity(8)

        assert(typeof(scriptInstance) == "Instance", "Script instance is not an instance.")
        assert(scriptInstance:IsA("LuaSourceContainer"), "Script instance is not a LuaSourceContainer (Script, LocalScript, or ModuleScript).")
        assert(not (scriptInstance:IsA("Script") and scriptInstance.RunContext == Enum.RunContext.Server), "Script instance is a Server Script.")

        if not ScriptSourcesMap[scriptInstance:GetDebugId()] then
            MapScriptSource(scriptInstance)
        end

        return ScriptSourcesMap[scriptInstance:GetDebugId()]
    end)

    Bridge:BindToType("search-instances", function(data)
        local rootInstance = loadstring("return " .. data.root)()
        local instances = rootInstance:QueryDescendants(data.selector)
        
        local limit = data.limit or 50
        local results = {}
        
        for i, instance in instances do
            if i > limit then break end

            table.insert(results, {
                Name = instance.Name,
                ClassName = instance.ClassName,
                InstancePath = instance,
                DebugId = instance:GetDebugId()
            })
        end
        
        return {
            count = #instances,
            limited = #instances > limit,
            results = results
        }
    end)

    Bridge:BindToType("get-game-info", function(data)
        local productInfo = MarketplaceService:GetProductInfo(game.PlaceId)
        
        return {
            PlaceId = game.PlaceId,
            GameId = game.GameId,
            PlaceVersion = game.PlaceVersion,
            PlaceName = productInfo.Name,
            PlaceDescription = productInfo.Description,
            Creator = productInfo.Creator.Name,
            CreatorType = tostring(productInfo.Creator.CreatorType),
            CreatorId = productInfo.Creator.CreatorTargetId,
            JobId = game.JobId,
            ServerType = RobloxReplicatedStorage.GetServerType:InvokeServer()
        }
    end)

    Bridge:BindToType("get-descendants-tree", function(data)
        local rootInstance = loadstring("return " .. data.root)()
        assert(typeof(rootInstance) == "Instance", "Root path did not resolve to a valid Instance.")

        local maxDepth = data.maxDepth or 3
        local maxChildren = data.maxChildren or 50
        local classFilter = data.classFilter or ""
        local hasFilter = classFilter ~= ""

        local function buildTree(instance, depth)
            if depth > maxDepth then
                return nil
            end

            local children = instance:GetChildren()
            local childNodes = {}
            local shown = 0
            local total = #children

            for _, child in children do
                if shown >= maxChildren then break end

                if hasFilter and not child:IsA(classFilter) then
                    -- Even if this child doesn't match, check if any descendant might
                    -- Only skip if we're at max depth anyway
                    if depth < maxDepth then
                        local subtree = buildTree(child, depth + 1)
                        if subtree and subtree.Children and #subtree.Children > 0 then
                            table.insert(childNodes, subtree)
                            shown += 1
                        end
                    end
                    continue
                end

                local node = {
                    Name = child.Name,
                    ClassName = child.ClassName,
                    ChildCount = #child:GetChildren()
                }

                if depth < maxDepth and node.ChildCount > 0 then
                    local subtree = buildTree(child, depth + 1)
                    if subtree then
                        node.Children = subtree.Children
                    end
                end

                table.insert(childNodes, node)
                shown += 1
            end

            return {
                Name = instance.Name,
                ClassName = instance.ClassName,
                ChildCount = total,
                TruncatedAt = if shown < total then shown else nil,
                Children = childNodes
            }
        end

        return buildTree(rootInstance, 0)
    end)

    Bridge:BindToType("ensure-dex", function(data)
        local waitTimeoutMs = ClampInt(data.waitTimeoutMs, 1000, 30000, 12000)
        local initialMenu, initialLocation = FindDexMainMenu()
        local wasAlreadyLoaded = initialMenu ~= nil

        local mainMenu = initialMenu
        local location = initialLocation

        if not wasAlreadyLoaded then
            local injectedOk, injectedErr = RunDexInjectedSource()
            if not injectedOk then
                error("Failed to load Dex explorer: " .. tostring(injectedErr))
            end

            local waitStart = os.clock()
            while os.clock() - waitStart < (waitTimeoutMs / 1000) do
                mainMenu, location = FindDexMainMenu()
                if mainMenu then
                    break
                end
                task.wait(0.1)
            end
        end

        local bridge, bridgeStatus, bridgeMessage = GetDexBridgeStatus()
        local bridgeReady = bridgeStatus == "ready" and bridge ~= nil
        local status = "loading_timeout"
        local loaded = false
        local message = "Dex script executed, but MainMenu was not detected before timeout."

        if mainMenu then
            loaded = true
            status = wasAlreadyLoaded and "already_loaded" or "loaded"
            if wasAlreadyLoaded then
                message = "Dex explorer is already loaded."
            else
                message = "Dex explorer loaded successfully."
            end
        end

        return {
            status = status,
            loaded = loaded,
            location = location,
            bridgeReady = bridgeReady,
            bridgeStatus = bridgeStatus,
            bridgeMessage = bridgeMessage,
            message = message
        }
    end)

    Bridge:BindToType("get-dex-status", function(data)
        local mainMenu, location = FindDexMainMenu()
        local bridge, bridgeStatus, bridgeMessage = GetDexBridgeStatus()
        local bridgeReady = bridgeStatus == "ready" and bridge ~= nil
        local bridgeVersion = bridge and bridge.version or nil

        if not mainMenu then
            return {
                status = "not_loaded",
                loaded = false,
                location = nil,
                menuOpen = nil,
                menuButtonText = nil,
                bridgeReady = bridgeReady,
                bridgeStatus = bridgeStatus,
                bridgeVersion = bridgeVersion,
                bridgeMessage = bridgeMessage,
                message = "Dex explorer is not currently loaded."
            }
        end

        local menuOpen, menuButtonText = GetDexMenuOpenState(mainMenu)
        return {
            status = "loaded",
            loaded = true,
            location = location,
            menuOpen = menuOpen,
            menuButtonText = menuButtonText,
            bridgeReady = bridgeReady,
            bridgeStatus = bridgeStatus,
            bridgeVersion = bridgeVersion,
            bridgeMessage = bridgeMessage,
            message = "Dex explorer is loaded."
        }
    end)

    Bridge:BindToType("set-dex-menu-open", function(data)
        local requestedOpen = data.open == true
        local mainMenu, location = FindDexMainMenu()
        assert(mainMenu, "Dex explorer is not loaded. Call ensure-dex first.")

        local initialOpen, _, openButton = GetDexMenuOpenState(mainMenu)
        assert(openButton, "Dex menu button was not found. Dex UI may be in an unexpected state.")

        if initialOpen == requestedOpen then
            return {
                status = "no_change",
                requestedOpen = requestedOpen,
                menuOpen = initialOpen,
                changed = false,
                method = "none",
                location = location,
                message = "Dex menu is already in the requested state."
            }
        end

        local _, method = TryToggleDexMenu(openButton, requestedOpen)
        local finalOpen = GetDexMenuOpenState(mainMenu)

        if finalOpen ~= requestedOpen then
            error("Failed to change Dex menu state. Executor may not support GUI activation fallback methods.")
        end

        local changed = if initialOpen == nil then true else finalOpen ~= initialOpen
        return {
            status = changed and "changed" or "no_change",
            requestedOpen = requestedOpen,
            menuOpen = finalOpen,
            changed = changed,
            method = method,
            location = location,
            message = "Dex menu state updated."
        }
    end)

    Bridge:BindToType("get-dex-overview", function(data)
        local mainMenu, location = FindDexMainMenu()
        local menuOpen, menuButtonText = GetDexMenuOpenState(mainMenu)
        local bridge, bridgeStatus, bridgeMessage = GetDexBridgeStatus()
        local bridgeReady = bridgeStatus == "ready" and bridge ~= nil
        local explorer = bridge and bridge.apps and bridge.apps.Explorer
        local properties = bridge and bridge.apps and bridge.apps.Properties
        local scriptViewer = bridge and bridge.apps and bridge.apps.ScriptViewer
        local explorerMCP = explorer and explorer.__MCP

        local selectionCount = 0
        if typeof(explorerMCP) == "table" and typeof(explorerMCP.GetSelectionCount) == "function" then
            local okCount, count = pcall(explorerMCP.GetSelectionCount)
            if okCount and tonumber(count) ~= nil then
                selectionCount = tonumber(count)
            end
        end

        local searchText = ""
        if typeof(explorerMCP) == "table" and typeof(explorerMCP.GetSearchText) == "function" then
            local okSearch, searchResult = pcall(explorerMCP.GetSearchText)
            if okSearch and typeof(searchResult) == "string" then
                searchText = searchResult
            end
        end

        local function GetWindowVisible(windowObj)
            if typeof(windowObj) ~= "table" or typeof(windowObj.IsVisible) ~= "function" then
                return nil
            end
            local okVisible, visible = pcall(windowObj.IsVisible, windowObj)
            if okVisible then
                return visible == true
            end
            return nil
        end

        return {
            status = mainMenu and "loaded" or "not_loaded",
            loaded = mainMenu ~= nil,
            location = location,
            menuOpen = menuOpen,
            menuButtonText = menuButtonText,
            selectionCount = selectionCount,
            searchText = searchText,
            windows = {
                explorerVisible = GetWindowVisible(explorer and explorer.Window),
                propertiesVisible = GetWindowVisible(properties and properties.Window),
                scriptViewerVisible = GetWindowVisible(scriptViewer and scriptViewer.Window),
            },
            bridgeReady = bridgeReady,
            bridgeStatus = bridgeStatus,
            bridgeVersion = bridge and bridge.version or nil,
            bridgeMessage = bridgeMessage,
            message = mainMenu and "Dex overview retrieved." or "Dex explorer is not loaded."
        }
    end)

    Bridge:BindToType("get-dex-selection", function(data)
        local bridge, bridgeStatus, bridgeMessage = GetDexBridgeStatus()
        local bridgeReady = bridgeStatus == "ready" and bridge ~= nil
        local explorer = bridge and bridge.apps and bridge.apps.Explorer
        local explorerMCP = explorer and explorer.__MCP

        if not bridgeReady or typeof(explorerMCP) ~= "table" or typeof(explorerMCP.GetSelectionNodes) ~= "function" then
            return {
                status = "ok",
                bridgeReady = false,
                bridgeStatus = bridgeStatus,
                bridgeMessage = bridgeMessage,
                message = "Dex selection reader is unavailable. Call ensure-dex, then select an object in Dex.",
                total = 0,
                startIndex = 1,
                limit = ClampInt(data.limit, 1, 1000, 200),
                returned = 0,
                hasMore = false,
                results = {}
            }
        end

        local okNodes, selectionNodes = pcall(explorerMCP.GetSelectionNodes)
        if not okNodes or typeof(selectionNodes) ~= "table" then
            error("Failed to read Dex selection nodes. Try calling ensure-dex again.")
        end

        local selectionEntries = {}
        for i = 1,#selectionNodes do
            local node = selectionNodes[i]
            if typeof(node) ~= "table" or typeof(node.Obj) ~= "Instance" then
                continue
            end

            local nodeDepth = 0
            local parentNode = node.Parent
            while parentNode do
                nodeDepth += 1
                parentNode = parentNode.Parent
            end

            local debugId = nil
            local okDebug, debugValue = pcall(function()
                return node.Obj:GetDebugId()
            end)
            if okDebug then
                debugId = debugValue
            end

            local childCount = 0
            local okChildren, childCountValue = pcall(function()
                return #node.Obj:GetChildren()
            end)
            if okChildren then
                childCount = childCountValue
            end

            selectionEntries[#selectionEntries + 1] = {
                index = i,
                name = node.Obj.Name,
                className = node.Obj.ClassName,
                path = SafePathFromInstance(node.Obj),
                debugId = debugId,
                childCount = childCount,
                depth = nodeDepth
            }
        end

        local page = Paginate(selectionEntries, data.startIndex, data.limit, 1000, 200)
        page.status = "ok"
        page.bridgeReady = true
        page.bridgeStatus = bridgeStatus
        page.bridgeMessage = bridgeMessage
        page.message = (#selectionEntries == 0)
            and "Dex selection is empty. Select an object in Dex or pass instancePath to other tools."
            or "Dex selection snapshot retrieved."
        return page
    end)

    Bridge:BindToType("get-dex-explorer-tree", function(data)
        local rawRows, treeStatus, treeMessage = BuildDexTreeRows(false, false)
        local outputRows = {}
        for i = 1,#rawRows do
            outputRows[#outputRows + 1] = ConvertTreeRowToOutput(rawRows[i])
        end

        local page = Paginate(outputRows, data.startIndex, data.limit, 1000, 500)
        page.status = "ok"
        page.bridgeReady = treeStatus == "ready"
        page.bridgeStatus = treeStatus
        page.message = treeMessage
        return page
    end)

    Bridge:BindToType("search-dex-explorer", function(data)
        local query = tostring(data.query or "")
        local includeAncestors = data.includeAncestors == true
        local preserveUi = data.preserveUi ~= false

        local rawRows, treeStatus, treeMessage = BuildDexTreeRows(true, false)
        local objectToIndex = {}
        for i = 1,#rawRows do
            objectToIndex[rawRows[i].Object] = i
        end

        local included = {}
        for i = 1,#rawRows do
            local outputRow = ConvertTreeRowToOutput(rawRows[i])
            local isMatch = query == ""
                or ContainsCaseInsensitive(outputRow.name, query)
                or ContainsCaseInsensitive(outputRow.className, query)
                or ContainsCaseInsensitive(outputRow.path, query)

            if isMatch then
                included[i] = true

                if includeAncestors then
                    local raw = rawRows[i]
                    if raw.kind == "dex" and raw.Node then
                        local parentNode = raw.Node.Parent
                        while parentNode do
                            local parentObj = parentNode.Obj
                            if parentObj and objectToIndex[parentObj] then
                                included[objectToIndex[parentObj]] = true
                            end
                            parentNode = parentNode.Parent
                        end
                    else
                        local parentObj = raw.Object and raw.Object.Parent
                        while parentObj do
                            local parentIndex = objectToIndex[parentObj]
                            if parentIndex then
                                included[parentIndex] = true
                            end
                            if parentObj == game then
                                break
                            end
                            parentObj = parentObj.Parent
                        end
                    end
                end
            end
        end

        local filtered = {}
        for i = 1,#rawRows do
            if included[i] then
                filtered[#filtered + 1] = ConvertTreeRowToOutput(rawRows[i])
            end
        end

        local page = Paginate(filtered, data.startIndex, data.limit, 1000, 500)
        page.status = "ok"
        page.query = query
        page.includeAncestors = includeAncestors
        page.preserveUi = preserveUi
        page.bridgeReady = treeStatus == "ready"
        page.bridgeStatus = treeStatus
        page.message = "Dex explorer search completed without mutating Dex UI state. " .. treeMessage
        return page
    end)

    Bridge:BindToType("get-dex-properties", function(data)
        local searchText = tostring(data.search or "")
        local includeTags = data.includeTags ~= false
        local selectionIndex = ClampInt(data.selectionIndex, 1, 1000000, 1)
        local target, resolveErr = ResolveDexTargetInstance(data.instancePath, selectionIndex)
        assert(target, resolveErr)

        local bridge, bridgeStatus, bridgeMessage = GetDexBridgeStatus()
        local bridgeReady = bridgeStatus == "ready" and bridge ~= nil
        local properties = bridge and bridge.apps and bridge.apps.Properties
        local propertiesMCP = properties and properties.__MCP

        local rows = {}
        local source = "fallback"
        local message = "Dex properties snapshot returned using fallback reader."

        if bridgeReady and typeof(propertiesMCP) == "table" and typeof(propertiesMCP.BuildRowsForObject) == "function" then
            local okRows, dexRows, dexErr = pcall(propertiesMCP.BuildRowsForObject, target, {
                search = searchText,
                includeTags = includeTags
            })
            if okRows and typeof(dexRows) == "table" then
                source = "dex_bridge"
                message = "Dex properties snapshot retrieved from bridge."

                for i = 1,#dexRows do
                    local row = dexRows[i]
                    if typeof(row) ~= "table" then continue end

                    rows[#rows + 1] = {
                        category = row.Category or row.category or "Data",
                        name = row.Name or row.name or "",
                        displayName = row.DisplayName or row.displayName or row.Name or row.name or "",
                        type = row.ValueType or row.type or "unknown",
                        value = row.Value,
                        readable = row.Readable ~= false,
                        readableValue = row.ReadableValue or tostring(row.Value),
                        tags = includeTags and (row.Tags or row.tags or {}) or nil,
                        source = source
                    }
                end
            else
                message = "Dex bridge properties reader failed; fallback reader used. " .. tostring(dexErr or "")
                rows = BuildFallbackPropertyRows(target, searchText, includeTags)
            end
        else
            rows = BuildFallbackPropertyRows(target, searchText, includeTags)
        end

        local page = Paginate(rows, data.startIndex, data.limit, 1000, 300)
        page.status = "ok"
        page.bridgeReady = bridgeReady
        page.bridgeStatus = bridgeStatus
        page.bridgeMessage = bridgeMessage
        page.targetPath = SafePathFromInstance(target)
        page.selectionIndex = selectionIndex
        page.search = searchText
        page.includeTags = includeTags
        page.source = source
        page.message = message
        return page
    end)

    Bridge:BindToType("get-dex-script-viewer", function(data)
        local preferCurrentViewer = data.preferCurrentViewer ~= false
        local maxChars = ClampInt(data.maxChars, 1000, 500000, 200000)
        local selectionIndex = ClampInt(data.selectionIndex, 1, 1000000, 1)
        local bridge, bridgeStatus, bridgeMessage = GetDexBridgeStatus()
        local bridgeReady = bridgeStatus == "ready" and bridge ~= nil
        local scriptViewer = bridge and bridge.apps and bridge.apps.ScriptViewer
        local scriptViewerMCP = scriptViewer and scriptViewer.__MCP

        local sourceText = nil
        local sourceFrom = nil
        local message = nil
        local target = nil

        if preferCurrentViewer and (data.instancePath == nil or data.instancePath == "") and typeof(scriptViewerMCP) == "table" and typeof(scriptViewerMCP.GetCurrentText) == "function" then
            local okViewer, viewerText = pcall(scriptViewerMCP.GetCurrentText)
            if okViewer and typeof(viewerText) == "string" and viewerText ~= "" then
                sourceText = viewerText
                sourceFrom = "viewer_buffer"
                message = "Returned source from currently opened Dex Script Viewer buffer."
            end
        end

        if not sourceText then
            local resolveTarget, resolveErr = ResolveDexTargetInstance(data.instancePath, selectionIndex)
            assert(resolveTarget, resolveErr)
            target = resolveTarget

            assert(target:IsA("LuaSourceContainer"), "Target is not a script instance. Select a LocalScript/ModuleScript in Dex or provide instancePath.")
            assert(not (target:IsA("Script") and target.RunContext == Enum.RunContext.Server), "Target is a server script. Provide a client-readable script.")

            local okDecompile, decompileResult = pcall(decompile, target)
            if okDecompile and typeof(decompileResult) == "string" and decompileResult ~= "" then
                sourceText = decompileResult
                sourceFrom = "decompile"
                message = "Script source returned from decompile()."
            else
                local debugId = target:GetDebugId()
                if not ScriptSourcesMap[debugId] then
                    pcall(MapScriptSource, target)
                end
                local fallbackSource = ScriptSourcesMap[debugId]
                if typeof(fallbackSource) == "string" and fallbackSource ~= "" then
                    sourceText = fallbackSource
                    sourceFrom = "fallback"
                    message = "Script source returned from fallback script source cache."
                else
                    sourceText = "-- Unable to read script source via Dex viewer, decompile(), or fallback cache."
                    sourceFrom = "fallback"
                    message = "No script source reader succeeded."
                end
            end
        end

        local truncated = false
        if #sourceText > maxChars then
            sourceText = string.sub(sourceText, 1, maxChars)
            truncated = true
        end

        return {
            status = "ok",
            bridgeReady = bridgeReady,
            bridgeStatus = bridgeStatus,
            bridgeMessage = bridgeMessage,
            sourceFrom = sourceFrom or "fallback",
            truncated = truncated,
            maxChars = maxChars,
            preferCurrentViewer = preferCurrentViewer,
            targetPath = target and SafePathFromInstance(target) or nil,
            message = message or "Script source returned.",
            source = sourceText
        }
    end)

    Bridge:BindToType("dex-list-capabilities", function(data)
        return GetDexCapabilities()
    end)

    Bridge:BindToType("dex-action", function(data)
        return ExecuteDexAction(data)
    end)

    Bridge:BindToType("dex-batch-actions", function(data)
        local actions = data.actions
        local stopOnError = data.stopOnError
        return ExecuteDexBatch(actions, stopOnError)
    end)

    Bridge:BindToType("ensure-remote-spy", function(data)
        if getgenv().Cobalt then
            return {
                status = "already_loaded",
                message = "Cobalt remote spy is already running."
            }
        end

        -- Load Cobalt
        local success, err = pcall(function()
            loadstring(game:HttpGet("https://github.com/notpoiu/cobalt/releases/latest/download/Cobalt.luau"))()
        end)

        if not success then
            error("Failed to load Cobalt: " .. tostring(err))
        end

        -- Wait for Cobalt to initialize
        local waitStart = os.clock()
        while not getgenv().Cobalt and os.clock() - waitStart < 10 do
            task.wait(0.1)
        end
        
        return {
            status = "loaded",
            message = "Cobalt remote spy loaded successfully."
        }
    end)

    Bridge:BindToType("get-remote-spy-logs", function(data)
        local Cobalt = getgenv().Cobalt
        assert(Cobalt and Cobalt.shared and Cobalt.shared.Logs, "Cobalt remote spy is not loaded. Call ensure-remote-spy first.")

        local direction = data.direction or "Both"
        local nameFilter = data.remoteNameFilter or ""
        local limit = data.limit or 50
        local maxCallsPerRemote = data.maxCallsPerRemote or 5
        local hasNameFilter = nameFilter ~= ""

        local function ProcessLogs(logTable, directionLabel)
            local results = {}

            for instance, log in logTable do
                if typeof(instance) ~= "Instance" then continue end
                if #results >= limit then break end

                local remoteName = ""
                local remoteClass = ""
                pcall(function()
                    remoteName = instance.Name
                    remoteClass = instance.ClassName
                end)

                -- Apply name filter
                if hasNameFilter and not string.find(string.lower(remoteName), string.lower(nameFilter), 1, true) then
                    continue
                end

                -- Get recent calls (raw — LuaEncode handles serialization)
                local recentCalls = {}
                local totalCalls = #log.Calls
                local startIdx = math.max(1, totalCalls - maxCallsPerRemote + 1)

                for i = startIdx, totalCalls do
                    local call = log.Calls[i]
                    if not call then continue end

                    table.insert(recentCalls, {
                        Index = i,
                        Arguments = call.Arguments,
                        Origin = call.Origin,
                        IsExecutor = call.IsExecutor or false,
                        IsActor = call.IsActor or false,
                        Line = call.Line,
                    })
                end

                table.insert(results, {
                    RemoteName = remoteName,
                    RemoteClass = remoteClass,
                    Direction = directionLabel,
                    Method = log.Method,
                    TotalCalls = totalCalls,
                    Ignored = log.Ignored,
                    Blocked = log.Blocked,
                    RecentCalls = recentCalls,
                })
            end

            return results
        end

        local allResults = {}

        if direction == "Outgoing" or direction == "Both" then
            local outgoing = ProcessLogs(Cobalt.shared.Logs.Outgoing, "Outgoing")
            for _, r in outgoing do
                table.insert(allResults, r)
            end
        end

        if direction == "Incoming" or direction == "Both" then
            local incoming = ProcessLogs(Cobalt.shared.Logs.Incoming, "Incoming")
            for _, r in incoming do
                table.insert(allResults, r)
            end
        end

        -- Sort by total calls descending (most active remotes first)
        table.sort(allResults, function(a, b)
            return a.TotalCalls > b.TotalCalls
        end)

        -- Trim to limit
        if #allResults > limit then
            local trimmed = {}
            for i = 1, limit do
                trimmed[i] = allResults[i]
            end
            allResults = trimmed
        end

        return {
            count = #allResults,
            results = allResults
        }
    end)

    Bridge:BindToType("clear-remote-spy-logs", function(data)
        local Cobalt = getgenv().Cobalt
        assert(Cobalt and Cobalt.shared and Cobalt.shared.ClearLogs, "Cobalt remote spy is not loaded. Call ensure-remote-spy first.")

        Cobalt.shared.ClearLogs()

        return {
            status = "cleared",
            message = "All remote spy logs have been cleared."
        }
    end)

    Bridge:BindToType("block-remote", function(data)
        local Cobalt = getgenv().Cobalt
        assert(Cobalt and Cobalt.shared and Cobalt.shared.Logs, "Cobalt remote spy is not loaded. Call ensure-remote-spy first.")

        local remoteName = data.remoteName
        local direction = data.direction
        local shouldBlock = data.shouldBlock

        local logTable = Cobalt.shared.Logs[direction]
        assert(logTable, "Invalid direction: " .. tostring(direction))

        for instance, log in logTable do
            if typeof(instance) ~= "Instance" then continue end

            local name = ""
            pcall(function() name = instance.Name end)

            if name == remoteName then
                if shouldBlock and not log.Blocked then
                    log:Block()
                elseif not shouldBlock and log.Blocked then
                    log:Block() -- toggles
                end

                return {
                    status = "success",
                    message = (shouldBlock and "Blocked" or "Unblocked") .. " remote: " .. remoteName,
                    blocked = log.Blocked
                }
            end
        end

        error("Remote not found: " .. remoteName .. " in " .. direction .. " logs. Make sure the remote has been logged at least once.")
    end)

    Bridge:BindToType("ignore-remote", function(data)
        local Cobalt = getgenv().Cobalt
        assert(Cobalt and Cobalt.shared and Cobalt.shared.Logs, "Cobalt remote spy is not loaded. Call ensure-remote-spy first.")

        local remoteName = data.remoteName
        local direction = data.direction
        local shouldIgnore = data.shouldIgnore

        local logTable = Cobalt.shared.Logs[direction]
        assert(logTable, "Invalid direction: " .. tostring(direction))

        for instance, log in logTable do
            if typeof(instance) ~= "Instance" then continue end

            local name = ""
            pcall(function() name = instance.Name end)

            if name == remoteName then
                if shouldIgnore and not log.Ignored then
                    log:Ignore()
                elseif not shouldIgnore and log.Ignored then
                    log:Ignore() -- toggles
                end

                return {
                    status = "success",
                    message = (shouldIgnore and "Ignoring" or "Unignored") .. " remote: " .. remoteName,
                    ignored = log.Ignored
                }
            end
        end

        error("Remote not found: " .. remoteName .. " in " .. direction .. " logs. Make sure the remote has been logged at least once.")
    end)

    Bridge:BindToType("search-scripts-sources", function(data)
        assert(ScriptSourcesMap.HasFinishedMapping, "The bridge is still mapping all script sources (" .. tostring(MappedSources) .. "/" .. tostring(SourcesToMap) .. ") please try again later.")

        local stringMatchQueries = ParseQuery(data.query)
        local limit = data.limit or 50
        local contextLines = data.contextLines or 2
        local totalMatches = 0
        local maxMatchesPerScript = data.maxMatchesPerScript or 20

        --// Pre-compute query info \\--
        local queryInfo = {}
        for idx, query in stringMatchQueries do
            local isLogicalAND = typeof(query) == "table"
            local isMultiLine = false
            
            if isLogicalAND then
                for _, q in query.AndQueries do
                    if not q:find("\n", 1, true) then continue end
                    
                    isMultiLine = true
                    break
                end
            else
                isMultiLine = query:find("\n", 1, true) ~= nil
            end
            
            queryInfo[idx] = { isLogicalAND = isLogicalAND, isMultiLine = isMultiLine }
        end

        --// Filter scripts that we need to process (search) \\--
        local matchingScripts = {}
        local count = 0
        
        for debugId, source in ScriptSourcesMap do
            if debugId == "HasFinishedMapping" then continue end
            if #matchingScripts >= limit then break end

            --// Rate limit \\--
            count += 1
            if count % 200 == 0 then task.wait() end

            --// Pre-check \\--
            local hasAnyPotentialMatch = false
            for idx, query in stringMatchQueries do
                local info = queryInfo[idx]
                
                if info.isLogicalAND then
                    local allPartsMatch = true
                    for _, andQuery in query.AndQueries do
                        if not source:find(andQuery, 1, true) then
                            allPartsMatch = false
                            break
                        end
                    end
                    if allPartsMatch then
                        hasAnyPotentialMatch = true
                        break
                    end
                elseif source:find(query, 1, true) then
                    hasAnyPotentialMatch = true
                    break
                end
            end

            if not hasAnyPotentialMatch then continue end
            
            table.insert(matchingScripts, { debugId = debugId, source = source })
        end

        --// Process matching scripts \\--
        local results = {}
        
        for _, scriptData in matchingScripts do
            if #results >= limit then break end
            
            local debugId = scriptData.debugId
            local source = scriptData.source
            
            --// Build line info lazily \\--
            local lines = nil
            local lineStarts = nil
            
            local function EnsureLineInfo()
                if lines then return end
                lines = {}
                local pos = 1
                local len = #source
                while pos <= len do
                    local newlinePos = source:find("\n", pos, true)
                    if newlinePos then
                        table.insert(lines, source:sub(pos, newlinePos - 1))
                        pos = newlinePos + 1
                    else
                        table.insert(lines, source:sub(pos))
                        break
                    end
                end
                lineStarts = GetLineInfo(source)
            end

            local function AddMatch(matchingLines, startLine, endLine, matchedContent)
                EnsureLineInfo()
                
                local before = {}
                for i = math.max(1, startLine - contextLines), startLine - 1 do
                    table.insert(before, { lineNumber = i, content = lines[i] or "" })
                end
                
                local after = {}
                for i = endLine + 1, math.min(#lines, endLine + contextLines) do
                    table.insert(after, { lineNumber = i, content = lines[i] or "" })
                end
                
                local content
                if startLine == endLine then
                    content = matchedContent or lines[startLine] or ""
                else
                    content = {}
                    for i = startLine, endLine do
                        table.insert(content, { lineNumber = i, content = lines[i] or "" })
                    end
                end
                
                table.insert(matchingLines, {
                    lineNumber = startLine,
                    endLineNumber = endLine,
                    content = content,
                    before = before,
                    after = after
                })
            end

            --// Find all matching lines \\--
            local matchingLines = {}
            local matchedPositions = {}
            
            for idx, query in stringMatchQueries do
                if #matchingLines >= maxMatchesPerScript then break end
                
                local info = queryInfo[idx]
                
                if info.isMultiLine then
                    EnsureLineInfo()

                    local searchStart = 1
                    while #matchingLines < maxMatchesPerScript do
                        local matchStart, matchEnd
                        
                        if info.isLogicalAND then
                            local allMatch = true
                            local minStart, maxEnd = math.huge, 0
                            for _, andQuery in query.AndQueries do
                                local s, e = source:find(andQuery, searchStart, true)
                                if not s then
                                    allMatch = false
                                    break
                                end

                                minStart = math.min(minStart, s)
                                maxEnd = math.max(maxEnd, e)
                            end

                            if allMatch then matchStart, matchEnd = minStart, maxEnd end
                        else
                            matchStart, matchEnd = source:find(query, searchStart, true)
                        end
                        
                        if not matchStart then break end
                        
                        local posKey = matchStart
                        if not matchedPositions[posKey] then
                            matchedPositions[posKey] = true
                            local startLine = GetLineNumber(lineStarts, matchStart)
                            local endLine = GetLineNumber(lineStarts, matchEnd)
                            local matchedContent = source:sub(matchStart, matchEnd)
                            AddMatch(matchingLines, startLine, endLine, matchedContent)
                        end

                        searchStart = matchEnd + 1
                    end

                else
                    
                    local searchStart = 1
                    while #matchingLines < maxMatchesPerScript do
                        local matchStart, matchEnd
                        
                        if info.isLogicalAND then
                            -- For AND queries, find first query then verify others on same line
                            local firstQuery = query.AndQueries[1]
                            matchStart, matchEnd = source:find(firstQuery, searchStart, true)
                            
                            if matchStart then
                                -- Find line boundaries
                                local lineStart = source:sub(1, matchStart):match(".*\n()") or 1
                                local lineEnd = source:find("\n", matchEnd, true) or (#source + 1)
                                local lineContent = source:sub(lineStart, lineEnd - 1)
                                
                                -- Check all AND queries match on this line
                                local allMatch = true
                                for i = 2, #query.AndQueries do
                                    if not lineContent:find(query.AndQueries[i], 1, true) then
                                        allMatch = false
                                        break
                                    end
                                end
                                
                                if not allMatch then
                                    searchStart = lineEnd + 1
                                    continue
                                end
                                
                                matchStart = lineStart
                                matchEnd = lineEnd - 1
                            end
                        else
                            matchStart, matchEnd = source:find(query, searchStart, true)
                        end
                        
                        if not matchStart then break end
                        
                        EnsureLineInfo()
                        local lineNumber = GetLineNumber(lineStarts, matchStart)
                        
                        if not matchedPositions[lineNumber] then
                            matchedPositions[lineNumber] = true
                            AddMatch(matchingLines, lineNumber, lineNumber, lines[lineNumber])
                        end
                        
                        local nextNewline = source:find("\n", matchEnd, true)
                        if not nextNewline then break end
                        searchStart = nextNewline + 1
                    end
                end
            end

            if #matchingLines == 0 then continue end

            local scriptRef = GetScriptByDebugId(debugId)
            local scriptPath = scriptRef and scriptRef or "<ScriptProxy: " .. debugId .. ">"

            totalMatches += #matchingLines
            table.insert(results, {
                Script = scriptPath,
                MatchCount = #matchingLines,
                Matches = matchingLines
            })
        end

        return {
            count = #results,
            totalMatches = totalMatches,
            limited = #results >= limit,
            results = results
        }
    end)

    Bridge:WaitForDisconnect()
end

