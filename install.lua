-- Minepanda installer. Run in-game with:
--   wget run https://raw.githubusercontent.com/tamayaren/Minepanda/main/install.lua [server|client]
local BaseUrl = "https://raw.githubusercontent.com/tamayaren/Minepanda/main/"
local RolePath = "/minepanda/role"
local StartupPath = "/startup.lua"
local StartupMarker = "-- Minepanda startup"

local Files = {
	Shared = {"minepanda/lib/common.lua", "minepanda/lib/ui.lua"},
	Server = {"minepanda/server.lua"},
	Client = {"minepanda/client.lua"}
}

local Programs = {
	Server = "/minepanda/server.lua",
	Client = "/minepanda/client.lua"
}

local function ReadFile(Path)
	if (not fs.exists(Path)) then return nil end

	local Handle = fs.open(Path, "r")
	local Contents = Handle.readAll()
	Handle.close()
	return Contents
end

local function WriteFile(Path, Contents)
	fs.makeDir(fs.getDir(Path))
	local Handle = fs.open(Path, "w")
	Handle.write(Contents)
	Handle.close()
end

local function Ask(Question)
	write(Question .. " ")
	return (read() or ""):lower()
end

-- Picks the role from the argument, the last install, or by asking.
local function ChooseRole(Argument)
	Argument = (Argument or ""):lower()
	if (Argument == "server") then return "Server" end
	if (Argument == "client") then return "Client" end

	local Previous = ReadFile(RolePath)
	if (Previous == "Server" or Previous == "Client") then
		print("Updating the Minepanda " .. Previous:lower() .. ".")
		return Previous
	end

	local Suggested = "server"
	if (pocket) then
		Suggested = "client"
	end

	while (true) do
		local Answer = Ask("Install as (s)erver or (c)lient? [" .. Suggested .. "]")
		if (Answer == "") then
			Answer = Suggested
		end

		if (Answer == "s" or Answer == "server") then return "Server" end
		if (Answer == "c" or Answer == "client") then return "Client" end
		print("Please type s or c.")
	end
end

local function Download(Path)
	-- The query string skips GitHub's cache so updates arrive straight away.
	local Url = BaseUrl .. Path .. "?t=" .. os.epoch("utc")
	local Response, Problem = http.get(Url)
	if (not Response) then
		error("Couldn't download " .. Path .. ": " .. tostring(Problem), 0)
	end

	local Contents = Response.readAll()
	Response.close()
	WriteFile("/" .. Path, Contents)
	print("  " .. Path)
end

-- Starts the program on boot without clobbering someone else's startup.lua.
local function InstallStartup(Role)
	local Existing = ReadFile(StartupPath)
	if (Existing and not Existing:find(StartupMarker, 1, true)) then
		local Answer = Ask("startup.lua already exists. Replace it so Minepanda starts on boot? (y/n)")
		if (Answer ~= "y" and Answer ~= "yes") then
			print("Skipped. Start it yourself with: " .. Programs[Role])
			return
		end
	end

	WriteFile(StartupPath, StartupMarker .. "\nshell.run(\"" .. Programs[Role] .. "\")\n")
end

local function Main(...)
	if (not http) then
		error("The HTTP API is disabled on this server, so the installer can't download files.", 0)
	end
	if (not term.isColour()) then
		error("Minepanda needs an Advanced Computer or Advanced Pocket Computer.", 0)
	end

	local Role = ChooseRole(...)
	if (Role == "Server" and pocket) then
		print("Note: the server is meant for an Advanced Computer, not a pocket computer.")
	end

	print("Downloading Minepanda " .. Role:lower() .. "...")
	for _, Path in ipairs(Files.Shared) do
		Download(Path)
	end
	for _, Path in ipairs(Files[Role]) do
		Download(Path)
	end

	WriteFile(RolePath, Role)
	InstallStartup(Role)

	print("Done! Updating never touches saved menus or orders.")
	local Answer = Ask("Start Minepanda now? (y/n)")
	if (Answer == "y" or Answer == "yes" or Answer == "") then
		shell.run(Programs[Role])
	end
end

Main(...)
