local codec  = require('http/codec')
local core 	 = require('core')
local dgram  = require('dgram')
local http   = require('http')
local json   = require('json')
local path 	 = require('path')
local utils  = require('utils')

local TAG = 'SsdpObject'

local exports = {}

local UPNP_DEVICE_TYPE	= "urn:schemas-upnp-org:device:Vision:1"
local UPNP_ADDRESS 		= '239.255.255.250'
local UPNP_PORT 		= 1900
local UPNP_ROOT_DEVICE	= "upnp:rootdevice"
local INET_ADDR_ANY  	= '0.0.0.0'

exports.UPNP_DEVICE_TYPE = UPNP_DEVICE_TYPE
exports.UPNP_ADDRESS 	 = UPNP_ADDRESS
exports.UPNP_PORT 		 = UPNP_PORT
exports.UPNP_ROOT_DEVICE = UPNP_ROOT_DEVICE
exports.INET_ADDR_ANY 	 = INET_ADDR_ANY

local _getIPv4Number = function(ip)
	local tokens = ip:split('.')
	local ret = (tokens[1] << 24) + (tokens[2] << 16) + (tokens[3] << 8) + (tokens[4])
	return math.floor(ret)
end

local _getBroadcastAddress = function (item)
	local ip      = _getIPv4Number(item.ip)
	local netmask = _getIPv4Number(item.netmask)

	local broadcast = ip | ~netmask & 0xffffffff
	return string.format("%d.%d.%d.%d", 
		(broadcast >> 24) & 0xff, (broadcast >> 16) & 0xff, 
		(broadcast >> 8)  & 0xff,  broadcast & 0xff)
end

-------------------------------------------------------------------------------
-- SsdpMessage

local SsdpMessage = core.Emitter:extend()
exports.SsdpMessage = SsdpMessage

function SsdpMessage:initialize(head, socket)
    self.httpVersion = tostring(head.version)
    local headers = setmetatable( { }, http.headerMeta)
    for i = 1, #head do
        headers[i] = head[i]
    end

    self.headers = headers
    if head.method then
        -- server specific
        self.method = head.method
        self.url 	= head.path
    else
        -- client specific
        self.statusCode 	= head.code
        self.statusMessage 	= head.reason
    end
    self.socket = socket
end

-------------------------------------------------------------------------------
-- SsdpObject

local SsdpObject = core.Emitter:extend()
exports.SsdpObject = SsdpObject

function SsdpObject:_createSocket(host, localPort)
-- [[
	local socket = dgram.createSocket('udp4')
	self.socket = socket

	local _onMessage, _onError, _onListening

	_onMessage = function (packet, remote)
		local localAddress = socket:address()
  		--console.log(TAG, #packet, remote.ip, remote.port)

  		local message = self:_parseMessage(packet)
  		if (not message) then
  			print('error', remote.ip, remote.port, packet)
  			return
  		end

  		if (message.method) then
  			self:_handleRequest(message, remote)

  		else
  			self:_handleResponse(message, remote)
  		end
	end

	_onError = function (err)
	  	console.log(TAG, '_onError', err)
	end

	_onListening = function ()
	  	--console.log(TAG, '_onListening')

		socket:setBroadcast(true)
		socket:addMembership(UPNP_ADDRESS)
		socket:setMulticastTTL(1)
		socket:setMulticastLoop(false)
	end

	socket:on('message',   _onMessage)
	socket:on('error',     _onError)
	socket:on('listening', _onListening)
	
	local port = localPort or self.port or UPNP_PORT
	socket:bind(port, host)

--]]	
end

function SsdpObject:_getLocalAddresses(mode)
	local addresses = {}

	local interfaces = os.networkInterfaces()
	if (not interfaces) then
		return 
	end

	local family = mode or 'inet'

	for _, interface in pairs(interfaces) do
		if (type(interface) ~= 'table') then
			break
		end

		for _, item in pairs(interface) do
			if (not item) then
				break
			end

			if (item.family == family and not item.internal) then
				item.broadcast = _getBroadcastAddress(item)
				table.insert(addresses, item)
			end
		end
	end

	return addresses
end

function SsdpObject:_handleNotify(request, remote)

end

function SsdpObject:_handleRequest(request, remote)
	local method = request.method
	if (method == 'NOTIFY') then
		self:_handleNotify(request, remote)

	elseif (method == 'M-SEARCH') then
		self:_handleSearch(request, remote)
	end
end

function SsdpObject:_handleResponse(response, remote)

end

function SsdpObject:_handleSearch(request, remote)

end

function SsdpObject:_parseMessage(message)
	self.decode  = codec.decoder()
	
	local ret, event = pcall(self.decode, message)
	if (ret) and (event) and(event ~= '') then
  		return SsdpMessage:new(event)
	end
end

function SsdpObject:_pareseHeaders( message )
	-- body
	local table = {}
	for i, v in pairs(message) do  
	    if type(v) == "table" then  
	        table.headers = {}
	        for new_table_index, new_table_value in pairs(v) do  
	            -- console.log(new_table_index,new_table_value)  
	            if new_table_value[1] == 'HOST' then
	                table.headers.HOST = new_table_value[2]    
	            elseif new_table_value[1] == 'MAN' then
	                table.headers.MAN = new_table_value[2]
	            elseif new_table_value[1] == 'ST' then
	                table.headers.ST = new_table_value[2]
	            elseif new_table_value[1] == 'MX' then
	                table.headers.MX = new_table_value[2]
	            end
	            -- parse_head(table,new_table_value)
	        end  
	    else  
	        -- console.log(i,v)  
	        if i == 'httpVersion' then
	                table.httpVersion = v   
	            elseif i == 'method' then
	                table.method = v
	            elseif i == 'url' then
	                table.url = v
	            end
	        -- table.i = v
	    end  
	end  
  	-- console.log('table',table)
  	return table
end

function SsdpObject:_sendMessage(message, host, port, callback)
	-- (message, callback)
	if (type(host) == 'function') then
		callback = host
		host = UPNP_ADDRESS
		port = self.port

	-- (message, port, callback)
	elseif (not host) then
		host = UPNP_ADDRESS
		port = self.port

	end

	local socket = self.socket
	if (not socket) then
		if (callback) then 
			callback('Bad socket') 
		end
		return
	end

	if (not port or port <= 0) then
	 	port = UPNP_PORT
	end

	--print(TAG, 'send', host, port, #message)
	socket:send(message, port, host, callback)
end

function SsdpObject:_stop()
	if (self.socket) then
		self.socket:close()
		self.socket = nil
	end

	self._started = false
end

return exports
