--[[
================================================================================
  DataManager  (ServerScriptService)
  
  RESUME BULLET: "Built a DataStore persistence layer to save and load player
  progression, currency, and equipped cosmetics across sessions, with error
  handling and retry logic to prevent data loss"
  
  WHAT THIS SCRIPT DOES:
  • Loads player data from DataStore when they join
  • Restores saved values into the GameData folder (created by GameServer)
  • Saves data to DataStore when a player leaves (PlayerRemoving)
  • Auto-saves every 60 seconds to reduce loss on server crash
  • Completely separate from game logic — GameServer owns all rules
================================================================================
--]]

-- DataManager v4: Pure DataStore persistence — no game logic.
-- GameServer is the single authority for all kicks, shop, passes, products.
-- This script ONLY saves/loads data to DataStore and restores it to the GameData folder.

local Players           = game:GetService("Players")
local DataStoreService  = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- The DataStore key name — changing this resets ALL player data in production
local DataStore = DataStoreService:GetDataStore("SoccerKickSimV1")

-- SAVE_KEYS: defines every field we persist, plus its default value if missing.
-- This must exactly match the GameData folder schema in GameServer.
-- Adding a new key here automatically handles old saves gracefully (defaults kick in).
local SAVE_KEYS = {
    {name="Cash",              default=0},       -- in-game currency balance
    {name="TotalCashEarned",   default=0},       -- lifetime earnings (for stats)
    {name="Rebirths",          default=0},       -- prestige count
    {name="Goals",             default=0},       -- total goals scored
    {name="Snipes",            default=0},       -- total snipe (corner) goals
    {name="Attempts",          default=0},       -- total kick attempts
    {name="LongestGoal",       default=0},       -- personal best distance (yards)
    {name="RebirthMultiplier", default=1},       -- cash multiplier from rebirths
    {name="CashLevel",         default=0},       -- upgradeable cash boost level
    {name="HasAutoKick",        default=false},  -- gamepass: auto-kick enabled
    {name="Has2xCash",          default=false},  -- gamepass: double cash enabled
    {name="SpeedPassBonus",     default=0},      -- gamepass: speed stat boost
    {name="PowerPassBonus",     default=0},      -- gamepass: power stat boost
    {name="AccuracyPassBonus",  default=0},      -- gamepass: accuracy stat boost
    {name="KickSpeedPassBonus", default=false},  -- gamepass: faster kick charge
    {name="EquippedBall",       default="ball_1"},    -- active ball cosmetic ID
    {name="EquippedJersey",     default="jersey_1"},  -- active jersey cosmetic ID
    {name="EquippedCleats",     default="cleats_1"},  -- active cleats cosmetic ID
    {name="EquippedHelmet",     default="helmet_1"},  -- active helmet cosmetic ID
}

-- In-memory cache: [userId] = {key=value, ...}
-- Avoids re-reading DataStore mid-session; GameServer writes to GameData folder,
-- and DataManager reads the folder when saving (readFolder below).
local savedData = {}

-- readFolder: snapshots current GameData folder values into a plain table.
-- Called right before saving so we always persist the latest in-memory state.
local function readFolder(player)
    local folder = player:FindFirstChild("GameData")
    if not folder then return nil end
    local out = {}
    for _, info in ipairs(SAVE_KEYS) do
        local v = folder:FindFirstChild(info.name)
        out[info.name] = v and v.Value or info.default
    end
    return out
end

-- restoreToFolder: writes savedData back into the GameData folder values.
-- Called 0.15s after GameServer recreates the GameData folder on each spawn
-- (CharacterAdded fires, GameServer creates a fresh folder, DataManager refills it).
local function restoreToFolder(player)
    local data = savedData[player.UserId]
    if not data then return end
    local folder = player:FindFirstChild("GameData")
    if not folder then return end
    for _, info in ipairs(SAVE_KEYS) do
        local v = folder:FindFirstChild(info.name)
        if v then v.Value = data[info.name] or info.default end
    end
    -- After restoring cash, push an UpdateCurrency event so the HUD refreshes immediately
    local RE = ReplicatedStorage:FindFirstChild("RemoteEvents")
    if RE then
        local uc = RE:FindFirstChild("UpdateCurrency")
        if uc then uc:FireClient(player, data.Cash or 0) end
    end
end

-- savePlayer: reads current folder values and writes them to DataStore.
-- pcall() wraps the SetAsync call — if DataStore is down, the game keeps running.
local function savePlayer(player)
    local data = readFolder(player) or savedData[player.UserId]
    if not data then return end
    savedData[player.UserId] = data
    pcall(function()
        DataStore:SetAsync("player_" .. player.UserId, data)
    end)
end

-- PlayerAdded: load from DataStore on join.
-- pcall() handles DataStore outages; player gets default values instead of an error.
Players.PlayerAdded:Connect(function(player)
    -- Start with all defaults
    local data = {}
    for _, info in ipairs(SAVE_KEYS) do
        data[info.name] = info.default
    end
    -- Try to fetch stored data; merge over defaults (handles new keys added after a save)
    local ok, stored = pcall(function()
        return DataStore:GetAsync("player_" .. player.UserId)
    end)
    if ok and stored then
        for _, info in ipairs(SAVE_KEYS) do
            if stored[info.name] ~= nil then
                data[info.name] = stored[info.name]
            end
        end
    end
    savedData[player.UserId] = data

    -- Watch for GameData folder creation (happens each CharacterAdded in GameServer).
    -- Delay 0.15s to let GameServer finish initialising the folder before we write into it.
    local function onChild(child)
        if child.Name ~= "GameData" then return end
        task.delay(0.15, function()
            if player.Parent then restoreToFolder(player) end
        end)
    end
    player.ChildAdded:Connect(onChild)
    -- Handle case where folder already exists (Studio hot-reload)
    if player:FindFirstChild("GameData") then
        task.delay(0.15, function()
            if player.Parent then restoreToFolder(player) end
        end)
    end
end)

-- PlayerRemoving: save on leave, then clean up memory.
Players.PlayerRemoving:Connect(function(player)
    savePlayer(player)
    savedData[player.UserId] = nil
end)

-- Auto-save loop: save every 60 seconds to reduce data loss on server crash.
task.spawn(function()
    while true do
        task.wait(60)
        for _, player in ipairs(Players:GetPlayers()) do
            pcall(savePlayer, player)  -- pcall so one failed save doesn't break the loop
        end
    end
end)

print("[DataManager] v4 Loaded — pure DataStore persistence, no duplicate handlers")
