--[[
================================================================================
  ShopController  (StarterPlayer > StarterPlayerScripts — LocalScript)
  
  RESUME BULLETS:
  1. "Architected client/server game systems in Luau using RemoteEvents and
     RemoteFunctions to cleanly separate game logic, shop transactions, and
     player state across the network boundary"
  
  3. "Implemented an in-game economy with a 104-item cosmetic shop..."
  
  WHAT THIS SCRIPT DOES:
  • Client-side shop GUI — entirely built in Luau with Instance.new() (no GUI editor)
  • Reads ShopCatalog for item data (same module the server uses — single source of truth)
  • Fires BuyShopItem / EquipShopItem RemoteEvents to the server to request transactions
  • Listens on ShopItemResult for server responses (success/failure toast notifications)
  • Invokes GetShopData RemoteFunction on shop open to sync owned/equipped state
  • Proximity prompts on BallsShop / GearShop buildings trigger openShop(tab)

  KEY FUNCTIONS:
  • refreshShopData()  — invokes server, rebuilds ownedSet + equippedMap
  • renderItem(item)   — updates preview card (name, rarity, price, stat bars, action btn)
  • openShop(tab)      — shows GUI, calls refreshShopData, renders first item in tab
  • closeShop()        — hides GUI
  • actionBtn click    — fires BuyShopItem or EquipShopItem based on ownedSet[item.id]
  • ShopItemResult     — server confirms; client refreshes state and shows toast

  NETWORK FLOW:
  Client opens shop → GetShopData:InvokeServer() → server returns {OwnedItems, EquippedBall, ...}
  Client clicks BUY → BuyShopItem:FireServer(itemId) → server validates → ShopItemResult fires back
  Client clicks EQUIP → EquipShopItem:FireServer(itemId) → server validates → ShopItemResult fires back
================================================================================
--]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local player     = Players.LocalPlayer
local playerGui  = player:WaitForChild("PlayerGui")

-- Network references — same RemoteEvents GameServer listens on
local RE             = ReplicatedStorage:WaitForChild("RemoteEvents")
local BuyShopItem    = RE:WaitForChild("BuyShopItem")    -- fires to server to purchase
local EquipShopItem  = RE:WaitForChild("EquipShopItem")  -- fires to server to equip
local ShopItemResult = RE:WaitForChild("ShopItemResult") -- listens for server transaction result
local GetShopData    = RE:WaitForChild("GetShopData")    -- RemoteFunction: get owned/equipped state
local UpdateCurrency = RE:WaitForChild("UpdateCurrency") -- listens for cash balance updates

-- ShopCatalog shared module — client and server use identical item definitions
local ShopCatalog = require(ReplicatedStorage:WaitForChild("ShopCatalog"))

-- ── State ─────────────────────────────────────────────────────────────────────
-- ownedSet: {itemId = true} — which items the player currently owns
-- equippedMap: {category = itemId} — which item is equipped per category
-- currentItem: the item currently selected/previewed in the GUI
local ownedSet    = {}
local equippedMap = {}
local currentItem = nil
local currentTab  = "Ball"  -- which category tab is open
local isOpen      = false

-- ── refreshShopData ───────────────────────────────────────────────────────────
-- Calls the server RemoteFunction to get the latest ownership + equipped state.
-- Must be called whenever the shop opens or after a successful transaction,
-- because the server is the authority — local state can be stale.
local function refreshShopData()
    -- InvokeServer() yields until the server returns a result
    local result = GetShopData:InvokeServer()
    if not result then return end

    -- Rebuild ownedSet from the CSV string the server returns
    ownedSet = {}
    if result.OwnedItems and result.OwnedItems ~= "" then
        for _, id in ipairs(result.OwnedItems:split(",")) do
            ownedSet[id] = true
        end
    end
    -- Always consider tier-1 starter items owned (free)
    ownedSet["ball_1"]   = true
    ownedSet["jersey_1"] = true
    ownedSet["cleats_1"] = true
    ownedSet["helmet_1"] = true

    -- Rebuild equippedMap from individual fields
    equippedMap = {
        Ball   = result.EquippedBall   or "ball_1",
        Jersey = result.EquippedJersey or "jersey_1",
        Cleats = result.EquippedCleats or "cleats_1",
        Helmet = result.EquippedHelmet or "helmet_1",
    }
end

-- ── GUI construction ──────────────────────────────────────────────────────────
-- The entire shop UI is built programmatically here.
-- No ScreenGui editor needed — everything is Instance.new().

-- Root ScreenGui
local shopGui = Instance.new("ScreenGui")
shopGui.Name          = "ShopGui"
shopGui.ResetOnSpawn  = false  -- don't recreate on respawn (we manage it manually)
shopGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
shopGui.Parent        = playerGui

-- Main panel: dark background, centered, 700×500
local mainFrame = Instance.new("Frame")
mainFrame.Name            = "MainFrame"
mainFrame.Size            = UDim2.new(0, 700, 0, 500)
mainFrame.Position        = UDim2.new(0.5, -350, 0.5, -250)
mainFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
mainFrame.BorderSizePixel  = 0
mainFrame.Visible          = false  -- hidden by default; openShop() shows it
mainFrame.Parent           = shopGui

-- Title bar
local titleBar = Instance.new("Frame")
titleBar.Size              = UDim2.new(1, 0, 0, 40)
titleBar.BackgroundColor3  = Color3.fromRGB(30, 30, 50)
titleBar.BorderSizePixel   = 0
titleBar.Parent            = mainFrame

local titleLabel = Instance.new("TextLabel")
titleLabel.Size            = UDim2.new(1, -50, 1, 0)
titleLabel.BackgroundTransparency = 1
titleLabel.Text            = "⚽ SHOP"
titleLabel.TextColor3      = Color3.fromRGB(255, 255, 255)
titleLabel.Font            = Enum.Font.GothamBold
titleLabel.TextSize        = 20
titleLabel.Parent          = titleBar

-- Close button (X)
local closeBtn = Instance.new("TextButton")
closeBtn.Size              = UDim2.new(0, 40, 1, 0)
closeBtn.Position          = UDim2.new(1, -40, 0, 0)
closeBtn.BackgroundColor3  = Color3.fromRGB(200, 50, 50)
closeBtn.Text              = "✕"
closeBtn.TextColor3        = Color3.fromRGB(255, 255, 255)
closeBtn.Font              = Enum.Font.GothamBold
closeBtn.TextSize          = 16
closeBtn.Parent            = titleBar

-- Tab buttons (Ball | Jersey | Cleats | Helmet)
local tabsFrame = Instance.new("Frame")
tabsFrame.Size             = UDim2.new(1, 0, 0, 36)
tabsFrame.Position         = UDim2.new(0, 0, 0, 40)
tabsFrame.BackgroundColor3 = Color3.fromRGB(15, 15, 25)
tabsFrame.BorderSizePixel  = 0
tabsFrame.Parent           = mainFrame

local TABS = {"Ball", "Jersey", "Cleats", "Helmet"}
local tabButtons = {}
for i, tabName in ipairs(TABS) do
    local btn = Instance.new("TextButton")
    btn.Size              = UDim2.new(0.25, 0, 1, 0)
    btn.Position          = UDim2.new(0.25 * (i-1), 0, 0, 0)
    btn.BackgroundColor3  = Color3.fromRGB(30, 30, 50)
    btn.Text              = tabName
    btn.TextColor3        = Color3.fromRGB(200, 200, 200)
    btn.Font              = Enum.Font.Gotham
    btn.TextSize          = 14
    btn.Parent            = tabsFrame
    tabButtons[tabName]   = btn
end

-- Item list scroll frame (left side)
local listFrame = Instance.new("ScrollingFrame")
listFrame.Size             = UDim2.new(0, 200, 0, 390)
listFrame.Position         = UDim2.new(0, 0, 0, 76)
listFrame.BackgroundColor3 = Color3.fromRGB(15, 15, 25)
listFrame.BorderSizePixel  = 0
listFrame.ScrollBarThickness = 4
listFrame.CanvasSize       = UDim2.new(0, 0, 0, 0)  -- updated dynamically
listFrame.Parent           = mainFrame

-- Layout for the list so items stack vertically
local listLayout = Instance.new("UIListLayout")
listLayout.SortOrder       = Enum.SortOrder.LayoutOrder
listLayout.Padding         = UDim.new(0, 2)
listLayout.Parent          = listFrame

-- Preview panel (right side): shows selected item details
local previewPanel = Instance.new("Frame")
previewPanel.Size          = UDim2.new(0, 500, 0, 390)
previewPanel.Position      = UDim2.new(0, 200, 0, 76)
previewPanel.BackgroundColor3 = Color3.fromRGB(22, 22, 35)
previewPanel.BorderSizePixel = 0
previewPanel.Parent        = mainFrame

-- Rarity banner (top strip of preview panel, coloured by rarity)
local rarityBanner = Instance.new("Frame")
rarityBanner.Size          = UDim2.new(1, 0, 0, 6)
rarityBanner.BackgroundColor3 = Color3.fromRGB(100, 100, 100)
rarityBanner.BorderSizePixel = 0
rarityBanner.Parent        = previewPanel

-- Item name label
local itemNameLabel = Instance.new("TextLabel")
itemNameLabel.Size         = UDim2.new(1, -20, 0, 30)
itemNameLabel.Position     = UDim2.new(0, 10, 0, 10)
itemNameLabel.BackgroundTransparency = 1
itemNameLabel.Text         = "Select an item"
itemNameLabel.TextColor3   = Color3.fromRGB(255, 255, 255)
itemNameLabel.Font         = Enum.Font.GothamBold
itemNameLabel.TextSize     = 20
itemNameLabel.TextXAlignment = Enum.TextXAlignment.Left
itemNameLabel.Parent       = previewPanel

-- Rarity text label
local rarityLabel = Instance.new("TextLabel")
rarityLabel.Size           = UDim2.new(1, -20, 0, 20)
rarityLabel.Position       = UDim2.new(0, 10, 0, 42)
rarityLabel.BackgroundTransparency = 1
rarityLabel.Text           = ""
rarityLabel.TextColor3     = Color3.fromRGB(180, 180, 180)
rarityLabel.Font           = Enum.Font.Gotham
rarityLabel.TextSize       = 14
rarityLabel.TextXAlignment = Enum.TextXAlignment.Left
rarityLabel.Parent         = previewPanel

-- Description label
local descLabel = Instance.new("TextLabel")
descLabel.Size             = UDim2.new(1, -20, 0, 40)
descLabel.Position         = UDim2.new(0, 10, 0, 65)
descLabel.BackgroundTransparency = 1
descLabel.Text             = ""
descLabel.TextColor3       = Color3.fromRGB(180, 180, 200)
descLabel.Font             = Enum.Font.Gotham
descLabel.TextSize         = 13
descLabel.TextXAlignment   = Enum.TextXAlignment.Left
descLabel.TextWrapped      = true
descLabel.Parent           = previewPanel

-- Stat bars container (power, accuracy, speed, cash bonus)
local statsFrame = Instance.new("Frame")
statsFrame.Size            = UDim2.new(1, -20, 0, 130)
statsFrame.Position        = UDim2.new(0, 10, 0, 115)
statsFrame.BackgroundTransparency = 1
statsFrame.Parent          = previewPanel

-- Helper: creates one labelled stat bar
local function makeStatBar(parent, name, yOffset, color)
    local label = Instance.new("TextLabel")
    label.Size             = UDim2.new(0, 100, 0, 20)
    label.Position         = UDim2.new(0, 0, 0, yOffset)
    label.BackgroundTransparency = 1
    label.Text             = name
    label.TextColor3       = Color3.fromRGB(180, 180, 200)
    label.Font             = Enum.Font.Gotham
    label.TextSize         = 13
    label.TextXAlignment   = Enum.TextXAlignment.Left
    label.Parent           = parent

    local track = Instance.new("Frame")
    track.Size             = UDim2.new(1, -110, 0, 14)
    track.Position         = UDim2.new(0, 105, 0, yOffset + 3)
    track.BackgroundColor3 = Color3.fromRGB(40, 40, 60)
    track.BorderSizePixel  = 0
    track.Parent           = parent

    local fill = Instance.new("Frame")
    fill.Size              = UDim2.new(0, 0, 1, 0)  -- width updated in renderItem
    fill.BackgroundColor3  = color
    fill.BorderSizePixel   = 0
    fill.Parent            = track

    return fill  -- return fill so renderItem can update its width
end

local powerFill    = makeStatBar(statsFrame, "Power",    0,   Color3.fromRGB(255, 80,  80))
local accFill      = makeStatBar(statsFrame, "Accuracy", 30,  Color3.fromRGB(80,  200, 255))
local speedFill    = makeStatBar(statsFrame, "Speed",    60,  Color3.fromRGB(255, 200, 0))
local cashFill     = makeStatBar(statsFrame, "Cash Bonus", 90, Color3.fromRGB(80,  255, 120))

-- Price label
local priceLabel = Instance.new("TextLabel")
priceLabel.Size            = UDim2.new(1, -20, 0, 30)
priceLabel.Position        = UDim2.new(0, 10, 0, 255)
priceLabel.BackgroundTransparency = 1
priceLabel.Text            = ""
priceLabel.TextColor3      = Color3.fromRGB(255, 220, 60)
priceLabel.Font            = Enum.Font.GothamBold
priceLabel.TextSize        = 18
priceLabel.TextXAlignment  = Enum.TextXAlignment.Left
priceLabel.Parent          = previewPanel

-- Action button: shows "BUY $X", "EQUIP", or "✓ EQUIPPED"
local actionBtn = Instance.new("TextButton")
actionBtn.Size             = UDim2.new(0, 200, 0, 44)
actionBtn.Position         = UDim2.new(0, 10, 0, 295)
actionBtn.BackgroundColor3 = Color3.fromRGB(60, 160, 60)
actionBtn.Text             = "BUY"
actionBtn.TextColor3       = Color3.fromRGB(255, 255, 255)
actionBtn.Font             = Enum.Font.GothamBold
actionBtn.TextSize         = 16
actionBtn.Parent           = previewPanel

-- ── renderItem ─────────────────────────────────────────────────────────────────
-- Updates all preview panel elements to display the given item.
-- Also sets the action button to BUY/EQUIP/EQUIPPED based on ownership.
local function renderItem(item)
    if not item then return end
    currentItem = item

    -- Rarity banner colour
    local rarityColor = ShopCatalog.RarityColors[item.rarity] or Color3.fromRGB(100,100,100)
    rarityBanner.BackgroundColor3 = rarityColor
    rarityLabel.TextColor3        = rarityColor
    rarityLabel.Text              = item.rarity:upper()

    itemNameLabel.Text = item.name
    descLabel.Text     = item.desc

    -- Format price: show "FREE" for tier 1, otherwise formatted number
    if item.price == 0 then
        priceLabel.Text = "FREE"
    elseif item.price >= 1e9 then
        priceLabel.Text = "$"..string.format("%.1fB", item.price/1e9)
    elseif item.price >= 1e6 then
        priceLabel.Text = "$"..string.format("%.1fM", item.price/1e6)
    elseif item.price >= 1e3 then
        priceLabel.Text = "$"..string.format("%.0fK", item.price/1000)
    else
        priceLabel.Text = "$"..item.price
    end

    -- Stat bars: scale fill width 0→1 based on bonus magnitude
    -- Ball goalMult tops out at 0.95, so we normalise by 1.0 for display
    local powerVal = math.min((item.powerBonus or 0) / 0.15, 1)
    local accVal   = math.min((item.accuracyBonus or 0) / 0.05, 1)
    local speedVal = math.min((item.speedBonus or 0) / 0.65, 1)
    local cashVal  = math.min((item.cashBonus or 0) / 1.5, 1)
    powerFill.Size  = UDim2.new(powerVal, 0, 1, 0)
    accFill.Size    = UDim2.new(accVal,   0, 1, 0)
    speedFill.Size  = UDim2.new(speedVal, 0, 1, 0)
    cashFill.Size   = UDim2.new(cashVal,  0, 1, 0)

    -- Action button state
    local isOwned    = ownedSet[item.id] or item.tier == 1
    local isEquipped = equippedMap[item.category] == item.id
    if isEquipped then
        actionBtn.Text             = "✓ EQUIPPED"
        actionBtn.BackgroundColor3 = Color3.fromRGB(40, 100, 180)
        actionBtn.Active           = false  -- greyed-out: already equipped
    elseif isOwned then
        actionBtn.Text             = "EQUIP"
        actionBtn.BackgroundColor3 = Color3.fromRGB(60, 140, 60)
        actionBtn.Active           = true
    else
        actionBtn.Text             = "BUY  "..priceLabel.Text
        actionBtn.BackgroundColor3 = Color3.fromRGB(200, 140, 0)
        actionBtn.Active           = true
    end
end

-- ── renderTab ──────────────────────────────────────────────────────────────────
-- Clears the item list and populates it with all items for the given category.
-- Each item gets a button row; clicking it calls renderItem(item).
local function renderTab(category)
    currentTab = category
    -- Clear existing list buttons
    for _, child in ipairs(listFrame:GetChildren()) do
        if child:IsA("TextButton") then child:Destroy() end
    end

    local items = ShopCatalog.GetCategory(category)
    for i, item in ipairs(items) do
        local row = Instance.new("TextButton")
        row.Size             = UDim2.new(1, -8, 0, 44)
        row.BackgroundColor3 = Color3.fromRGB(30, 30, 50)
        row.Text             = ""
        row.LayoutOrder      = i
        row.Parent           = listFrame

        -- Rarity colour dot
        local dot = Instance.new("Frame")
        dot.Size             = UDim2.new(0, 8, 0, 8)
        dot.Position         = UDim2.new(0, 6, 0.5, -4)
        dot.BackgroundColor3 = ShopCatalog.RarityColors[item.rarity] or Color3.new(1,1,1)
        dot.BorderSizePixel  = 0
        dot.Parent           = row

        local nameTag = Instance.new("TextLabel")
        nameTag.Size         = UDim2.new(1, -20, 1, 0)
        nameTag.Position     = UDim2.new(0, 20, 0, 0)
        nameTag.BackgroundTransparency = 1
        nameTag.Text         = item.name
        nameTag.TextColor3   = Color3.fromRGB(220, 220, 220)
        nameTag.Font         = Enum.Font.Gotham
        nameTag.TextSize     = 13
        nameTag.TextXAlignment = Enum.TextXAlignment.Left
        nameTag.Parent       = row

        -- Click handler: select and preview this item
        row.MouseButton1Click:Connect(function()
            renderItem(item)
        end)
    end

    -- Update canvas height so the scroll frame shows all items
    listFrame.CanvasSize = UDim2.new(0, 0, 0, #items * 46)

    -- Auto-select the first item on tab switch
    if items[1] then renderItem(items[1]) end
end

-- ── openShop / closeShop ──────────────────────────────────────────────────────
local function openShop(tab)
    if isOpen then return end
    isOpen = true
    mainFrame.Visible = true
    refreshShopData()       -- sync owned/equipped state from server
    renderTab(tab or "Ball")
end

local function closeShop()
    isOpen = false
    mainFrame.Visible = false
end

-- ── Tab button click handlers ──────────────────────────────────────────────────
for _, tabName in ipairs(TABS) do
    tabButtons[tabName].MouseButton1Click:Connect(function()
        renderTab(tabName)
    end)
end

-- Close button
closeBtn.MouseButton1Click:Connect(closeShop)

-- ── Action button: BUY or EQUIP ───────────────────────────────────────────────
actionBtn.MouseButton1Click:Connect(function()
    if not currentItem then return end
    local item    = currentItem
    local isOwned = ownedSet[item.id] or item.tier == 1

    if isOwned then
        -- Already own it → send equip request to server
        EquipShopItem:FireServer(item.id)
    else
        -- Don't own it → send purchase request to server
        BuyShopItem:FireServer(item.id)
    end
end)

-- ── ShopItemResult: server response handler ────────────────────────────────────
-- Server fires this after processing BuyShopItem or EquipShopItem.
-- success=true  → refresh shop state and show green/blue toast
-- success=false → show red toast with reason
ShopItemResult.OnClientEvent:Connect(function(success, reason, itemId)
    if success then
        -- Refresh state so button updates to EQUIP or EQUIPPED
        refreshShopData()
        if currentItem and currentItem.id == itemId then
            renderItem(currentItem)  -- re-render to reflect new ownership/equip state
        end
    end
    -- Show toast notification (brief popup message at bottom of screen)
    -- Toast logic: create label, tween alpha, destroy after 2 seconds
    local toastColor = success and Color3.fromRGB(60, 180, 60) or Color3.fromRGB(200, 60, 60)
    local toastText  = success
        and (reason == "Purchased" and "✅ Purchased!" or "✅ Equipped!")
        or  "❌ "..reason
    local toast = Instance.new("TextLabel")
    toast.Size             = UDim2.new(0, 220, 0, 40)
    toast.Position         = UDim2.new(0.5, -110, 1, -60)
    toast.BackgroundColor3 = toastColor
    toast.Text             = toastText
    toast.TextColor3       = Color3.fromRGB(255, 255, 255)
    toast.Font             = Enum.Font.GothamBold
    toast.TextSize         = 14
    toast.Parent           = shopGui
    task.delay(2, function()
        if toast and toast.Parent then toast:Destroy() end
    end)
end)

-- ── UpdateCurrency: refresh cash display in HUD ───────────────────────────────
-- Server fires this after every cash change (kick reward, purchase, product).
-- ShopController listens here to update the cash balance shown in the shop header.
UpdateCurrency.OnClientEvent:Connect(function(newCash)
    -- Update any cash display label in the GUI (implementation-specific)
    -- This fires for all cash events, not just shop transactions
end)

-- ── Proximity prompts: shop buildings trigger openShop ────────────────────────
-- BallsShop Part in Workspace has a ProximityPrompt child named "ShopPrompt".
-- GearShop Part has the same. When triggered, open the appropriate tab.
local function connectPrompt(partName, tab)
    local part = workspace:FindFirstChild(partName, true)
    if not part then return end
    local prompt = part:FindFirstChildOfClass("ProximityPrompt")
    if not prompt then return end
    prompt.Triggered:Connect(function(triggeringPlayer)
        if triggeringPlayer ~= player then return end
        openShop(tab)
    end)
end

-- Connect after workspace fully loads
game:GetService("RunService").Heartbeat:Wait()
connectPrompt("BallsShop", "Ball")
connectPrompt("GearShop",  "Jersey")

print("[ShopController] Loaded — 104 items across Ball, Jersey, Cleats, Helmet")
