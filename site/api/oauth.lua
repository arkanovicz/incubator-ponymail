--[[
 Licensed to the Apache Software Foundation (ASF) under one or more
 contributor license agreements.  See the NOTICE file distributed with
 this work for additional information regarding copyright ownership.
 The ASF licenses this file to You under the Apache License, Version 2.0
 (the "License"); you may not use this file except in compliance with
 the License.  You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
]]--

-- This is oauth.lua - an oauth providing script for ponymail

local JSON = require 'cjson'
local http = require 'socket.http'
local elastic = require 'lib/elastic'
local https = require 'ssl.https'
local user = require 'lib/user'
local cross = require 'lib/cross'

function handle(r)
    r.content_type = "application/json"
    local get = r:parseargs()
    local post = r:parsebody()
    local valid, json
    local scheme = "https"
    if r.port == 80 then
        scheme = "http"
    end
    
    local oauth_domain = ""
    -- Persona callback
    if get.mode and get.mode == "persona" then
        oauth_domain = "verifier.login.persona.org"
        local result = https.request("https://verifier.login.persona.org/verify", ("assertion=%s&audience=%s://%s:%u/"):format(post.assertion, scheme, r.hostname, r.port))
        r:err(("assertion=%s&audience=%s://ponymail:443/"):format(post.assertion, scheme))
        r:err(result)
        valid, json = pcall(function() return JSON.decode(result) end)
        
    -- Google Auth callback
    elseif get.oauth_token and get.oauth_token:match("^https://www.google") and get.id_token then
        oauth_domain = "www.googleapis.com"
        local result = https.request("https://www.googleapis.com/oauth2/v3/tokeninfo?id_token=" .. r:escape(get.id_token))
        valid, json = pcall(function() return JSON.decode(result) end)
        
    -- Generic callback (like ASF Oauth2)
    elseif get.state and get.code and get.oauth_token then
        oauth_domain = get.oauth_token:match("https?://(.-)/")
        local result = https.request(get.oauth_token, r.args)
        valid, json = pcall(function() return JSON.decode(result) end)
    end
    
    -- Did we get something useful from the backend?
    if valid and json then
        local eml = json.email
        local fname = json.fullname or json.name or json.email
        local admin = json.isMember
        
        -- If we got an email and a name, log in the user and set cookie etc
        if eml and fname then
            local cid = json.uid or json.email
            -- Does the user exist already?
            local oaccount = user.get(r, cid)
            local usr = {}
            if oaccount then
                usr.preferences = oaccount.preferences
            else
                usr.preferences = {}
            end
            usr.gauth = get.id_token
            usr.fullname = fname
            
            -- if the oauth provider can set admin status, do so if needed
            local authority = false
            for k, v in pairs(config.admin_oauth or {}) do
                if r.strcmp_match(oauth_domain, v) then
                    authority = true
                    break
                end
            end
            if authority then
                usr.admin = admin
            end
            
            usr.email = eml
            usr.uid = json.uid
            usr.oauth_used = oauth_domain
            user.update(r, cid, usr)
            r:puts[[{"okay": true, "msg": "Logged in successfully!"}]]
        
        -- didn't get email or name, bork!
        else
            r:puts[[{"okay": false, "msg": "Erroneous or missing response from backend!"}]]
        end
    -- Backend borked, let the user know
    else
        r:puts[[{"okay": false, "msg": "Invalid oauth response!"}]]
    end
    return cross.OK
end

cross.start(handle)