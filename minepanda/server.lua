-- Minepanda restaurant server. Runs on an Advanced Computer with a wireless or ender modem.
local Common = require("lib.common")
local UI = require("lib.ui")
local Strings = require("cc.strings")

local DataPath = "/minepanda/data/server.db"
local HistoryLimit = 100
local PendingLimitPerCustomer = 10
local MaxOrderLines = 50
local AlertPulses = 3
local AlertSides = {"back", "front", "left", "right", "top", "bottom", "all"}
local TabOrder = {"Orders", "Menu", "Config"}

local Theme = UI.Theme
local Protocol = Common.Protocol

local Data = Common.Load(DataPath, {})
Data.Menu = Data.Menu or {}
Data.Orders = Data.Orders or {}
Data.NextItemId = Data.NextItemId or 1
Data.NextOrderId = Data.NextOrderId or 1
Data.Config = Data.Config or {}

local Config = Data.Config
if (Config.AlertSide == nil) then Config.AlertSide = "back" end
if (Config.AlertInterval == nil) then Config.AlertInterval = 0.5 end
if (Config.Open == nil) then Config.Open = true end

local View = {
	Tab = "Orders",
	OrderFilter = "Pending",
	Scroll = {},
	Editing = nil, -- {Id, Name, Price} while the item editor is open
	Message = nil,
	MessageColor = nil
}

local ScreenWidth, ScreenHeight = term.getSize()
local AlertsQueued = 0
local Hosted = false
local ClockTimer

--

local function SaveData()
	Common.Save(DataPath, Data)
end

local function RestaurantName()
	return os.getComputerLabel() or "Unnamed"
end

-- Shows a message in the footer. Safe to call from any coroutine.
local function Notify(Message, Color)
	View.Message = Message
	View.MessageColor = Color
	os.queueEvent("MinepandaRedraw")
end

local function FindItem(Id)
	for Index, Item in ipairs(Data.Menu) do
		if (Item.Id == Id) then return Item, Index end
	end

	return nil
end

local function FindOrder(Id)
	for _, Order in ipairs(Data.Orders) do
		if (Order.Id == Id) then return Order end
	end

	return nil
end

-- Counts pending orders, or finished ones when Pending is false.
local function CountOrders(Pending)
	local Count = 0
	for _, Order in ipairs(Data.Orders) do
		if ((Order.Status == "Pending") == Pending) then
			Count = Count + 1
		end
	end

	return Count
end

-- Keeps only the newest HistoryLimit finished orders.
local function PruneHistory()
	local Finished = 0
	for Index = #Data.Orders, 1, -1 do
		if (Data.Orders[Index].Status ~= "Pending") then
			Finished = Finished + 1
			if (Finished > HistoryLimit) then
				table.remove(Data.Orders, Index)
			end
		end
	end
end

local function CloseOrder(Order, Status, TellCustomer)
	Order.Status = Status
	Order.ClosedDay = os.day()
	Order.ClosedTime = os.time()
	PruneHistory()
	SaveData()

	if (TellCustomer) then
		rednet.send(Order.CustomerId, {
			Type = "Update",
			OrderId = Order.Id,
			Status = Status,
			Restaurant = RestaurantName()
		}, Protocol)
	end
end

local function SetAlertOutput(Side, On)
	if (Side == "all") then
		for _, EachSide in ipairs(redstone.getSides()) do
			redstone.setOutput(EachSide, On)
		end
	else
		redstone.setOutput(Side, On)
	end
end

local function QueueAlert()
	AlertsQueued = AlertsQueued + 1
	os.queueEvent("MinepandaAlert")
end

-- Hosts the restaurant on rednet under Name and makes it the computer label.
-- Returns true, or false and the reason it failed.
local function SetRestaurantName(Name)
	Name = Common.CleanName(Name)
	if (not Name) then return false, "The name can't be empty." end

	local OldName
	if (Hosted) then
		OldName = os.getComputerLabel()
		if (Name == OldName) then return true end

		rednet.unhost(Protocol)
		Hosted = false
	end

	-- rednet.host fails when another computer already hosts the name.
	local Success, Result = pcall(rednet.host, Protocol, Name)
	if (not Success) then
		if (OldName) then
			Hosted = pcall(rednet.host, Protocol, OldName)
		end

		if (tostring(Result):find("in use")) then
			return false, "Another restaurant is already called " .. Name .. "."
		end
		return false, "Couldn't go online: " .. tostring(Result)
	end

	os.setComputerLabel(Name)
	Hosted = true
	return true
end

local function CleanPos(Pos)
	if (type(Pos) ~= "table") then return nil end

	local X, Y, Z = tonumber(Pos.X), tonumber(Pos.Y), tonumber(Pos.Z)
	if (not (X and Y and Z)) then return nil end

	return {X = math.floor(X + 0.5), Y = math.floor(Y + 0.5), Z = math.floor(Z + 0.5)}
end

-- Network requests from pocket computers, keyed by message Type. Each returns the reply.
local Handlers = {}

function Handlers.Hello(Sender, Message)
	return {
		Type = "Info",
		Ref = Message.Ref,
		Name = RestaurantName(),
		Open = Config.Open,
		Items = #Data.Menu
	}
end

function Handlers.Menu(Sender, Message)
	local Menu = {}
	for Index, Item in ipairs(Data.Menu) do
		Menu[Index] = {Id = Item.Id, Name = Item.Name, Price = Item.Price}
	end

	return {
		Type = "MenuResult",
		Ref = Message.Ref,
		Name = RestaurantName(),
		Open = Config.Open,
		Menu = Menu
	}
end

function Handlers.Order(Sender, Message)
	local function Fail(Reason)
		return {Type = "OrderResult", Ref = Message.Ref, Ok = false, Error = Reason}
	end

	if (not Config.Open) then return Fail("Sorry, we're closed right now.") end
	if (type(Message.Items) ~= "table" or #Message.Items > MaxOrderLines) then
		return Fail("That order couldn't be read.")
	end

	local OpenOrders = 0
	for _, Order in ipairs(Data.Orders) do
		if (Order.CustomerId == Sender and Order.Status == "Pending") then
			OpenOrders = OpenOrders + 1
		end
	end
	if (OpenOrders >= PendingLimitPerCustomer) then
		return Fail("You already have " .. OpenOrders .. " open orders here.")
	end

	-- Prices are copied into the order so later menu edits don't change it.
	local Lines, Total = {}, Common.NewPrice()
	for _, Wanted in ipairs(Message.Items) do
		local Item = nil
		if (type(Wanted) == "table") then
			Item = FindItem(Wanted.Id)
		end
		if (not Item) then return Fail("The menu changed. Please check it again.") end

		local Qty = math.floor(tonumber(Wanted.Qty) or 0)
		if (Qty < 1 or Qty > Common.MaxQty) then
			return Fail("Invalid amount of " .. Item.Name .. ".")
		end

		Lines[#Lines + 1] = {
			ItemId = Item.Id,
			Name = Item.Name,
			Qty = Qty,
			Price = Common.CleanPrice(Item.Price)
		}
		Total = Common.AddPrice(Total, Item.Price, Qty)
	end
	if (#Lines == 0) then return Fail("Your order is empty.") end

	local Order = {
		Id = Data.NextOrderId,
		CustomerId = Sender,
		CustomerName = Common.CleanName(Message.Customer) or ("Customer " .. Sender),
		CustomerLabel = Common.CleanName(Message.Label),
		Items = Lines,
		Total = Total,
		Pos = CleanPos(Message.Pos),
		Status = "Pending",
		Day = os.day(),
		Time = os.time()
	}
	Data.NextOrderId = Data.NextOrderId + 1
	table.insert(Data.Orders, Order)
	SaveData()

	QueueAlert()
	Notify(("New order #%d from %s!"):format(Order.Id, Order.CustomerName), colors.lime)

	return {
		Type = "OrderResult",
		Ref = Message.Ref,
		Ok = true,
		OrderId = Order.Id,
		Total = Total,
		Restaurant = RestaurantName()
	}
end

function Handlers.Cancel(Sender, Message)
	local Reply = {Type = "CancelResult", Ref = Message.Ref, OrderId = Message.OrderId, Ok = false}

	local Order = FindOrder(Message.OrderId)
	if (not Order or Order.CustomerId ~= Sender) then
		Reply.Status = "Unknown"
		Reply.Error = "This restaurant has no record of that order."
		return Reply
	end
	if (Order.Status ~= "Pending") then
		Reply.Status = Order.Status
		Reply.Error = "That order was already " .. Common.Status[Order.Status].Label:lower() .. "."
		return Reply
	end

	CloseOrder(Order, "Cancelled", false)
	Notify(("Order #%d was cancelled by %s."):format(Order.Id, Order.CustomerName), colors.orange)

	Reply.Ok = true
	Reply.Status = "Cancelled"
	return Reply
end

function Handlers.Status(Sender, Message)
	local Statuses = {}
	if (type(Message.Ids) == "table") then
		for Index, Id in ipairs(Message.Ids) do
			if (Index > MaxOrderLines) then break end

			if (type(Id) == "number") then
				local Order = FindOrder(Id)
				if (Order and Order.CustomerId == Sender) then
					Statuses[Id] = Order.Status
				else
					Statuses[Id] = "Unknown"
				end
			end
		end
	end

	return {Type = "StatusResult", Ref = Message.Ref, Statuses = Statuses}
end

--

local function SelectTab(Key)
	View.Tab = Key
	View.Editing = nil
end

local function ScrollBy(Key, Delta)
	View.Scroll[Key] = (View.Scroll[Key] or 0) + Delta
end

-- The scroll key of the list on screen, or nil when the screen has no list.
local function CurrentListKey()
	if (View.Tab == "Orders") then return "Orders" .. View.OrderFilter end
	if (View.Tab == "Menu" and not View.Editing) then return "Menu" end

	return nil
end

local function DrawList(Key, Rows, Y1, Y2)
	View.Scroll[Key] = UI.List(Rows, Y1, Y2, View.Scroll[Key], function(Delta)
		ScrollBy(Key, Delta)
	end)
end

local function DefaultHint()
	if (View.Tab == "Orders") then return "Click Delivered once the food has arrived." end
	if (View.Tab == "Menu" and View.Editing) then return "Click a number to type it. Right-click -/+ for 10." end
	if (View.Tab == "Menu") then return "Click an item to edit it." end

	return "Changes are saved automatically."
end

local function DrawHeader()
	local Stamp = Common.FormatStamp(os.day(), os.time()) .. " "
	UI.Header(RestaurantName(), Stamp)

	local Label, Bg = " OPEN ", Theme.Good
	if (not Config.Open) then
		Label, Bg = " CLOSED ", Theme.Bad
	end
	UI.Text(ScreenWidth - #Stamp - #Label - 1, 1, Label, colors.white, Bg)
end

local function DrawTabs()
	UI.Tabs(2, {
		{Key = "Orders", Label = "Orders (" .. CountOrders(true) .. ")"},
		{Key = "Menu", Label = "Menu (" .. #Data.Menu .. ")"},
		{Key = "Config", Label = "Config"}
	}, View.Tab, SelectTab)

	local Brand = "Minepanda v" .. Common.Version .. " "
	UI.Text(ScreenWidth - #Brand + 1, 2, Brand, Theme.Muted, Theme.Card)
end

local function DrawFooter()
	if (not rednet.isOpen()) then
		UI.Footer("No modem! Customers can't reach you.", Theme.Bad)
	elseif (View.Message) then
		UI.Footer(View.Message, View.MessageColor)
	else
		UI.Footer(DefaultHint())
	end
end

-- Orders tab

local function MarkOrder(Order, Status)
	local Question = "Mark order #" .. Order.Id .. " as delivered?"
	local ButtonLabel, ButtonColor = "Delivered", Theme.Good
	if (Status == "Rejected") then
		Question = "Reject order #" .. Order.Id .. "? Use this when you can't make it."
		ButtonLabel, ButtonColor = "Reject", Theme.Bad
	end

	local Lines = {Question, Order.CustomerName .. "'s pocket computer will be told."}
	if (not UI.Confirm("Order #" .. Order.Id, Lines, ButtonLabel, ButtonColor)) then return end

	-- The customer may have cancelled while the dialog was open.
	if (Order.Status ~= "Pending") then
		View.Message = "Order #" .. Order.Id .. " was already " .. Common.Status[Order.Status].Label:lower() .. "."
		View.MessageColor = Theme.Bad
		return
	end

	CloseOrder(Order, Status, true)
	View.Message = "Order #" .. Order.Id .. " marked " .. Common.Status[Status].Label:lower() .. "."
	View.MessageColor = Common.Status[Status].Color
end

local function AddOrderRows(Rows, Order)
	local Width = ScreenWidth - 1

	local ItemLines = Strings.wrap(Common.ItemsText(Order.Items), Width - 4)
	if (#ItemLines > 3) then
		ItemLines = {ItemLines[1], ItemLines[2], UI.Fit(ItemLines[3] .. " ...", Width - 4)}
	end

	Rows[#Rows + 1] = function(Y)
		UI.Fill(1, Y, Width, 1, Theme.Card)
		local Stamp = Common.FormatStamp(Order.Day, Order.Time)
		UI.Text(Width - #Stamp, Y, Stamp, Theme.Muted, Theme.Card)

		local X = UI.Text(2, Y, "#" .. Order.Id, Theme.Text, Theme.Card)
		X = UI.Text(X + 2, Y, Order.CustomerName, Theme.Text, Theme.Card)

		-- Which computer ordered: its ID, plus its label when that differs from the name.
		local Computer = "PC " .. Order.CustomerId
		if (Order.CustomerLabel and Order.CustomerLabel ~= Order.CustomerName) then
			Computer = Computer .. " \"" .. Order.CustomerLabel .. "\""
		end
		UI.Text(X + 1, Y, UI.Fit("(" .. Computer .. ")", Width - #Stamp - X - 2), Theme.Muted, Theme.Card)
	end

	for _, Line in ipairs(ItemLines) do
		Rows[#Rows + 1] = function(Y)
			UI.Fill(1, Y, Width, 1, Theme.Card)
			UI.Text(4, Y, Line, Theme.Text, Theme.Card)
		end
	end

	Rows[#Rows + 1] = function(Y)
		UI.Fill(1, Y, Width, 1, Theme.Card)

		local RightX
		if (Order.Status == "Pending") then
			RightX = Width - UI.ButtonWidth("Delivered") - UI.ButtonWidth("Reject") - 1
			local X = UI.Button(RightX, Y, "Delivered", Theme.Good, colors.white, function()
				MarkOrder(Order, "Delivered")
			end)
			UI.Button(X + 1, Y, "Reject", Theme.Bad, colors.white, function()
				MarkOrder(Order, "Rejected")
			end)
		else
			local Status = Common.Status[Order.Status]
			RightX = Width - #Status.Label
			UI.Text(RightX, Y, Status.Label, Status.Color, Theme.Card)
		end

		local X = UI.Text(4, Y, "Total ", Theme.Muted, Theme.Card)
		X = UI.Parts(X, Y, Common.PriceParts(Order.Total), Theme.Card, RightX - 2)
		if (Order.Pos) then
			local Where = ("@ %d, %d, %d"):format(Order.Pos.X, Order.Pos.Y, Order.Pos.Z)
			UI.Text(X + 2, Y, UI.Fit(Where, RightX - X - 4), Theme.Muted, Theme.Card)
		end
	end

	Rows[#Rows + 1] = function() end
end

local function DrawOrders()
	local function FilterButton(X, Key, Label)
		local Bg, Fg = Theme.Card, Theme.Muted
		if (View.OrderFilter == Key) then
			Bg, Fg = Theme.Accent, Theme.OnAccent
		end

		return UI.Button(X, 3, Label, Bg, Fg, function()
			View.OrderFilter = Key
		end)
	end

	local X = FilterButton(2, "Pending", "Pending (" .. CountOrders(true) .. ")")
	FilterButton(X + 1, "Done", "Done (" .. CountOrders(false) .. ")")

	-- Pending orders oldest first, so the next one to cook is on top. Finished ones newest first.
	local Pending = View.OrderFilter == "Pending"
	local Rows = {}
	if (Pending) then
		for _, Order in ipairs(Data.Orders) do
			if (Order.Status == "Pending") then AddOrderRows(Rows, Order) end
		end
	else
		for Index = #Data.Orders, 1, -1 do
			local Order = Data.Orders[Index]
			if (Order.Status ~= "Pending") then AddOrderRows(Rows, Order) end
		end
	end

	if (#Rows > 0) then
		DrawList("Orders" .. View.OrderFilter, Rows, 5, ScreenHeight - 1)
	elseif (Pending) then
		UI.Centered(5, ScreenHeight - 2, {"No orders right now.", "New orders show up here and ring the noteblock."})
	else
		UI.Centered(5, ScreenHeight - 2, {"No finished orders.", "Delivered, rejected and cancelled orders are kept here."})
	end
end

-- Menu tab

local function StartEditing(Item)
	if (Item) then
		View.Editing = {Id = Item.Id, Name = Item.Name, Price = Common.CleanPrice(Item.Price)}
	else
		View.Editing = {Id = nil, Name = "", Price = Common.NewPrice()}
	end
end

local function RemoveItem(Item)
	local Lines = {"Remove " .. Item.Name .. " from the menu? Orders already placed keep it."}
	if (not UI.Confirm("Remove item", Lines, "Remove", Theme.Bad)) then return end

	local _, Index = FindItem(Item.Id)
	if (Index) then
		table.remove(Data.Menu, Index)
		SaveData()
	end

	View.Editing = nil
	View.Message = Item.Name .. " was removed from the menu."
	View.MessageColor = Theme.Muted
end

local function DrawMenu()
	UI.Button(2, 3, "+ Add item", Theme.Accent, Theme.OnAccent, function()
		StartEditing(nil)
	end)

	local Width = ScreenWidth - 1
	local Rows = {}
	for _, Item in ipairs(Data.Menu) do
		local function Edit()
			StartEditing(Item)
		end

		Rows[#Rows + 1] = function(Y)
			UI.Fill(1, Y, Width, 1, Theme.Card)
			UI.OnClick(1, Y, Width, Y, Edit)

			local ButtonsX = Width - UI.ButtonWidth("Edit") - UI.ButtonWidth("Remove") - 1
			UI.Text(3, Y, UI.Fit(Item.Name, ButtonsX - 4), Theme.Text, Theme.Card)
			local X = UI.Button(ButtonsX, Y, "Edit", Theme.Accent, Theme.OnAccent, Edit)
			UI.Button(X + 1, Y, "Remove", Theme.Bad, colors.white, function()
				RemoveItem(Item)
			end)
		end

		Rows[#Rows + 1] = function(Y)
			UI.Fill(1, Y, Width, 1, Theme.Card)
			UI.OnClick(1, Y, Width, Y, Edit)
			UI.Parts(3, Y, Common.PriceParts(Item.Price, true), Theme.Card, Width - 1)
		end

		Rows[#Rows + 1] = function() end
	end

	if (#Rows > 0) then
		DrawList("Menu", Rows, 5, ScreenHeight - 1)
	else
		UI.Centered(5, ScreenHeight - 2, {"Your menu is empty.", "Click + Add item to create your first dish."})
	end
end

local function ChangePrice(Key, Delta)
	local Price = View.Editing.Price
	Price[Key] = math.max(0, math.min(Common.MaxPrice, Price[Key] + Delta))
end

local function SaveEditing()
	local Editing = View.Editing
	local Name = Common.CleanName(Editing.Name)
	if (not Name) then
		View.Message, View.MessageColor = "Give the item a name first.", Theme.Bad
		return
	end

	local Item = nil
	if (Editing.Id) then
		Item = FindItem(Editing.Id)
	end
	if (not Item) then
		Item = {Id = Data.NextItemId}
		Data.NextItemId = Data.NextItemId + 1
		table.insert(Data.Menu, Item)
	end

	Item.Name = Name
	Item.Price = Common.CleanPrice(Editing.Price)
	SaveData()

	View.Editing = nil
	View.Message, View.MessageColor = "Saved " .. Name .. ".", colors.lime
end

local function DrawEditor()
	local Editing = View.Editing

	local Title = "New menu item"
	if (Editing.Id) then
		Title = "Edit menu item"
	end
	UI.Text(2, 3, Title, Theme.Text, Theme.Bg)

	UI.Text(3, 5, "Name", Theme.Muted, Theme.Bg)
	UI.Fill(3, 6, Common.MaxName + 4, 1, Theme.Card)
	if (Editing.Name == "") then
		UI.Text(4, 6, "Click to type a name", Theme.Muted, Theme.Card)
	else
		UI.Text(4, 6, Editing.Name, Theme.Text, Theme.Card)
	end
	UI.OnClick(3, 6, Common.MaxName + 6, 6, function()
		local Label = "Up to " .. Common.MaxName .. " characters"
		local Name = UI.Prompt("Item name", Label, Editing.Name, {MaxLen = Common.MaxName})
		if (Name) then
			Editing.Name = Common.Trim(Name)
		end
	end)

	UI.Text(3, 8, "Price (leave all at 0 for a free item)", Theme.Muted, Theme.Bg)
	for Index, Currency in ipairs(Common.Currencies) do
		local Y = 8 + Index
		local Key = Currency.Key
		UI.Text(5, Y, Currency.Name, Currency.Color, Theme.Bg)

		UI.Button(15, Y, "-", Theme.Card, Theme.Text, function(MouseButton)
			ChangePrice(Key, MouseButton == 2 and -10 or -1)
		end)

		UI.Text(19, Y, ("%4d "):format(Editing.Price[Key]), colors.black, colors.white)
		UI.OnClick(19, Y, 23, Y, function()
			local Label = "Amount of " .. Currency.Name .. " (0-" .. Common.MaxPrice .. ")"
			local Options = {MaxLen = #tostring(Common.MaxPrice), Numeric = true}
			local Amount = tonumber(UI.Prompt(Currency.Name .. " price", Label, Editing.Price[Key], Options) or "")
			if (Amount) then
				Editing.Price[Key] = math.max(0, math.min(Common.MaxPrice, math.floor(Amount)))
			end
		end)

		UI.Button(25, Y, "+", Theme.Card, Theme.Text, function(MouseButton)
			ChangePrice(Key, MouseButton == 2 and 10 or 1)
		end)
	end

	UI.Text(3, 14, "Shown as", Theme.Muted, Theme.Bg)
	local MakeFreeX = ScreenWidth - UI.ButtonWidth("Make free")
	UI.Parts(15, 14, Common.PriceParts(Editing.Price, true), Theme.Bg, MakeFreeX - 2)
	if (not Common.IsFree(Editing.Price)) then
		UI.Button(MakeFreeX, 14, "Make free", Theme.Card, Theme.Text, function()
			Editing.Price = Common.NewPrice()
		end)
	end

	local X = UI.Button(3, 16, "Save", Theme.Accent, Theme.OnAccent, SaveEditing)
	UI.Button(X + 1, 16, "Cancel", colors.lightGray, colors.black, function()
		View.Editing = nil
	end)

	local Item = nil
	if (Editing.Id) then
		Item = FindItem(Editing.Id)
	end
	if (Item) then
		UI.Button(ScreenWidth - UI.ButtonWidth("Remove item"), 16, "Remove item", Theme.Bad, colors.white, function()
			RemoveItem(Item)
		end)
	end
end

-- Config tab

local function RenameRestaurant()
	local Label = "New name (up to " .. Common.MaxName .. " characters)"
	local Name = UI.Prompt("Rename restaurant", Label, RestaurantName(), {MaxLen = Common.MaxName})
	if (not Name) then return end

	UI.Busy("Checking the name...")
	local Success, Reason = SetRestaurantName(Name)
	if (Success) then
		View.Message, View.MessageColor = "Customers now see you as " .. RestaurantName() .. ".", colors.lime
	else
		View.Message, View.MessageColor = Reason, Theme.Bad
	end
end

local function CycleAlertSide(Step)
	local Index = 1
	for EachIndex, Side in ipairs(AlertSides) do
		if (Side == Config.AlertSide) then
			Index = EachIndex
		end
	end

	SetAlertOutput(Config.AlertSide, false)
	Config.AlertSide = AlertSides[(Index - 1 + Step) % #AlertSides + 1]
	SaveData()
end

local function ChangeInterval(Delta)
	Config.AlertInterval = math.max(0.25, math.min(2, Config.AlertInterval + Delta))
	SaveData()
end

local function ClearHistory()
	local Finished = CountOrders(false)
	local Lines = {"Delete " .. Common.Plural("finished order", Finished) .. "? Pending orders are kept."}
	if (not UI.Confirm("Clear history", Lines, "Clear", Theme.Bad)) then return end

	for Index = #Data.Orders, 1, -1 do
		if (Data.Orders[Index].Status ~= "Pending") then
			table.remove(Data.Orders, Index)
		end
	end
	SaveData()

	View.Message, View.MessageColor = "Order history cleared.", Theme.Muted
end

local function DrawConfig()
	local LabelX, ValueX, ActionX = 3, 19, 40

	UI.Text(LabelX, 4, "Restaurant name", Theme.Muted, Theme.Bg)
	UI.Text(ValueX, 4, RestaurantName(), Theme.Text, Theme.Bg)
	UI.Button(ActionX, 4, "Rename", Theme.Accent, Theme.OnAccent, RenameRestaurant)

	UI.Text(LabelX, 6, "Taking orders", Theme.Muted, Theme.Bg)
	if (Config.Open) then
		UI.Text(ValueX, 6, "Open", colors.lime, Theme.Bg)
		UI.Button(ActionX, 6, "Close shop", Theme.Bad, colors.white, function()
			Config.Open = false
			SaveData()
		end)
	else
		UI.Text(ValueX, 6, "Closed", colors.red, Theme.Bg)
		UI.Button(ActionX, 6, "Open shop", Theme.Good, colors.white, function()
			Config.Open = true
			SaveData()
		end)
	end

	UI.Text(LabelX, 8, "Noteblock side", Theme.Muted, Theme.Bg)
	local X = UI.Button(ValueX, 8, "\17", Theme.Card, Theme.Text, function()
		CycleAlertSide(-1)
	end)
	UI.Text(X + 1, 8, ("%-6s"):format(Config.AlertSide), Theme.Text, Theme.Bg)
	UI.Button(X + 8, 8, "\16", Theme.Card, Theme.Text, function()
		CycleAlertSide(1)
	end)
	UI.Button(ActionX, 8, "Test alert", Theme.Accent, Theme.OnAccent, QueueAlert)
	UI.Text(ValueX, 9, "Redstone goes out of this side.", Theme.Muted, Theme.Bg)

	UI.Text(LabelX, 11, "Pulse interval", Theme.Muted, Theme.Bg)
	X = UI.Button(ValueX, 11, "-", Theme.Card, Theme.Text, function()
		ChangeInterval(-0.25)
	end)
	UI.Text(X + 1, 11, ("%.2fs"):format(Config.AlertInterval), Theme.Text, Theme.Bg)
	UI.Button(X + 8, 11, "+", Theme.Card, Theme.Text, function()
		ChangeInterval(0.25)
	end)
	UI.Text(ValueX, 12, "Rings " .. AlertPulses .. " times per new order.", Theme.Muted, Theme.Bg)

	local Finished = CountOrders(false)
	UI.Text(LabelX, 14, "Order history", Theme.Muted, Theme.Bg)
	UI.Text(ValueX, 14, Common.Plural("finished order", Finished), Theme.Text, Theme.Bg)
	local ClearAction = nil
	if (Finished > 0) then
		ClearAction = ClearHistory
	end
	UI.Button(ActionX, 14, "Clear", Theme.Bad, colors.white, ClearAction)

	UI.Text(LabelX, 16, "Network", Theme.Muted, Theme.Bg)
	X = UI.Text(ValueX, 16, "Computer #" .. os.getComputerID() .. ", ", Theme.Text, Theme.Bg)
	if (rednet.isOpen()) then
		UI.Text(X, 16, "modem OK", colors.lime, Theme.Bg)
	else
		UI.Text(X, 16, "no modem", colors.red, Theme.Bg)
	end
end

--

local function Draw()
	ScreenWidth, ScreenHeight = term.getSize()
	UI.Clear()
	DrawHeader()
	DrawTabs()

	if (View.Tab == "Orders") then
		DrawOrders()
	elseif (View.Tab == "Menu" and View.Editing) then
		DrawEditor()
	elseif (View.Tab == "Menu") then
		DrawMenu()
	else
		DrawConfig()
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
	elseif (Key == keys.pageUp) then
		ScrollBy(ListKey, -(ScreenHeight - 6))
	elseif (Key == keys.pageDown) then
		ScrollBy(ListKey, ScreenHeight - 6)
	end
end

local function UILoop()
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

local function NetworkLoop()
	while (true) do
		local Sender, Message = rednet.receive(Protocol)
		if (type(Message) == "table" and type(Message.Type) == "string") then
			local Handler = Handlers[Message.Type]
			if (Handler) then
				local Success, Reply = pcall(Handler, Sender, Message)
				if (not Success) then
					Notify("Error in " .. Message.Type .. " request: " .. tostring(Reply), Theme.Bad)
				elseif (Reply) then
					rednet.send(Sender, Reply, Protocol)
				end
			end
		end
	end
end

-- Plays AlertPulses redstone pulses for every queued order, one order after another.
local function AlertLoop()
	while (true) do
		if (AlertsQueued > 0) then
			AlertsQueued = AlertsQueued - 1

			local Side, Interval = Config.AlertSide, Config.AlertInterval
			for _ = 1, AlertPulses do
				SetAlertOutput(Side, true)
				sleep(Interval)
				SetAlertOutput(Side, false)
				sleep(Interval)
			end
		else
			os.pullEvent("MinepandaAlert")
		end
	end
end

local function WaitForModem()
	while (not Common.OpenModems()) do
		UI.Clear()
		UI.Header("Minepanda")
		UI.Centered(2, ScreenHeight, {
			"No modem found.",
			"Attach a Wireless or Ender Modem to this computer. Minepanda starts as soon as one is connected."
		})
		os.pullEvent("peripheral")
	end
end

-- Hosts the restaurant under its label, asking for a name on first run or when it's taken.
local function GoOnline()
	local Name = os.getComputerLabel()
	local Problem

	while (true) do
		if (Name) then
			UI.Clear()
			UI.Header("Minepanda")
			UI.Busy("Going online as " .. Name .. "...")

			local Success, Reason = SetRestaurantName(Name)
			if (Success) then return end
			Problem = Reason
		end

		UI.Clear()
		UI.Header("Minepanda")
		local Lines = {
			"Welcome to Minepanda!",
			"Name your restaurant. Customers see this name, and it becomes this computer's label."
		}
		if (Problem) then
			Lines[#Lines + 1] = Problem
		end
		UI.Centered(2, 6, Lines)

		Name = UI.Prompt("Set up your restaurant", "Restaurant name", Name or "", {
			MaxLen = Common.MaxName,
			NoCancel = true
		})
	end
end

local function Main()
	if (not term.isColour()) then
		error("Minepanda needs an Advanced Computer.", 0)
	end

	UI.Init()
	WaitForModem()
	GoOnline()
	SetAlertOutput(Config.AlertSide, false)
	parallel.waitForAny(UILoop, NetworkLoop, AlertLoop)
end

local Success, Result = pcall(Main)
pcall(SetAlertOutput, Config.AlertSide, false)
pcall(rednet.unhost, Protocol)
UI.Restore()
if (not Success and Result ~= "Terminated") then
	printError(Result)
end
