local pairs    = pairs
local type     = type
local tonumber = tonumber
local tostring = tostring
local setmetatable = setmetatable
local encode_args  = ngx.encode_args
local tcp    = ngx.socket.tcp
local concat = table.concat
local insert = table.insert
local upper  = string.upper
local lower  = string.lower
local sub    = string.sub
local sfind  = string.find
local gmatch = string.gmatch
local gsub = string.gsub
local ipairs = ipairs
local rawset = rawset
local rawget = rawget

local ngx = ngx

module(...)

_VERSION = "0.1.0"

--------------------------------------
-- LOCAL CONSTANTS                  --
--------------------------------------
local HTTP_1_1   = " HTTP/1.1\r\n"
local CHUNK_SIZE = 1048576
local USER_AGENT = "Resty/HTTP " .. _VERSION .. " (Lua)"

-- canonical names for common headers
local common_headers = {
    "Cache-Control",
    "Content-Length", 
    "Content-Type", 
    "Date",
    "ETag",
    "Expires",
    "Host",
    "Location",
    "User-Agent"
}

for _,key in ipairs(common_headers) do
    rawset(common_headers, key, key)
    rawset(common_headers, lower(key), key)
end

local function header_case_fixups(table, key)
    local val = rawget(table, key)
    if val then
	return val
    end
    val =  rawget(table, lower(key))
    if val then
	return val
    end
    -- normalize it ourselves. do not cache it as we could explode our memory usage
    key = gsub(key, "^%l", upper)
    key = gsub(key, "-%l", upper)
    return key
end

setmetatable(common_headers, { __index = header_case_fixups })

function normalize_header(key)
    return common_headers[key]
end


--------------------------------------
-- LOCAL HELPERS                    --
--------------------------------------

local function _req_header(conf, opts)
    opts = opts or {}

    -- Initialize request
    local req = {
	upper(opts.method or "GET"),
	" "
    }

    -- Append path
    local path = opts.path or conf.path
    if type(path) ~= "string" then
	path = "/"
    elseif sub(path, 1, 1) ~= "/" then
	path = "/" .. path
    end
    insert(req, path)

    -- Normalize query string
    if type(opts.query) == "table" then
	opts.query = encode_args(opts.query)
    end

    -- Append query string
    if type(opts.query) == "string" then
	insert(req, "?" .. opts.query)
    end

    -- Close first line
    insert(req, HTTP_1_1)

    -- Normalize headers
    opts.headers = opts.headers or {}
    local headers = {}
    for k,v in pairs(opts.headers) do
	headers[normalize_header(k)] = v
    end
    
    if opts.body then
	headers['Content-Length'] = #opts.body
    end
    if not headers['Host'] then
	headers['Host'] = conf.host
    end
    if not headers['User-Agent'] then
	headers['User-Agent'] = USER_AGENT
    end
    if not headers['Accept'] then
	headers['Accept'] = "*/*"
    end

    -- Append headers
    for key, values in pairs(headers) do
	if type(values) ~= "table" then
	    values = {values}
	end
	
	key = tostring(key)
	for _, value in pairs(values) do
	    insert(req, key .. ": " .. tostring(value) .. "\r\n")
	end
    end
    
    -- Close headers
    insert(req, "\r\n")
    
    return concat(req)
end

local function _parse_headers(sock)
    local headers = {}
    local mode    = nil
    
    repeat
	local line = sock:receive()
	
	for key, val in gmatch(line, "([%w%-]+)%s*:%s*(.+)") do
	    key = normalize_header(key)
	    if headers[key] then
		local delimiter = ", "
		if key == "Set-Cookie" then
		    delimiter = "; "
		end
		headers[key] = headers[key] .. delimiter .. tostring(val)
	    else
		headers[key] = tostring(val)
	    end
	end
    until sfind(line, "^%s*$")
    
    return headers, nil
end

local function _receive_length(sock, length)
    local chunks = {}

    while length > CHUNK_SIZE do
	local chunk, err = sock:receive(CHUNK_SIZE)
	if not chunk then
	    return nil, err
	end

	insert(chunks, chunk)
	length = length - CHUNK_SIZE
    end

    if length > 0 then
	local chunk, err = sock:receive(length)
	if not chunk then
	    return nil, err
	end

	insert(chunks, chunk)
    end

    return concat(chunks), nil
end


local function _receive_chunked(sock)
    local chunks = {}

    repeat
	local str, err = sock:receive()
	if not str then
	    return nil, err
	end

	local length = tonumber(str, 16)
	if not length or length < 1 then
	    break
	end

	local str, err = sock:receive(length + 2)
	if not str then
	    return nil, err
	end

	insert(chunks, str)
    until false
    sock:receive(2)

    return concat(chunks), nil
end


local function _receive(self, sock)
    local line, err = sock:receive()
    if not line then
	return nil, err
    end

    local status = tonumber(sub(line, 10, 12))

    local headers, err = _parse_headers(sock)
    if not headers then
	return nil, err
    end

    local length = tonumber(headers["Content-Length"])
    local body

    if length then
	local str, err = _receive_length(sock, length)
	if not str then
	    return nil, err
	end
	body = str
    elseif lower(headers["Transfer-Encoding"]) == "chunked" then
	local str, err = _receive_chunked(sock)
	if not str then
	    return nil, err
	end
	body = str
    else
	local str, err = sock:receive()
	headers["Connection"] = "close"
	if not str then
	    return nil, err
	end
	body = str
    end

    if lower(headers["Connection"]) == "close" then
	self:close()
    else
	self:set_keepalive()
    end

    return { status = status, headers = headers, body = body }
end


--------------------------------------
-- PUBLIC API                       --
--------------------------------------

function new(self)
    local sock, err = tcp()
    if not sock then
	return nil, err
    end

    return setmetatable({ sock = sock }, { __index = _M })
end


function connect(self, host, port, conf)
    local sock = self.sock
    if not sock then
	return nil, "not initialized"
    end

    conf = conf or {}
    conf.host = host
    conf.port = tonumber(port) or 80

    if not conf.scheme then
	if conf.port == 443 then
	    conf.scheme = "https"
	else
	    conf.scheme = "http"
	end
    end
    self.conf = conf

    return sock:connect(conf.host, conf.port)
end


function get_reused_times(self)
    local sock = self.sock
    if not sock then
	return nil, "not initialized"
    end

    return sock:getreusedtimes()
end


function set_timeout(self, timeout)
    local sock = self.sock
    if not sock then
	return nil, "not initialized"
    end

    return sock:settimeout(timeout)
end


function set_keepalive(self, ...)
    local sock = self.sock
    if not sock then
	return nil, "not initialized"
    end

    return sock:setkeepalive(...)
end


function close(self)
    local sock = self.sock
    if not sock then
	return nil, "not initialized"
    end
    self.conf = nil

    return sock:close()
end


function request(self, opts)
    local sock = self.sock
    if not sock then
	return nil, "not initialized"
    end

    local conf = self.conf
    if not conf then
	return nil, "not connected"
    end

    -- Build and send request header
    local header = _req_header(conf, opts)
    local bytes, err = sock:send(header)
    if not bytes then
	return nil, err
    end

    -- Send the body if there is one
    if opts and type(opts.body) == "string" then
	local bytes, err = sock:send(opts.body)
	if not bytes then
	    return nil, err
	end
    end

    return _receive(self, sock)
end

