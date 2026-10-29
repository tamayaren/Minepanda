-- Shared constants and helpers for the Minepanda server and client.
local Common = {}

Common.Version = "1.0.0"
Common.Protocol = "Minepanda"
Common.MaxName = 20
Common.MaxQty = 64
Common.MaxPrice = 999

-- Highest value first; this is also the order prices are displayed in.
Common.Currencies = {
	{Key = "Diamond", Name = "Diamond", Short = "Dia", Color = colors.lightBlue},
	{Key = "Emerald", Name = "Emerald", Short = "Emr", Color = colors.lime},
	{Key = "Gold", Name = "Gold", Short = "Gold", Color = colors.yellow},
	{Key = "Iron", Name = "Iron", Short = "Iron", Color = colors.lightGray}
}

Common.Status = {
	Pending = {Label = "Pending", Color = colors.orange},
	Delivered = {Label = "Delivered", Color = colors.lime},
	Rejected = {Label = "Rejected", Color = colors.red},
	Cancelled = {Label = "Cancelled", Color = colors.lightGray},
	Unknown = {Label = "Not found", Color = colors.lightGray}
}

function Common.NewPrice()
	local Price = {}
	for _, Currency in ipairs(Common.Currencies) do
		Price[Currency.Key] = 0
	end

	return Price
end

-- Copies a price, dropping unknown keys and clamping amounts to whole numbers.
function Common.CleanPrice(Price)
	local Clean = Common.NewPrice()
	if (type(Price) ~= "table") then return Clean end

	for _, Currency in ipairs(Common.Currencies) do
		local Amount = math.floor(tonumber(Price[Currency.Key]) or 0)
		Clean[Currency.Key] = math.max(0, math.min(Common.MaxPrice, Amount))
	end

	return Clean
end

function Common.IsFree(Price)
	for _, Currency in ipairs(Common.Currencies) do
		if ((Price[Currency.Key] or 0) > 0) then return false end
	end

	return true
end

-- Returns Total + Price * Qty as a new price.
function Common.AddPrice(Total, Price, Qty)
	local Sum = Common.NewPrice()
	for _, Currency in ipairs(Common.Currencies) do
		local Key = Currency.Key
		Sum[Key] = (Total[Key] or 0) + (Price[Key] or 0) * (Qty or 1)
	end

	return Sum
end

-- Splits a price into coloured pieces, e.g. {Text = "1 Dia", Color = colors.lightBlue}.
function Common.PriceParts(Price, Long)
	local Parts = {}
	for _, Currency in ipairs(Common.Currencies) do
		local Amount = Price[Currency.Key] or 0
		if (Amount > 0) then
			local Label = Currency.Short
			if (Long) then Label = Currency.Name end

			Parts[#Parts + 1] = {Text = Amount .. " " .. Label, Color = Currency.Color}
		end
	end

	if (#Parts == 0) then
		Parts[1] = {Text = "Free", Color = colors.pink}
	end

	return Parts
end

function Common.PriceText(Price, Long)
	local Words = {}
	for Index, Part in ipairs(Common.PriceParts(Price, Long)) do
		Words[Index] = Part.Text
	end

	return table.concat(Words, " + ")
end

function Common.ItemsText(Items)
	local Parts = {}
	for Index, Line in ipairs(Items) do
		Parts[Index] = Line.Qty .. "x " .. Line.Name
	end

	return table.concat(Parts, ", ")
end

-- Plural("item", 1) is "1 item", Plural("item", 3) is "3 items".
function Common.Plural(Word, Count)
	if (Count == 1) then return "1 " .. Word end

	return Count .. " " .. Word .. "s"
end

function Common.Trim(Text)
	return (tostring(Text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Trims and shortens a name typed by a user or received from the network. Returns nil when empty.
function Common.CleanName(Name)
	if (type(Name) ~= "string") then return nil end

	Name = Common.Trim(Name):sub(1, Common.MaxName)
	if (Name == "") then return nil end

	return Name
end

function Common.FormatStamp(Day, Time)
	return ("Day %d %s"):format(Day or 0, textutils.formatTime(Time or 0, true))
end

function Common.NewRef()
	return os.getComputerID() .. "-" .. math.random(1, 999999999)
end

-- Opens every attached modem for rednet. Returns whether any modem was found.
function Common.OpenModems()
	local Found = false
	for _, Side in ipairs(peripheral.getNames()) do
		local IsModem
		if (peripheral.hasType) then
			IsModem = peripheral.hasType(Side, "modem")
		else
			IsModem = peripheral.getType(Side) == "modem"
		end

		if (IsModem) then
			rednet.open(Side)
			Found = true
		end
	end

	return Found
end

function Common.Load(Path, Default)
	-- A leftover .tmp means a save was interrupted after the old file was removed.
	if (not fs.exists(Path) and fs.exists(Path .. ".tmp")) then
		Path = Path .. ".tmp"
	end
	if (not fs.exists(Path)) then return Default end

	local Handle = fs.open(Path, "r")
	if (not Handle) then return Default end

	local Contents = Handle.readAll()
	Handle.close()

	local Value = textutils.unserialize(Contents or "")
	if (type(Value) ~= "table") then return Default end

	return Value
end

function Common.Save(Path, Value)
	fs.makeDir(fs.getDir(Path))

	local TempPath = Path .. ".tmp"
	local Handle = fs.open(TempPath, "w")
	Handle.write(textutils.serialize(Value))
	Handle.close()

	if (fs.exists(Path)) then
		fs.delete(Path)
	end
	fs.move(TempPath, Path)
end

return Common
