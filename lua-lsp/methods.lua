-- the actual meat and potatos of the app
local analyze = require 'lua-lsp.analyze'
local rpc     = require 'lua-lsp.rpc'
local log     = require 'lua-lsp.log'
local utf     = require 'lua-lsp.unicode'
local json    = require 'dkjson'

local method_handlers = {}

-- luacheck: globals Initialized Documents Root Shutdown

function method_handlers.initialize(params, id)
	if Initialized then
		error("already initialized!")
	end
	_G.Root  = params.rootPath or params.rootUriA
	log("Root = %q", Root)	
	log.setTraceLevel(params.trace or "off")
	--if params.initializationOptions then
	--	-- use for server-specific config?
	--end
	--ClientCapabilities = params.capabilities
	Initialized = true

	-- hopefully this is modest enough
	rpc.respond(id, {
		capabilities = {
			completionProvider = {
				triggerCharacters = {".",":"},
				resolveProvider = false
			},
			definitionProvider = true,
			textDocumentSync = {
				openClose = true,
				change = 1, -- 1 is non-incremental, 2 is incremental
				save = { includeText = true },
			},
			hoverProvider = true,
			documentSymbolProvider = false,
			--referencesProvider = false,
			--documentHighlightProvider = false,
			--workspaceSymbolProvider = false,
			--codeActionProvider = false,
			--documentFormattingProvider = false,
			--documentRangeFormattingProvider = false,
			--renameProvider = false,
		}
	})
end

local function document_for(uri)
	if Documents[uri] then
		return Documents[uri]
	end
	local document = {}
	document.uri = uri

	local f = assert(io.open(uri:gsub("^[^:]+://", ""), "r"))
	document.text  = f:read("*a")
	f:close()

	analyze.document(document)

	Documents[uri] = document

	return document
end

method_handlers["textDocument/didOpen"] = function(params)
	Documents[params.textDocument.uri] = params.textDocument
	analyze.document(params.textDocument)
end

method_handlers["textDocument/didChange"] = function(params)
	local uri = params.textDocument.uri
	local document = document_for(uri)

	for _, patch in ipairs(params.contentChanges) do
		if (patch.range == nil and patch.rangeLength == nil) then
			document.text = patch.text
		else
			error("NYI")
			-- remove text from patch.range.start -> patch.range["end"]
			-- assert(patch.rangeLength == actual_length)
			-- then insert patch.text at origin point
		end
	end

	analyze.document(document)
end

method_handlers["textDocument/didSave"] = function(params)
	local uri = params.textDocument.uri
	local document = document_for(uri)
	-- FIXME: merge in details from params.textDocument
	analyze.document(document)
end

method_handlers["textDocument/didClose"] = function(params)
	Documents[params.textDocument.uri] = nil
end

local function pick_scope(scopes, pos)
	assert(scopes ~= nil)
	local closest = nil
	local size = math.huge
	for _, scope in ipairs(scopes) do
		local meta = getmetatable(scope)
		local dist = meta.posEnd - meta.pos
		if meta.pos <= pos and meta.posEnd >= pos and dist < size then
			size = dist
			closest = scope
		end
	end

	return closest
end

local completionKinds = {
	Text = 1,
	Method = 2,
	Function = 3,
	Constructor = 4,
	Field = 5,
	Variable = 6,
	Class = 7,
	Interface = 8,
	Module = 9,
	Property = 10,
	Unit = 11,
	Value = 12,
	Enum = 13,
	Keyword = 14,
	Snippet = 15,
	Color = 16,
	File = 17,
	Reference = 18,
}

local function make_item(k, _, val)
	local item = { label = k }

	if val then
		item.kind = completionKinds.Variable
		if val.tag == "Call" then
			if val[1][1] == "require" then
				-- this is a module
				item.kind = completionKinds.Module
			end
		elseif val.tag == "Function" then
			-- generate function signature
			local sig
			if val.signature then
				sig = val.signature
			else
				sig = {}
				for _, name in ipairs(val.arguments) do
					if name.tag == "Dots" then
						table.insert(sig, "...")
					elseif name[1] then
						table.insert(sig, name[1])
					elseif name.displayName then
						table.insert(sig, name.displayName)
					elseif name.name then
						table.insert(sig, name.name)
					end
				end
				sig = table.concat(sig, ", ")
			end

			local ret = "()"
			local literals = {String = "string", Number = "number", True = "bool", False = "bool", Nil = "nil"}
			if val.scope then
				local scope_mt = getmetatable(val.scope)
				if scope_mt._return then
					local types, values, noValues = {}, {}, false
					for _, r in ipairs(scope_mt._return) do
						if literals[r.tag] then
							table.insert(types, literals[r.tag])
							if not r[1] then
								noValues = true
							elseif r.tag == "String" then
								table.insert(values, string.format("%q", r[1]))
							elseif r.tag == "Number" then
								table.insert(values, tostring(r[1]))
							end
						else
							noValues = true
						end
					end
					if noValues then 
						ret = table.concat(types, "|")
					else
						ret = table.concat(values, "|")
					end
					--ret = "?"
				end
			elseif val.returns then
				ret = {}
				for _, r in ipairs(val.returns) do table.insert(ret, r.name) end
				ret = table.concat(ret, ", ")
			end


			item.kind = completionKinds.Function
			item.insertText = k
			item.label = ("%s(%s) -> %s"):format(k, sig, ret)
			item.documentation = val.description
		elseif val.tag == "Table" then
			item.detail = "<table>"
		elseif val.tag == "String" or val.tag == "Number" then
			item.kind = completionKinds.Field
			item.documentation = val.description
			if val.value then
				item.detail = string.format("%q", val.value)
			else
				item.detail = string.format("<%s>", val.tag)
			end
		end
	end

	item.kind = nil
	return item
end

local function iter_scope(scope)
	return coroutine.wrap(function()
		while scope do
			for key, nodes in pairs(scope) do
				local symbol, value = unpack(nodes)
				coroutine.yield(key, symbol, value)
			end
			local mt = getmetatable(scope)
			scope = mt and mt.__index
		end
	end)
end

method_handlers["textDocument/completion"] = function(params, id)
	local pos = params.position
	local document = document_for(params.textDocument.uri)
	if document.scopes == nil then
		return rpc.respond(id, {
			isIncomplete = false,
			items = {}
		})
	end
	local line = document.lines[pos.line+1]

	local char = utf.to_bytes(line.text, pos.character)
	local word = line.text:sub(1, char):match("[A-Za-z_][%w_.:]*$") or ""

	local items = {}
	local used  = {}
	if char then
		local realpos = line.start + char - 1
		local scope = pick_scope(document.scopes, realpos)

		if word:find("[:.]") then
			-- path scope
			local path_ids = {}

			for s in word:gmatch("[^:.]*") do table.insert(path_ids, s) end
			for i=#path_ids, 2, -2 do table.remove(path_ids, i) end

			local iword = path_ids[1]
			local function follow_path(ii, _scope)
				assert(_scope)
				local _iword = path_ids[ii]
				local last = ii == #path_ids
				for iname, node, val in iter_scope(_scope) do
					if last then
						if iname:sub(1, _iword:len()) == _iword then
							table.insert(items, make_item(iname, node, val))
						end
					elseif iname == _iword and val.tag == "Table" then
						if val.scope then
							follow_path(path_ids, ii+1, val.scope)
						end
					end
				end
			end

			for iname, node, val in iter_scope(scope) do
				if not used[iname] and node.pos <= realpos then
					used[iname] = true
					if iname == iword and val.tag == "Table" then
						if val.scope then
							follow_path(2, val.scope)
						end
					end
				end
			end
		else
			-- variable scope
			for iname, node, val in iter_scope(scope) do
				if not used[iname] and node.pos <= realpos then
					used[iname] = true
					if iname:sub(1, word:len()) == word then
						table.insert(items, make_item(iname, node, val))
					end
				end
			end
		end
	end

	return rpc.respond(id, {
		isIncomplete = false,
		items = items
	})
end

local function make_position(document, pos)
	local last_linepos = nil
	for i, line in ipairs(document.lines) do
		if line.start > pos then
			local text = document.lines[i-1].text
			return {
				line = i-1-1, 
				character = utf.to_codeunits(text, pos - last_linepos + 1)
			}
		end
		last_linepos = line.start
	end
	return nil
end

-- turn two index arguments into a range
local function make_range(document, startidx, endidx)
	return {
		start   = make_position(document, startidx),
		["end"] = make_position(document, endidx)
	}
end

local function make_location(document, symbol)
	return {
		uri = document.uri,
		range = make_range(document, symbol.pos, symbol.posEnd)
	}
end

--- Returns line and index for an LSP position. index is relative to line, not
--  the document, and is measured in bytes.
local function line_for(document, pos)
	local line = document.lines[pos.line+1]
	local char = utf.to_bytes(line.text, pos.character)

	return line, char
end

--- Returns a document index for an LSP position. Indexes are measured in bytes.
local function index_for(document, pos)
	local line, char = line_for(document, pos)

	return line.start + char - 1
end


method_handlers["textDocument/definition"] = function(params, id)
	local pos = params.position
	local document = document_for(params.textDocument.uri)

	local line = document.lines[pos.line+1]
	local char = utf.to_bytes(line.text, pos.character)
	assert(char)
	local word_s = line.text:sub(1, char):find("[%w.:_]*$")
	-- FIXME: this looks for the parent local, which makes sense if you're
	-- looking at a local variable, but if you want to find an actual function
	-- definition this is inconvenient
	local word = line.text:sub(word_s, -1):match("^([%a_][%w_.:]*)")

	local used  = {}
	if char then
		local realpos = line.start + char - 1
		local scope = pick_scope(document.scopes, realpos)
		local word_start = word:match("^([^.:]+)")
		for k, symbol in iter_scope(scope) do
			if not used[k] and symbol.canGoto ~= false and symbol.pos <= realpos then
				if k == word_start then
					if word:find("[:.]") then
						error("NYI field definition")
					else
						local sub = document.text:sub(symbol.pos, symbol.posEnd)
						local a, b = string.find(sub, k, 1, true)
						a, b = a + symbol.pos - 1, b + symbol.pos - 1

						local range = make_range(document, a, b)
						rpc.respond(id, {
							uri = params.textDocument.uri,
							range = range
						})
						return
					end
				end
			end
		end
	end

	rpc.respondError(id, string.format("symbol %q not found", word))
end

method_handlers["textDocument/documentSymbol"] = function(params, id)
	local document = document_for(params.textDocument.uri)
	local symbols = {}

	for _, scope in ipairs(document.scopes) do
		for _, pair in pairs(scope) do
			local symbol, _ = unpack(pair)
			if symbol.canGoto ~= false then
				table.insert(symbols, {
					name = symbol[1],
					kind = 13,
					location = make_location(document, symbol),
					containerName = nil -- use for fields
				})
			end
		end
	end
	return rpc.respond(id, symbols)
end

function method_handlers.shutdown(_, id)
	Shutdown = true
	rpc.respond(id, json.null)
end

function method_handlers.exit(_)
	if Shutdown then
		os.exit(0)
	else
		os.exit(1)
	end
end

return method_handlers
