local args = { ... }

local version = '0.3.x'
local meta_protocol = ('multi-chat-%s'):format(version)
local shellEnv = { shell = shell, multishell = multishell }
local function run_on_src(mode, method, ...)
	local file = fs.open(shell.getRunningProgram(), mode)
	--- @cast file -nil -- since it should always exist
	local ok, res
	if type(method) == 'function' then
		ok, res = pcall(method, file, ...)
	else
		ok, res = pcall(file[method], ...)
	end
	file.close()
	if not ok then
		error(res)
	else
		return res
	end
end
local function get_hash() return run_on_src('r', 'readLine') end
local function update_from_source()
	print 'Trying remote source'
	local response, err, errResponse = http.get(
		('https://api.github.com/repos/%s/%s/contents/%s?ref=%s')
		:format('jkeDev', 'multi-chat.cc', 'client.lua', version))
	--- @cast errResponse -nil when response is null
	if response == nil then error(('[%s] %s'):format(errResponse.getResponseCode(), err)) end
	local json = textutils.unserializeJSON(response.readAll() or '', { parse_empty_array = false }) or {}
	if type(json.sha) ~= 'string' or type(json.content) ~= 'string' then
		error 'Malformed response from github'
	end
	if get_hash() == json.sha then return end
	if json.encoding ~= 'base64' then error(('Upstream is in non base64 encoding: %s'):format(json.encoding)) end
	run_on_src('w', function(file)
		file.write(('-- %s\n'):format(json.sha))
		local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
		local raw = json.content:gsub('\n', '')
		local buf = 0
		for i = 1, #raw do
			local char = raw:sub(i, i)
			if char == '=' then
				if i % 4 == 0 then -- one padding byte
					file.write(string.char(bit32.extract(buf, 10, 8), bit32.extract(buf, 2, 8)))
				else -- two padding bytes
					file.write(string.char(bit32.extract(buf, 4, 8)))
				end
				break
			end
			local n = b:find(char) - 1
			buf = bit32.lshift(buf, 6) + n
			if i % 4 == 0 then
				file.write(string.char(
					bit32.extract(buf, 16, 8),
					bit32.extract(buf, 8, 8),
					bit32.extract(buf, 0, 8)))
				buf = 0
			end
		end
	end)
end
local function update()
	print 'Checking for updates'
	rednet.broadcast('get-hash', meta_protocol)
	local tEnd, from, from2, mes = 5 + os.clock(), nil, nil, nil
	repeat
		from, mes = rednet.receive(meta_protocol, tEnd - os.clock())
		if from == nil then
			if http ~= nil then update_from_source() end
			return
		end
	until type(mes) == 'table' and mes.cmd == 'hash'
	--- @cast from -nil Cannot escape previous loop with from equals nil
	--- @cast mes -nil See above
	if mes.hash == get_hash() then return end
	rednet.send(from, 'get-src', meta_protocol)
	tEnd = 5 + os.clock()
	repeat
		from2, mes = rednet.receive(meta_protocol, tEnd - os.clock())
		if from2 == nil then
			print 'Did not get update'
			if http ~= nil then update_from_source() end
			return
		end
	until from2 == from and type(mes) == 'table' and mes.cmd == 'src'
	--- @cast mes -nil See above
	run_on_src('w', 'write', mes.src)
end
local function handle_meta_messages(only_supply_updates)
	return function()
		local hash = get_hash()
		local src = run_on_src('r', 'readAll')
		local username = os.getComputerLabel()
		local active_protocols = {}
		local users = setmetatable({
			[os.getComputerID()] = 'You',
		}, {
			__index = function(_, from)
				return ('%5d'):format(from)
			end
		})
		local function handle_message(from, cmd, mes)
			if cmd == 'get-hash' then
				rednet.send(from, { cmd = 'hash', hash = hash }, meta_protocol)
			elseif cmd == 'get-src' then
				rednet.send(from, { cmd = 'src', src = src }, meta_protocol)
			elseif only_supply_updates then
				return
			elseif cmd == 'open-chat' then
				local protocol, name = mes.protocol, mes.name
				if type(protocol) ~= 'string'
					or (name ~= nil and type(name) ~= 'string') then
					return
				end
				if active_protocols[protocol] == nil then
					local pid = multishell.launch(shellEnv, shell.getRunningProgram(), 'rednet', protocol, name, users)
					multishell.setTitle(pid, name or protocol)
					active_protocols[protocol] = true
				end
				if username ~= nil then rednet.broadcast({ cmd = 'set-name', name = username }, meta_protocol) end
			elseif cmd == 'set-name' then
				users[from] = mes.name
			end
		end
		while true do
			local from, mes = rednet.receive(meta_protocol)
			if type(mes) == 'string' then
				handle_message(from, mes, {})
			elseif type(mes) == 'table' then
				handle_message(from, mes.cmd, mes)
			end
		end
	end
end

if #args <= 0 then
	os.run(shellEnv, shell.getRunningProgram(), 'update')
	os.run(shellEnv, shell.getRunningProgram(), 'run')
elseif args[1] == 'update' then
	peripheral.find('modem', rednet.open)
	update()
elseif args[1] == 'run' then
	term.clear()
	term.setCursorPos(1, 1)
	local name = os.getComputerLabel()
	if name ~= nil then rednet.broadcast({ cmd = 'set-name', name = name }, meta_protocol) end
	parallel.waitForAll(
		function() os.run(shellEnv, 'rom/programs/shell.lua') end,
		handle_meta_messages(false),
		function()
			local global_chat = {
				cmd = 'open-chat',
				protocol = 'rednet-chat',
				name = 'chat'
			}
			os.queueEvent('rednet_message', -1, global_chat, meta_protocol)
			rednet.broadcast(global_chat, meta_protocol)
		end
	)
elseif args[1] == 'rednet' then
	local protocol = args[2]
	local users = args[4]
	if protocol == nil then
	else
		local parent = term.current()
		local w, h = parent.getSize()
		local messageScreen = window.create(parent, 1, 1, w, h - 1)
		local inputField = window.create(parent, 1, h, w, 1)
		local nw, nh = term.native().getSize()
		local nx, ny = nw / 2, nh * 4 / 5
		nw, nh = nw - nx + 1, nh - ny + 1
		local notifyTimer = nil
		local notifyTerm = window.create(term.native(), nx, ny, nw, nh, false)
		notifyTerm.setBackgroundColor(colors.gray)
		local function withTerm(redirect, func, ...)
			local old = term.current()
			term.redirect(redirect)
			local val = { func(...) }
			term.redirect(old)
			return table.unpack(val)
		end
		parallel.waitForAny(
			function()
				while true do
					local from, message = rednet.receive(protocol)
					if multishell.getFocus() ~= multishell.getCurrent() then
						notifyTerm.clear()
						if notifyTimer ~= nil then os.cancelTimer(notifyTimer) end
						notifyTimer = os.startTimer(5)
						notifyTerm.setVisible(true)
						withTerm(notifyTerm,
							print, ('%s\n%s: %s'):format(args[3] or protocol, users[from], message))
					end
					withTerm(messageScreen,
						print, ('%s: %s'):format(users[from], message))
				end
			end,
			function()
				while true do
					local _, id = os.pullEvent 'timer'
					if id == notifyTimer then
						notifyTerm.setVisible(false)
						os.queueEvent 'term_resize'
					end
				end
			end,
			function()
				while true do
					os.pullEvent 'term_resize'
					messageScreen.redraw()
					inputField.redraw()
				end
			end,
			function()
				while true do
					inputField.write '> '
					local message = withTerm(inputField, read)
					rednet.broadcast(message, protocol)
					rednet.send(os.getComputerID(), message, protocol)
				end
			end
		)
	end
elseif args[1] == 'rednet-bot' then
	local protocol = args[2]
	rednet.broadcast({ cmd = 'open-chat', protocol = protocol }, meta_protocol)
	rednet.broadcast({
		cmd = 'set-name',
		name =
			turtle and 'Turtle'
			or (pocket and 'Pocket'
				or 'Server')
	}, meta_protocol)
	parallel.waitForAny(
		handle_meta_messages(true),
		function()
			os.run({
				shell = shell,
				multishell = multishell,
				print = function(...)
					print(...)
					rednet.broadcast(table.concat({ ... }, '\t'), protocol)
				end,
			}, args[3])
		end
	)
end
