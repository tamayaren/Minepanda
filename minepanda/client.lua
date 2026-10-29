-- Minepanda customer app. Runs on an Advanced Pocket Computer with a wireless or ender modem.
local Common = require("lib.common")
local UI = require("lib.ui")

-- This program's own path, so its data can live beside it wherever an OS installs it.
local function ProgramPath()
	if (shell and shell.getRunningProgram) then
		return "/" .. shell.getRunningProgram()
	end

	if (debug and debug.getinfo) then
		local Source = debug.getinfo(1, "S").source
		if (type(Source) == "string" and Source:sub(1, 1) == "@") then
			return "/" .. fs.combine(Source:sub(2), "")
		end
	end

	return "/minepanda/client.lua"
end

-- /minepanda/client.lua keeps data in /minepanda/data/client.db, /apps/minepanda.lua in /apps/data/minepanda.db.
local ProgramFile = ProgramPath()
local ProgramName = fs.getName(ProgramFile):gsub("%.lua$", "")
local DataPath = fs.combine(fs.combine(fs.getDir(ProgramFile), "data"), ProgramName .. ".db")

local SearchTime = 1.5
local RequestTimeout = 3
local SyncInterval = 60
local TabOrder = {"Shops", "Orders", "Me"}

local Theme = UI.Theme
local Protocol = Common.Protocol

local Data = Common.Load(DataPath, {})
Data.Orders = Data.Orders or {} -- Newest first
if (Data.ShareLocation == nil) then Data.ShareLocation = true end

local View = {
	Tab = "Shops",
	Shops = {},
	Searched = false,
	Shop = nil, -- {Id, Name, Open, Menu} of the restaurant being browsed
	Cart = {}, -- ItemId -> Qty for View.Shop
	Scroll = {},
	Message = nil,
	MessageColor = nil,
	LastPos = nil
}

local ScreenWidth, ScreenHeight = term.getSize()
local ClockTimer

--

local function SaveData()
	Common.Save(DataPath, Data)
end

local function CustomerName()
	return Data.CustomerName or os.getComputerLabel() or ("Customer " .. os.getComputerID())
end

-- Shows a message in the footer. Safe to call from any coroutine.
local function Notify(Message, Color)
	View.Message = Message
	View.MessageColor = Color
	os.queueEvent("MinepandaRedraw")
end

local function CountPending()
	local Count = 0
	for _, Order in ipairs(Data.Orders) do
		if (Order.Status == "Pending") then
			Count = Count + 1
		end
	end

	return Count
end

local function Locate(Timeout)
	local X, Y, Z = gps.locate(Timeout)
	if (not X) then return nil end

	View.LastPos = {X = math.floor(X + 0.5), Y = math.floor(Y + 0.5), Z = math.floor(Z + 0.5)}
	return View.LastPos
end

-- Sends Message to a restaurant and waits for its reply of ReplyType. Returns the reply, or nil.
local function Request(ShopId, Message, ReplyType, Timeout)
	Message.Ref = Common.NewRef()
	rednet.send(ShopId, Message, Protocol)

	local Deadline = os.clock() + (Timeout or RequestTimeout)
	while (true) do
		local Remaining = Deadline - os.clock()
		if (Remaining <= 0) then return nil end

		local Sender, Reply = rednet.receive(Protocol, Remaining)
		if (not Sender) then return nil end

		if (Sender == ShopId and type(Reply) == "table" and Reply.Type == ReplyType and Reply.Ref == Message.Ref) then
			return Reply
		end
	end
end

local function SearchShops()
	UI.Busy("Searching...")

	local Ref = Common.NewRef()
	rednet.broadcast({Type = "Hello", Ref = Ref}, Protocol)

	local Found, Seen = {}, {}
	local Deadline = os.clock() + SearchTime
	while (os.clock() < Deadline) do
		local Sender, Reply = rednet.receive(Protocol, Deadline - os.clock())
		if (not Sender) then break end

		if (not Seen[Sender] and type(Reply) == "table" and Reply.Type == "Info" and Reply.Ref == Ref) then
			Seen[Sender] = true
			Found[#Found + 1] = {
				Id = Sender,
				Name = tostring(Reply.Name),
				Open = Reply.Open == true,
				Items = tonumber(Reply.Items) or 0
			}
		end
	end

	table.sort(Found, function(A, B)
		return A.Name:lower() < B.Name:lower()
	end)
	View.Shops = Found
	View.Searched = true
	View.Scroll.Shops = 0

	if (#Found == 0) then
		Notify("No restaurants in range.", Theme.Bad)
	else
		Notify("Found " .. Common.Plural("restaurant", #Found) .. ".", colors.lime)
	end
end

local function CleanMenu(Menu)
	local Clean = {}
	if (type(Menu) ~= "table") then return Clean end

	for _, Item in ipairs(Menu) do
		if (type(Item) == "table" and type(Item.Id) == "number") then
			Clean[#Clean + 1] = {
				Id = Item.Id,
				Name = tostring(Item.Name or "?"),
				Price = Common.CleanPrice(Item.Price)
			}
		end
	end

	return Clean
end

local function OpenShop(ShopId, Name)
	UI.Busy("Loading the menu...")
	local Reply = Request(ShopId, {Type = "Menu"}, "MenuResult")
	if (not Reply) then
		Notify("Couldn't reach " .. Name .. ". Move closer and try again.", Theme.Bad)
		return
	end

	-- Keep the cart when reloading the same restaurant.
	if (not View.Shop or View.Shop.Id ~= ShopId) then
		View.Cart = {}
		View.Scroll.Shop = 0
	end
	View.Shop = {
		Id = ShopId,
		Name = tostring(Reply.Name or Name),
		Open = Reply.Open == true,
		Menu = CleanMenu(Reply.Menu)
	}
end

local function ChangeQty(ItemId, Delta)
	local Qty = math.max(0, math.min(Common.MaxQty, (View.Cart[ItemId] or 0) + Delta))
	if (Qty == 0) then
		View.Cart[ItemId] = nil
	else
		View.Cart[ItemId] = Qty
	end
end

-- Returns the cart's lines, total price and number of items, skipping items no longer on the menu.
local function CartSummary()
	local Lines, Total, Count = {}, Common.NewPrice(), 0
	for _, Item in ipairs(View.Shop.Menu) do
		local Qty = View.Cart[Item.Id] or 0
		if (Qty > 0) then
			Lines[#Lines + 1] = {Id = Item.Id, Name = Item.Name, Qty = Qty}
			Total = Common.AddPrice(Total, Item.Price, Qty)
			Count = Count + Qty
		end
	end

	return Lines, Total, Count
end

local function PlaceOrder()
	local Shop = View.Shop
	local Lines, Total, Count = CartSummary()
	if (Count == 0) then return end

	local Summary = {
		Common.Plural("item", Count) .. " from " .. Shop.Name .. ".",
		{Parts = Common.PriceParts(Total)},
		"Pay the courier on delivery."
	}
	if (not UI.Confirm("Place order?", Summary, "Order", Theme.Good)) then return end

	local Pos = nil
	if (Data.ShareLocation) then
		UI.Busy("Locating you...")
		Pos = Locate(1)
	end

	UI.Busy("Sending your order...")
	local Wanted = {}
	for Index, Line in ipairs(Lines) do
		Wanted[Index] = {Id = Line.Id, Qty = Line.Qty}
	end
	local Reply = Request(Shop.Id, {
		Type = "Order",
		Items = Wanted,
		Customer = CustomerName(),
		Label = os.getComputerLabel(),
		Pos = Pos
	}, "OrderResult")

	if (not Reply) then
		Notify("No answer from " .. Shop.Name .. ". Try again.", Theme.Bad)
		return
	end
	if (not Reply.Ok) then
		-- Reload the menu in case it changed; the cart keeps whatever is still on it.
		local Reason = tostring(Reply.Error or "The order was refused.")
		OpenShop(Shop.Id, Shop.Name)
		Notify(Reason, Theme.Bad)
		return
	end

	local OrderTotal = Total
	if (type(Reply.Total) == "table") then
		OrderTotal = Reply.Total
	end
	table.insert(Data.Orders, 1, {
		RestaurantId = Shop.Id,
		RestaurantName = tostring(Reply.Restaurant or Shop.Name),
		OrderId = Reply.OrderId,
		Items = Lines,
		Total = OrderTotal,
		Status = "Pending",
		Day = os.day(),
		Time = os.time()
	})
	SaveData()

	View.Cart = {}
	View.Tab = "Orders"
	View.Scroll.Orders = 0
	Notify("Order #" .. Reply.OrderId .. " placed! Pay on delivery.", colors.lime)
end

local function CancelOrder(Order)
	local Lines = {"From " .. Order.RestaurantName .. "."}
	if (not UI.Confirm("Cancel order #" .. Order.OrderId .. "?", Lines, "Cancel it", Theme.Bad, "Keep")) then return end
	if (Order.Status ~= "Pending") then return end

	UI.Busy("Cancelling...")
	local Reply = Request(Order.RestaurantId, {Type = "Cancel", OrderId = Order.OrderId}, "CancelResult")
	if (not Reply) then
		Notify("Couldn't reach " .. Order.RestaurantName .. ".", Theme.Bad)
		return
	end

	if (Common.Status[Reply.Status]) then
		Order.Status = Reply.Status
		SaveData()
	end

	if (Reply.Ok) then
		Notify("Order #" .. Order.OrderId .. " cancelled.", Theme.Muted)
	else
		Notify(tostring(Reply.Error or "Couldn't cancel that order."), Theme.Bad)
	end
end

local function RemoveOrder(Order)
	for Index, EachOrder in ipairs(Data.Orders) do
		if (EachOrder == Order) then
			table.remove(Data.Orders, Index)
			SaveData()
			return
		end
	end
end

local function ClearFinished()
	local Finished = #Data.Orders - CountPending()
	local Lines = {"Remove " .. Common.Plural("finished order", Finished) .. " from this list?"}
	if (not UI.Confirm("Clear orders", Lines, "Clear", Theme.Bad)) then return end

	for Index = #Data.Orders, 1, -1 do
		if (Data.Orders[Index].Status ~= "Pending") then
			table.remove(Data.Orders, Index)
		end
	end
	SaveData()
end

-- Asks each restaurant about our pending orders.
-- Returns how many orders changed and how many restaurants didn't answer.
local function SyncOrders(ShowBusy)
	local IdsByShop = {}
	for _, Order in ipairs(Data.Orders) do
		if (Order.Status == "Pending") then
			IdsByShop[Order.RestaurantId] = IdsByShop[Order.RestaurantId] or {}
			table.insert(IdsByShop[Order.RestaurantId], Order.OrderId)
		end
	end

	local Changed, Unreachable = 0, 0
	for ShopId, Ids in pairs(IdsByShop) do
		if (ShowBusy) then
			UI.Busy("Checking orders...")
		end

		local Reply = Request(ShopId, {Type = "Status", Ids = Ids}, "StatusResult", 2)
		if (Reply and type(Reply.Statuses) == "table") then
			for _, Order in ipairs(Data.Orders) do
				local Status = Reply.Statuses[Order.OrderId]
				if (Order.RestaurantId == ShopId and Order.Status == "Pending" and Status ~= "Pending" and Common.Status[Status]) then
					Order.Status = Status
					Changed = Changed + 1
				end
			end
		else
			Unreachable = Unreachable + 1
		end
	end

	if (Changed > 0) then
		SaveData()
	end
	return Changed, Unreachable
end

local function SyncNow()
	local Changed, Unreachable = SyncOrders(true)
	if (Unreachable > 0) then
		Notify(Common.Plural("restaurant", Unreachable) .. " didn't answer.", Theme.Bad)
	elseif (Changed > 0) then
		Notify(Common.Plural("order", Changed) .. " updated.", colors.lime)
	else
		Notify("Your orders are up to date.", Theme.Muted)
	end
end

local function EditName()
	local Name = UI.Prompt("Your name", "Shown to restaurants", CustomerName(), {MaxLen = Common.MaxName})
	if (Name == nil) then return end

	Data.CustomerName = Common.CleanName(Name)
	SaveData()
	Notify("Restaurants will see you as " .. CustomerName() .. ".", colors.lime)
end

local function LocateNow()
	UI.Busy("Asking GPS...")
	if (Locate(2)) then
		Notify("Location found.", colors.lime)
	else
		Notify("No GPS signal here.", Theme.Bad)
	end
end

--

local function SelectTab(Key)
	View.Tab = Key
end

local function ScrollBy(Key, Delta)
	View.Scroll[Key] = (View.Scroll[Key] or 0) + Delta
end

-- The scroll key of the list on screen, or nil when the screen has no list.
local function CurrentListKey()
	if (View.Tab == "Shops" and View.Shop) then return "Shop" end
	if (View.Tab == "Shops") then return "Shops" end
	if (View.Tab == "Orders") then return "Orders" end

	return nil
end

local function DrawList(Key, Rows, Y1, Y2)
	View.Scroll[Key] = UI.List(Rows, Y1, Y2, View.Scroll[Key], function(Delta)
		ScrollBy(Key, Delta)
	end)
end

local function DefaultHint()
	if (View.Tab == "Shops" and View.Shop) then return "Pay the courier on delivery." end
	if (View.Tab == "Shops") then return "Tap a restaurant to open it." end
	if (View.Tab == "Orders") then return "Updates arrive automatically." end

	return "Settings save automatically."
end

local function DrawHeader()
	UI.Header("Minepanda", textutils.formatTime(os.time(), true) .. " ")
end

local function DrawTabs()
	local Pending = CountPending()
	local OrdersLabel = "Orders"
	if (Pending > 0) then
		OrdersLabel = "Orders (" .. Pending .. ")"
	end

	UI.Tabs(2, {
		{Key = "Shops", Label = "Shops"},
		{Key = "Orders", Label = OrdersLabel},
		{Key = "Me", Label = "Me"}
	}, View.Tab, SelectTab)
end

local function DrawFooter()
	if (not rednet.isOpen()) then
		UI.Footer("No modem!", Theme.Bad)
	elseif (View.Message) then
		UI.Footer(View.Message, View.MessageColor)
	else
		UI.Footer(DefaultHint())
	end
end

local function StatusText(Open)
	if (Open) then return "Open", colors.lime end

	return "Closed", colors.red
end

-- Shops tab

local function DrawShopList()
	UI.Text(2, 3, "Restaurants", Theme.Text, Theme.Bg)
	UI.Button(ScreenWidth - UI.ButtonWidth("Search"), 3, "Search", Theme.Accent, Theme.OnAccent, SearchShops)

	local Width = ScreenWidth - 1
	local Rows = {}
	for _, Shop in ipairs(View.Shops) do
		local function Enter()
			OpenShop(Shop.Id, Shop.Name)
		end

		Rows[#Rows + 1] = function(Y)
			UI.Fill(1, Y, Width, 1, Theme.Card)
			UI.OnClick(1, Y, Width, Y, Enter)

			local Status, Color = StatusText(Shop.Open)
			UI.Text(2, Y, UI.Fit(Shop.Name, Width - #Status - 3), Theme.Text, Theme.Card)
			UI.Text(Width - #Status, Y, Status, Color, Theme.Card)
		end

		Rows[#Rows + 1] = function(Y)
			UI.Fill(1, Y, Width, 1, Theme.Card)
			UI.OnClick(1, Y, Width, Y, Enter)
			UI.Text(2, Y, Common.Plural("item", Shop.Items), Theme.Muted, Theme.Card)
			UI.Text(Width - 5, Y, "Menu\16", Theme.Text, Theme.Card)
		end

		Rows[#Rows + 1] = function() end
	end

	if (#Rows > 0) then
		DrawList("Shops", Rows, 5, ScreenHeight - 1)
	elseif (View.Searched) then
		UI.Centered(4, ScreenHeight - 1, {
			"No restaurants found.",
			"Get closer to one, or use an Ender Modem for unlimited range."
		})
	else
		UI.Centered(4, ScreenHeight - 1, {"Hungry?", "Tap Search to find restaurants nearby."})
	end
end

local function DrawShop()
	local Shop = View.Shop
	local Width = ScreenWidth - 1

	UI.Fill(1, 3, ScreenWidth, 1, Theme.Card)
	UI.Button(1, 3, "\17", Theme.Card, Theme.Text, function()
		View.Shop = nil
	end)
	local Status, Color = StatusText(Shop.Open)
	UI.Text(5, 3, UI.Fit(Shop.Name, ScreenWidth - #Status - 6), Theme.Text, Theme.Card)
	UI.Text(ScreenWidth - #Status, 3, Status, Color, Theme.Card)

	local Rows = {}
	for Index, Item in ipairs(Shop.Menu) do
		local Bg = Theme.Bg
		if (Index % 2 == 0) then
			Bg = Theme.Card
		end

		Rows[#Rows + 1] = function(Y)
			UI.Fill(1, Y, Width, 1, Bg)

			local Qty = View.Cart[Item.Id] or 0
			local ControlsX
			if (Qty == 0) then
				local AddAction = nil
				if (Shop.Open) then
					AddAction = function()
						ChangeQty(Item.Id, 1)
					end
				end
				ControlsX = Width - UI.ButtonWidth("Add")
				UI.Button(ControlsX, Y, "Add", Theme.Accent, Theme.OnAccent, AddAction)
			else
				local QtyText = (" %2d "):format(Qty)
				ControlsX = Width - UI.ButtonWidth("-") - #QtyText - UI.ButtonWidth("+")
				local X = UI.Button(ControlsX, Y, "-", Theme.Bad, colors.white, function()
					ChangeQty(Item.Id, -1)
				end)
				X = UI.Text(X, Y, QtyText, Theme.Text, Bg)
				UI.Button(X, Y, "+", Theme.Good, colors.white, function()
					ChangeQty(Item.Id, 1)
				end)
			end

			UI.Text(2, Y, UI.Fit(Item.Name, ControlsX - 3), Theme.Text, Bg)
		end

		Rows[#Rows + 1] = function(Y)
			UI.Fill(1, Y, Width, 1, Bg)
			UI.Parts(2, Y, Common.PriceParts(Item.Price), Bg, Width - 1)
		end
	end

	local BarY = ScreenHeight - 2
	if (#Rows > 0) then
		DrawList("Shop", Rows, 4, BarY - 1)
	else
		UI.Centered(4, BarY - 1, {"Nothing on the menu yet.", "Check back later."})
	end

	-- Cart bar
	local _, Total, Count = CartSummary()
	UI.Fill(1, BarY, ScreenWidth, 2, Theme.Card)
	if (not Shop.Open) then
		UI.Text(2, BarY, "Closed right now.", colors.red, Theme.Card)
	elseif (Count == 0) then
		UI.Text(2, BarY, "Tap Add to pick items.", Theme.Muted, Theme.Card)
	else
		local X = UI.Text(2, BarY, "Total ", Theme.Muted, Theme.Card)
		UI.Parts(X, BarY, Common.PriceParts(Total), Theme.Card, ScreenWidth - 1)
	end

	local ClearAction, OrderAction = nil, nil
	if (Count > 0) then
		ClearAction = function()
			View.Cart = {}
		end
		if (Shop.Open) then
			OrderAction = PlaceOrder
		end
	end

	local OrderLabel = "Order"
	if (Count > 0) then
		OrderLabel = "Order (" .. Count .. ")"
	end
	UI.Button(2, BarY + 1, "Clear", colors.lightGray, colors.black, ClearAction)
	UI.Button(ScreenWidth - UI.ButtonWidth(OrderLabel), BarY + 1, OrderLabel, Theme.Good, colors.white, OrderAction)
end

-- Orders tab

local function AddOrderRows(Rows, Order)
	local Width = ScreenWidth - 1
	local Status = Common.Status[Order.Status] or Common.Status.Unknown

	Rows[#Rows + 1] = function(Y)
		UI.Fill(1, Y, Width, 1, Theme.Card)
		local X = UI.Text(2, Y, "#" .. Order.OrderId .. " ", Theme.Text, Theme.Card)
		UI.Text(X, Y, UI.Fit(Order.RestaurantName, Width - X), Theme.Text, Theme.Card)
	end

	Rows[#Rows + 1] = function(Y)
		UI.Fill(1, Y, Width, 1, Theme.Card)
		local X = UI.Text(2, Y, Status.Label, Status.Color, Theme.Card)
		UI.Text(X + 1, Y, UI.Fit(Common.FormatStamp(Order.Day, Order.Time), Width - X - 1), Theme.Muted, Theme.Card)
	end

	Rows[#Rows + 1] = function(Y)
		UI.Fill(1, Y, Width, 1, Theme.Card)
		UI.Text(2, Y, UI.Fit(Common.ItemsText(Order.Items), Width - 2), Theme.Muted, Theme.Card)
	end

	Rows[#Rows + 1] = function(Y)
		UI.Fill(1, Y, Width, 1, Theme.Card)

		local ButtonX
		if (Order.Status == "Pending") then
			ButtonX = Width - UI.ButtonWidth("Cancel")
			UI.Button(ButtonX, Y, "Cancel", Theme.Bad, colors.white, function()
				CancelOrder(Order)
			end)
		else
			ButtonX = Width - UI.ButtonWidth("Remove")
			UI.Button(ButtonX, Y, "Remove", colors.lightGray, colors.black, function()
				RemoveOrder(Order)
			end)
		end

		UI.Parts(2, Y, Common.PriceParts(Order.Total), Theme.Card, ButtonX - 2)
	end

	Rows[#Rows + 1] = function() end
end

local function DrawOrders()
	UI.Text(2, 3, "My orders", Theme.Text, Theme.Bg)

	local Pending = CountPending()
	local SyncAction, ClearAction = nil, nil
	if (Pending > 0) then
		SyncAction = SyncNow
	end
	if (#Data.Orders > Pending) then
		ClearAction = ClearFinished
	end

	local ClearX = ScreenWidth - UI.ButtonWidth("Clear")
	UI.Button(ClearX, 3, "Clear", colors.lightGray, colors.black, ClearAction)
	UI.Button(ClearX - 1 - UI.ButtonWidth("Sync"), 3, "Sync", Theme.Accent, Theme.OnAccent, SyncAction)

	-- Pending orders first, each group newest first.
	local Rows = {}
	for _, Order in ipairs(Data.Orders) do
		if (Order.Status == "Pending") then AddOrderRows(Rows, Order) end
	end
	for _, Order in ipairs(Data.Orders) do
		if (Order.Status ~= "Pending") then AddOrderRows(Rows, Order) end
	end

	if (#Rows > 0) then
		DrawList("Orders", Rows, 5, ScreenHeight - 1)
	else
		UI.Centered(4, ScreenHeight - 1, {"No orders yet.", "Pick a restaurant in Shops to place one."})
	end
end

-- Me tab

local function DrawMe()
	local Width = ScreenWidth

	UI.Text(2, 4, "Your name", Theme.Muted, Theme.Bg)
	UI.Fill(2, 5, Width - 2, 1, Theme.Card)
	UI.Text(3, 5, UI.Fit(CustomerName(), Width - 4), Theme.Text, Theme.Card)
	UI.OnClick(2, 5, Width - 1, 5, EditName)
	UI.Text(2, 6, "Tap to change it.", Theme.Muted, Theme.Bg)

	UI.Text(2, 8, "Share location", Theme.Text, Theme.Bg)
	if (Data.ShareLocation) then
		UI.Button(Width - UI.ButtonWidth("On"), 8, "On", Theme.Good, colors.white, function()
			Data.ShareLocation = false
			SaveData()
		end)
	else
		UI.Button(Width - UI.ButtonWidth("Off"), 8, "Off", colors.lightGray, colors.black, function()
			Data.ShareLocation = true
			SaveData()
		end)
	end
	UI.Text(2, 9, "Adds GPS to your orders.", Theme.Muted, Theme.Bg)

	UI.Text(2, 11, "Location", Theme.Text, Theme.Bg)
	UI.Button(Width - UI.ButtonWidth("Locate"), 11, "Locate", Theme.Accent, Theme.OnAccent, LocateNow)
	if (View.LastPos) then
		local Pos = View.LastPos
		UI.Text(2, 12, ("%d, %d, %d"):format(Pos.X, Pos.Y, Pos.Z), Theme.Muted, Theme.Bg)
	else
		UI.Text(2, 12, "Unknown (needs GPS)", Theme.Muted, Theme.Bg)
	end

	UI.Text(2, 14, "Pocket computer", Theme.Text, Theme.Bg)
	local Label = os.getComputerLabel()
	local Computer = "#" .. os.getComputerID()
	if (Label) then
		Computer = Computer .. " " .. Label
	end
	UI.Text(2, 15, UI.Fit(Computer, Width - 2), Theme.Muted, Theme.Bg)
	if (rednet.isOpen()) then
		UI.Text(2, 16, "Modem connected", colors.lime, Theme.Bg)
	else
		UI.Text(2, 16, "No modem", colors.red, Theme.Bg)
	end

	UI.Text(2, 18, "Minepanda v" .. Common.Version, Theme.Muted, Theme.Bg)
end

--

local function Draw()
	ScreenWidth, ScreenHeight = term.getSize()
	UI.Clear()
	DrawHeader()
	DrawTabs()

	if (View.Tab == "Shops" and View.Shop) then
		DrawShop()
	elseif (View.Tab == "Shops") then
		DrawShopList()
	elseif (View.Tab == "Orders") then
		DrawOrders()
	else
		DrawMe()
	end

	DrawFooter()
	ClockTimer = os.startTimer(2)
end

local function HandleKey(Key)
	if (Key == keys.tab) then
		for Index, Tab in ipairs(TabOrder) do
			if (Tab == View.Tab) then
				SelectTab(TabOrder[Index % #TabOrder + 1])
				return
			end
		end
	end

	local ListKey = CurrentListKey()
	if (not ListKey) then return end

	if (Key == keys.up) then
		ScrollBy(ListKey, -1)
	elseif (Key == keys.down) then
		ScrollBy(ListKey, 1)
	end
end

local function UILoop()
	Draw()
	SearchShops()
	if (CountPending() > 0) then
		SyncOrders(true)
	end

	Draw()
	while (true) do
		local Event, A, B, C = os.pullEvent()
		if (Event == "mouse_click") then
			View.Message = nil
			UI.Click(B, C, A)
			Draw()
		elseif (Event == "mouse_scroll") then
			local ListKey = CurrentListKey()
			if (ListKey) then
				ScrollBy(ListKey, A)
			end
			Draw()
		elseif (Event == "key") then
			HandleKey(A)
			Draw()
		elseif (Event == "peripheral" or Event == "peripheral_detach") then
			Common.OpenModems()
			Draw()
		elseif (Event == "MinepandaRedraw" or Event == "term_resize" or (Event == "timer" and A == ClockTimer)) then
			Draw()
		end
	end
end

-- Listens for restaurants telling us an order was delivered or rejected.
local function NetworkLoop()
	while (true) do
		local Sender, Message = rednet.receive(Protocol)
		if (type(Message) == "table" and Message.Type == "Update" and Common.Status[Message.Status]) then
			for _, Order in ipairs(Data.Orders) do
				if (Order.RestaurantId == Sender and Order.OrderId == Message.OrderId and Order.Status ~= Message.Status) then
					Order.Status = Message.Status
					SaveData()

					local Status = Common.Status[Message.Status]
					Notify(("#%d %s: %s"):format(Order.OrderId, Order.RestaurantName, Status.Label), Status.Color)
				end
			end
		end
	end
end

-- Some community OSes don't start rednet's background daemon, so nothing would ever arrive.
-- rednet.run errors straight away when the system already runs one; then this just idles.
local function RednetDaemon()
	pcall(rednet.run)
	while (true) do
		os.pullEvent("MinepandaIdle")
	end
end

-- Catches updates we missed, e.g. while out of range.
local function SyncLoop()
	while (true) do
		sleep(SyncInterval)
		if (CountPending() > 0) then
			local Changed = SyncOrders(false)
			if (Changed > 0) then
				Notify(Common.Plural("order", Changed) .. " updated.", colors.lime)
			end
		end
	end
end

local function WaitForModem()
	local Problem
	while (not Common.OpenModems()) do
		UI.Clear()
		UI.Header("Minepanda")

		local Lines = {
			"No modem found.",
			"Craft this pocket computer with a Wireless or Ender Modem, or hold one and tap Equip."
		}
		if (Problem) then
			Lines[#Lines + 1] = Problem
		end
		UI.Centered(3, ScreenHeight - 4, Lines)

		if (pocket and pocket.equipBack) then
			local Label = "Equip modem"
			local X = math.floor((ScreenWidth - UI.ButtonWidth(Label)) / 2) + 1
			UI.Button(X, ScreenHeight - 2, Label, Theme.Accent, Theme.OnAccent, function()
				local Success, Equipped, Reason = pcall(pocket.equipBack)
				if (not Success) then
					Problem = tostring(Equipped)
				elseif (not Equipped) then
					Problem = tostring(Reason or "Couldn't equip a modem.")
				end
			end)
		end

		local Event, A, B, C = os.pullEvent()
		if (Event == "mouse_click") then
			UI.Click(B, C, A)
		end
	end
end

local function Main()
	if (not term.isColour()) then
		error("Minepanda needs an Advanced Pocket Computer.", 0)
	end

	UI.Init()
	WaitForModem()
	parallel.waitForAny(RednetDaemon, UILoop, NetworkLoop, SyncLoop)
end

local Success, Result = pcall(Main)
UI.Restore()
if (not Success and Result ~= "Terminated") then
	printError(Result)
end
