-- A tiny clickable UI toolkit shared by the Minepanda server and client.
-- Screens are redrawn from scratch, and every draw registers the click areas for what it shows.
local Strings = require("cc.strings")

local UI = {}

UI.Theme = {
	Bg = colors.black,
	Text = colors.white,
	Muted = colors.lightGray,
	Card = colors.gray,
	Accent = colors.pink, -- Recoloured to Minepanda pink by UI.Init()
	OnAccent = colors.white,
	Good = colors.green,
	Bad = colors.red,
	Field = colors.black,
	Disabled = colors.lightGray
}

local AccentRGB = 0xD70F64
local Buttons = {}

function UI.Init()
	term.setPaletteColour(colors.pink, AccentRGB)
end

function UI.Restore()
	term.setPaletteColour(colors.pink, term.nativePaletteColour(colors.pink))
	term.setCursorBlink(false)
	term.setBackgroundColour(colors.black)
	term.setTextColour(colors.white)
	term.clear()
	term.setCursorPos(1, 1)
end

function UI.Clear()
	Buttons = {}
	term.setCursorBlink(false)
	term.setBackgroundColour(UI.Theme.Bg)
	term.clear()
end

function UI.Fill(X, Y, Width, Height, Bg)
	if (Width <= 0 or Height <= 0) then return end

	term.setBackgroundColour(Bg)
	local Blank = (" "):rep(Width)
	for Row = Y, Y + Height - 1 do
		term.setCursorPos(X, Row)
		term.write(Blank)
	end
end

-- Writes text and returns the column just after it.
function UI.Text(X, Y, Text, Fg, Bg)
	Text = tostring(Text)
	term.setCursorPos(X, Y)
	term.setTextColour(Fg)
	if (Bg) then
		term.setBackgroundColour(Bg)
	end
	term.write(Text)

	return X + #Text
end

-- Shortens Text to Width characters, marking the cut with "..".
function UI.Fit(Text, Width)
	Text = tostring(Text)
	if (Width <= 0) then return "" end
	if (#Text <= Width) then return Text end
	if (Width <= 2) then return Text:sub(1, Width) end

	return Text:sub(1, Width - 2) .. ".."
end

function UI.OnClick(X1, Y1, X2, Y2, Action)
	Buttons[#Buttons + 1] = {X1 = X1, Y1 = Y1, X2 = X2, Y2 = Y2, Action = Action}
end

function UI.ButtonWidth(Label)
	return #Label + 2
end

-- Draws " Label " and makes it clickable. Without an action it is drawn greyed out.
-- The action receives the mouse button (1 = left, 2 = right). Returns the column after it.
function UI.Button(X, Y, Label, Bg, Fg, Action)
	local Text = " " .. Label .. " "
	if (Action) then
		UI.Text(X, Y, Text, Fg or UI.Theme.OnAccent, Bg or UI.Theme.Accent)
		UI.OnClick(X, Y, X + #Text - 1, Y, Action)
	else
		UI.Text(X, Y, Text, UI.Theme.Disabled, UI.Theme.Card)
	end

	return X + #Text
end

-- Runs the most recently registered click area under (X, Y). Returns whether one was hit.
function UI.Click(X, Y, MouseButton)
	for Index = #Buttons, 1, -1 do
		local Button = Buttons[Index]
		if (X >= Button.X1 and X <= Button.X2 and Y >= Button.Y1 and Y <= Button.Y2) then
			Button.Action(MouseButton or 1)
			return true
		end
	end

	return false
end

-- Writes price parts in their currency colours, stopping at MaxX. Returns the column after it.
function UI.Parts(X, Y, Parts, Bg, MaxX)
	for Index, Part in ipairs(Parts) do
		local Text = Part.Text
		if (Index > 1) then
			Text = " " .. Text
		end

		if (MaxX and X + #Text - 1 > MaxX) then
			if (X + 1 <= MaxX) then
				UI.Text(X, Y, "..", UI.Theme.Muted, Bg)
			end
			return MaxX + 1
		end

		X = UI.Text(X, Y, Text, Part.Color, Bg)
	end

	return X
end

function UI.Header(Left, Right)
	local Width = term.getSize()
	UI.Fill(1, 1, Width, 1, UI.Theme.Accent)
	UI.Text(2, 1, UI.Fit(Left, Width - 2), UI.Theme.OnAccent, UI.Theme.Accent)
	if (Right) then
		UI.Text(Width - #Right, 1, Right, UI.Theme.OnAccent, UI.Theme.Accent)
	end
end

-- Tabs is a list of {Key = ..., Label = ...}; clicking one calls OnSelect(Key).
function UI.Tabs(Y, Tabs, ActiveKey, OnSelect)
	local Width = term.getSize()
	UI.Fill(1, Y, Width, 1, UI.Theme.Card)

	local X = 1
	for _, Tab in ipairs(Tabs) do
		local Bg, Fg = UI.Theme.Card, UI.Theme.Muted
		if (Tab.Key == ActiveKey) then
			Bg, Fg = UI.Theme.Bg, UI.Theme.Text
		end

		X = UI.Button(X, Y, Tab.Label, Bg, Fg, function()
			OnSelect(Tab.Key)
		end)
	end
end

function UI.Footer(Message, Color)
	local Width, Height = term.getSize()
	UI.Fill(1, Height, Width, 1, UI.Theme.Card)
	UI.Text(2, Height, UI.Fit(Message or "", Width - 2), Color or UI.Theme.Muted, UI.Theme.Card)
end

-- Writes wrapped lines centred between rows Y1 and Y2. The first line is highlighted.
function UI.Centered(Y1, Y2, Lines, Color)
	local Width = term.getSize()
	local Wrapped = {}
	for _, Line in ipairs(Lines) do
		for _, Piece in ipairs(Strings.wrap(Line, Width - 4)) do
			Wrapped[#Wrapped + 1] = Piece
		end
	end

	local Top = Y1 + math.floor((Y2 - Y1 + 1 - #Wrapped) / 2)
	for Index, Piece in ipairs(Wrapped) do
		local Fg = Color or UI.Theme.Muted
		if (Index == 1) then
			Fg = UI.Theme.Text
		end

		UI.Text(math.floor((Width - #Piece) / 2) + 1, Top + Index - 1, Piece, Fg, UI.Theme.Bg)
	end
end

-- Draws Rows[Scroll + 1 ...] into screen rows Y1..Y2, with a clickable scrollbar in the last
-- column when they don't all fit. Each row is a function(Y) that draws itself and leaves the
-- last column free. OnScroll(Delta) is called by the scrollbar. Returns the clamped scroll offset.
function UI.List(Rows, Y1, Y2, Scroll, OnScroll)
	local Width = term.getSize()
	local Visible = Y2 - Y1 + 1
	local MaxScroll = math.max(0, #Rows - Visible)
	Scroll = math.max(0, math.min(Scroll or 0, MaxScroll))

	for Index = 1, Visible do
		local Row = Rows[Scroll + Index]
		if (Row) then
			Row(Y1 + Index - 1)
		end
	end

	if (MaxScroll > 0 and Visible >= 3) then
		local Track = Visible - 2
		local Thumb = math.max(1, math.floor(Track * Visible / #Rows))
		local ThumbY = Y1 + 1 + math.floor((Track - Thumb) * Scroll / MaxScroll + 0.5)
		local Middle = Y1 + math.floor(Visible / 2)

		UI.Fill(Width, Y1, 1, Visible, UI.Theme.Card)
		UI.Fill(Width, ThumbY, 1, Thumb, UI.Theme.Muted)
		UI.Text(Width, Y1, "\30", UI.Theme.Text, UI.Theme.Card)
		UI.Text(Width, Y2, "\31", UI.Theme.Text, UI.Theme.Card)
		UI.OnClick(Width, Y1, Width, Middle - 1, function()
			OnScroll(-3)
		end)
		UI.OnClick(Width, Middle, Width, Y2, function()
			OnScroll(3)
		end)
	end

	return Scroll
end

-- Draws an empty dialog box with a title bar. Returns its X, Y and width.
local function DrawBox(Title, Height, Width)
	local ScreenWidth, ScreenHeight = term.getSize()
	Width = math.min(ScreenWidth - 2, Width)

	local X = math.floor((ScreenWidth - Width) / 2) + 1
	local Y = math.max(1, math.floor((ScreenHeight - Height) / 2) + 1)
	UI.Fill(X, Y, Width, 1, UI.Theme.Accent)
	UI.Text(X + 1, Y, UI.Fit(Title, Width - 2), UI.Theme.OnAccent, UI.Theme.Accent)
	UI.Fill(X, Y + 1, Width, Height - 1, UI.Theme.Card)

	return X, Y, Width
end

-- Shows a message over the current screen while something slow happens.
function UI.Busy(Message)
	local X, Y, Width = DrawBox("Please wait", 4, #Message + 4)
	UI.Text(X + 1, Y + 2, UI.Fit(Message, Width - 2), UI.Theme.Text, UI.Theme.Card)
end

-- Asks a yes/no question. Lines are strings (wrapped) or {Parts = PriceParts} (drawn in colour).
-- Returns true when the yes button is clicked or Enter is pressed.
function UI.Confirm(Title, Lines, YesLabel, YesColor, NoLabel)
	if (type(Lines) == "string") then
		Lines = {Lines}
	end
	YesLabel = YesLabel or "Yes"
	NoLabel = NoLabel or "Back"

	local SavedButtons = Buttons
	local ScreenWidth = term.getSize()
	local Width = math.min(ScreenWidth - 2, 40)

	local Wrapped = {}
	for _, Line in ipairs(Lines) do
		if (type(Line) == "table") then
			Wrapped[#Wrapped + 1] = Line
		else
			for _, Piece in ipairs(Strings.wrap(Line, Width - 2)) do
				Wrapped[#Wrapped + 1] = Piece
			end
		end
	end

	Buttons = {}
	local Result
	local X, Y = DrawBox(Title, #Wrapped + 5, Width)
	for Index, Line in ipairs(Wrapped) do
		if (type(Line) == "table") then
			UI.Parts(X + 1, Y + 1 + Index, Line.Parts, UI.Theme.Card, X + Width - 2)
		else
			UI.Text(X + 1, Y + 1 + Index, Line, UI.Theme.Text, UI.Theme.Card)
		end
	end

	local ButtonY = Y + #Wrapped + 3
	local ButtonX = X + Width - 1 - UI.ButtonWidth(YesLabel) - 1 - UI.ButtonWidth(NoLabel)
	ButtonX = UI.Button(ButtonX, ButtonY, NoLabel, colors.lightGray, colors.black, function()
		Result = false
	end)
	UI.Button(ButtonX + 1, ButtonY, YesLabel, YesColor or UI.Theme.Accent, UI.Theme.OnAccent, function()
		Result = true
	end)

	while (Result == nil) do
		local Event, A, B, C = os.pullEvent()
		if (Event == "mouse_click") then
			UI.Click(B, C, A)
		elseif (Event == "key" and (A == keys.enter or A == keys.numPadEnter)) then
			Result = true
		end
	end

	Buttons = SavedButtons
	return Result
end

-- Asks for a line of text. Returns the text, or nil if cancelled.
-- Options: MaxLen, Numeric (digits only), NoCancel (hide the Cancel button), Width.
function UI.Prompt(Title, Label, Default, Options)
	Options = Options or {}

	local SavedButtons = Buttons
	local Text = tostring(Default or "")
	local MaxLen = Options.MaxLen or 32
	local Done, Result = false, nil

	while (not Done) do
		Buttons = {}
		local X, Y, Width = DrawBox(Title, 7, Options.Width or 36)
		UI.Text(X + 1, Y + 2, UI.Fit(Label, Width - 2), UI.Theme.Muted, UI.Theme.Card)

		-- Long text scrolls so the end stays visible.
		local FieldWidth = Width - 2
		local Shown = Text
		if (#Text >= FieldWidth) then
			Shown = Text:sub(-(FieldWidth - 1))
		end
		UI.Fill(X + 1, Y + 3, FieldWidth, 1, UI.Theme.Field)
		UI.Text(X + 1, Y + 3, Shown, UI.Theme.Text, UI.Theme.Field)

		local ButtonY = Y + 5
		local ButtonX = X + Width - 1 - UI.ButtonWidth("OK")
		if (not Options.NoCancel) then
			ButtonX = ButtonX - 1 - UI.ButtonWidth("Cancel")
			ButtonX = UI.Button(ButtonX, ButtonY, "Cancel", colors.lightGray, colors.black, function()
				Done = true
			end) + 1
		end
		UI.Button(ButtonX, ButtonY, "OK", UI.Theme.Accent, UI.Theme.OnAccent, function()
			Done, Result = true, Text
		end)

		term.setCursorPos(X + 1 + #Shown, Y + 3)
		term.setTextColour(UI.Theme.Text)
		term.setBackgroundColour(UI.Theme.Field)
		term.setCursorBlink(true)

		local Event, A, B, C = os.pullEvent()
		if (Event == "char") then
			if (#Text < MaxLen and (not Options.Numeric or A:match("%d"))) then
				Text = Text .. A
			end
		elseif (Event == "paste") then
			if (Options.Numeric) then
				A = A:gsub("%D", "")
			end
			Text = (Text .. A):sub(1, MaxLen)
		elseif (Event == "key") then
			if (A == keys.backspace) then
				Text = Text:sub(1, -2)
			elseif (A == keys.enter or A == keys.numPadEnter) then
				Done, Result = true, Text
			end
		elseif (Event == "mouse_click") then
			UI.Click(B, C, A)
		end
	end

	term.setCursorBlink(false)
	Buttons = SavedButtons
	return Result
end

return UI
