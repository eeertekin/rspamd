--[[
Copyright (c) 2017, Vsevolod Stakhov <vsevolod@highsecure.ru>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
]]--

if confighelp then
  return
end

-- A generic plugin for reputation handling

local E = {}
local N = 'reputation'

local rspamd_logger = require "rspamd_logger"
local rspamd_util = require "rspamd_util"
local lua_util = require "lua_util"
local lua_maps = require "maps"
local hash = require 'rspamd_cryptobox_hash'
local fun = require "fun"
local redis_params = nil
local default_expiry = 864000 -- 10 day by default

-- Get reputation from ham/spam/probable hits
local function generic_reputation_calc(rule, token, mult)
  local cfg = rule.selector.config

  if cfg.score_calc_func then
    return cfg.score_calc_func(rule, token, mult)
  end

  local ham_samples = token.h or 0
  local spam_samples = token.s or 0
  local probable_samples = token.p or 0
  local total_samples = ham_samples + spam_samples + probable_samples

  if total_samples < cfg.lower_bound then return 0 end

  local score = (ham_samples / total_samples) * -1.0 +
      (spam_samples / total_samples) +
      (probable_samples / total_samples) * 0.5
  return score
end

-- DKIM Selector functions
local gr
local function gen_dkim_queries(task, rule)
  local dkim_trace = task:get_symbol('DKIM_TRACE')
  local lpeg = require 'lpeg'
  local ret = {}

  if not gr then
    local semicolon = lpeg.P(':')
    local domain = lpeg.C((1 - semicolon)^0)
    local res = lpeg.S'+-?~'

    local function res_to_label(ch)
      if ch == '+' then return 'a'
      elseif ch == '-' then return 'r'
        else return 'u'
      end
    end

    gr = domain * semicolon * lpeg.C(res / res_to_label)
  end

  if dkim_trace and dkim_trace.options then
    for _,opt in ipairs(dkim_trace.options) do
      local dom,res = lpeg.match(gr, opt)

      if dom and res then
        ret[dom] = res
      end
    end
  end

  return ret
end

local function dkim_reputation_filter(task, rule)
  local requests = gen_dkim_queries(task, rule)
  local results = {}
  local nchecked = 0
  local rep_accepted = 0.0
  local rep_rejected = 0.0

  local function tokens_cb(err, token, values)
    nchecked = nchecked + 1

    if values then
      results[token] = values
    end

    if nchecked == #requests then
      for k,v in pairs(results) do
        if requests[k] == 'a' then
          rep_accepted = rep_accepted + generic_reputation_calc(v, rule, 1.0)
        elseif requests[k] == 'r' then
          rep_rejected = rep_rejected + generic_reputation_calc(v, rule, 1.0)
        end
      end

      -- Set local reputation symbol
      if rep_accepted > 0 or rep_rejected > 0 then
        if rep_accepted > rep_rejected then
          task:insert_result(rule.symbol, -(rep_accepted - rep_rejected))
        else
          task:insert_result(rule.symbol, (rep_rejected - rep_accepted))
        end

        -- Store results for future DKIM results adjustments
        task:get_mempool():set_variable("dkim_reputation_accept", tostring(rep_accepted))
        task:get_mempool():set_variable("dkim_reputation_reject", tostring(rep_rejected))
      end
    end
  end

  for dom,res in pairs(requests) do
    -- tld + "." + check_result, e.g. example.com.+ - reputation for valid sigs
    local query = string.format('%s.%s', dom, res)
    rule.backend.get_token(task, rule, query, tokens_cb)
  end
end

local function dkim_reputation_idempotent(task, rule)
  local action = task:get_metric_action()
  local token = {
  }
  local cfg = rule.selector.config
  local need_set = false

  -- TODO: take metric score into consideration
  local k = cfg.keys_map[action]

  if k then
    token[k] = 1.0
    need_set = true
  end

  if need_set then

    local requests = gen_dkim_queries(task, rule)

    for dom,res in pairs(requests) do
      -- tld + "." + check_result, e.g. example.com.+ - reputation for valid sigs
      local query = string.format('%s.%s', dom, res)
      rule.backend.set_token(task, rule, query, token)
    end
  end
end

local function dkim_reputation_postfilter(task, rule)
  local sym_accepted = task:get_symbol('R_DKIM_ALLOW')
  local accept_adjustment = task:get_mempool():get_variable("dkim_reputation_accept")

  if sym_accepted and accept_adjustment then
    local final_adjustment = rule.cfg.max_accept_adjustment *
        rspamd_util.tanh(tonumber(accept_adjustment))
    task:adjust_result('R_DKIM_ALLOW', sym_accepted.score * final_adjustment)
  end

  local sym_rejected = task:get_symbol('R_DKIM_REJECT')
  local reject_adjustment = task:get_mempool():get_variable("dkim_reputation_reject")

  if sym_rejected and reject_adjustment then
    local final_adjustment = rule.cfg.max_reject_adjustment *
        rspamd_util.tanh(tonumber(reject_adjustment))
    task:adjust_result('R_DKIM_REJECT', sym_rejected.score * final_adjustment)
  end
end

local dkim_selector = {
  config = {
    -- keys map between actions and hash elements in bucket,
    -- h is for ham,
    -- s is for spam,
    -- p is for probable spam
    keys_map = {
      ['reject'] = 's',
      ['add header'] = 'p',
      ['rewrite subject'] = 'p',
      ['no action'] = 'h'
    },
    symbol = 'DKIM_SCORE', -- symbol to be inserted
    lower_bound = 10, -- minimum number of messages to be scored
    min_score = nil,
    max_score = nil,
    outbound = true,
    inbound = true,
    max_accept_adjustment = 2.0, -- How to adjust accepted DKIM score
    max_reject_adjustment = 3.0 -- How to adjust rejected DKIM score
  },
  dependencies = {"DKIM_TRACE"},
  filter = dkim_reputation_filter, -- used to get scores
  postfilter = dkim_reputation_postfilter, -- used to adjust DKIM scores
  idempotent = dkim_reputation_idempotent -- used to set scores
}

-- URL Selector functions

local function gen_url_queries(task, rule)
  local domains = {}

  fun.each(function(u)
    if u:is_redirected() then
      local redir = u:get_redirected() -- get the original url
      local redir_tld = redir:get_tld()
      if domains[redir_tld] then
        domains[redir_tld] = domains[redir_tld] - 1
      end
    end
    local dom = u:get_tld()
    if not domains[dom] then
      domains[dom] = 1
    else
      domains[dom] = domains[dom] + 1
    end
  end, fun.filter(function(u) return not u:is_html_displayed() end,
    task:get_urls(true)))

  local results = {}
  for k,v in lua_util.spairs(domains,
    function(t, a, b) return t[a] > t[b] end, rule.selector.config.max_urls) do
    if v > 0 then
      table.insert(results, {k,v})
    end
  end

  return results
end

local function url_reputation_filter(task, rule)
  local requests = gen_url_queries(task, rule)
  local results = {}
  local nchecked = 0

  local function tokens_cb(err, token, values)
    nchecked = nchecked + 1

    if values then
      results[token] = values
    end

    if nchecked == #requests then
      -- Check the url with maximum hits
      local mhits = 0
      for k,_ in pairs(results) do
        if requests[k][2] > mhits then
          mhits = requests[k][2]
        end
      end

      if mhits > 0 then
        local score = 0
        for k,v in pairs(results) do
          score = score + generic_reputation_calc(v, rule, requests[k][2] / mhits)
        end

        if math.abs(score) > 1e-3 then
          -- TODO: add description
          task:insert_result(rule.symbol, score)
        end
      end
    end
  end

  for _,tld in ipairs(requests) do
    rule.backend.get_token(task, rule, tld[1], tokens_cb)
  end
end

local function url_reputation_idempotent(task, rule)
  local action = task:get_metric_action()
  local token = {
  }
  local cfg = rule.selector.config
  local need_set = false

  -- TODO: take metric score into consideration
  local k = cfg.keys_map[action]

  if k then
    token[k] = 1.0
    need_set = true
  end

  if need_set then

    local requests = gen_url_queries(task, rule)

    for _,tld in ipairs(requests) do
      rule.backend.set_token(task, rule, tld[1], token)
    end
  end
end

local url_selector = {
  config = {
    -- keys map between actions and hash elements in bucket,
    -- h is for ham,
    -- s is for spam,
    -- p is for probable spam
    keys_map = {
      ['reject'] = 's',
      ['add header'] = 'p',
      ['rewrite subject'] = 'p',
      ['no action'] = 'h'
    },
    symbol = 'URL_SCORE', -- symbol to be inserted
    lower_bound = 10, -- minimum number of messages to be scored
    min_score = nil,
    max_score = nil,
    max_urls = 10,
    check_from = true,
    outbound = true,
    inbound = true,
  },
  dependencies = {"SURBL_CALLBACK"},
  filter = url_reputation_filter, -- used to get scores
  idempotent = url_reputation_idempotent -- used to set scores
}
-- IP Selector functions

local function ip_reputation_init(rule)
  local cfg = rule.selector.config

  if cfg.asn_cc_whitelist then
    cfg.asn_cc_whitelist = rspamd_map_add('reputation',
      'asn_cc_whitelist',
      'map',
      'IP score whitelisted ASNs/countries')
  end
end

local function ip_reputation_filter(task, rule)

  local ip = task:get_from_ip()

  if not ip or not ip:is_valid() then return end
  if lua_util.is_rspamc_or_controller(task) then return end

  local cfg = rule.selector.config

  local pool = task:get_mempool()
  local asn = pool:get_variable("asn")
  local country = pool:get_variable("country")
  local ipnet = pool:get_variable("ipnet")

  if country and cfg.asn_cc_whitelist then
    if cfg.asn_cc_whitelist:get_key(country) then
      return
    end
    if asn and cfg.asn_cc_whitelist:get_key(asn) then
      return
    end
  end

  -- These variables are used to define if we have some specific token
  local has_asn = not asn
  local has_country = not country
  local has_ipnet = not ipnet
  local has_ip = false

  local asn_stats, country_stats, ipnet_stats, ip_stats

  local function ipstats_check()
    local score = 0.0
    local description_t = {}

    if asn_stats then
      local asn_score = generic_reputation_calc(asn_stats, rule, cfg.scores.asn)
      score = score + asn_score
      table.insert(description_t, string.format('asn: %s(%.2f)', asn, asn_score))
    end
    if country_stats then
      local country_score = generic_reputation_calc(country_stats, rule, cfg.scores.country)
      score = score + country_score
      table.insert(description_t, string.format('country: %s(%.2f)', country, country_score))
    end
    if ipnet_stats then
      local ipnet_score = generic_reputation_calc(ipnet_stats, rule, cfg.scores.ipnet)
      score = score + ipnet_score
      table.insert(description_t, string.format('ipnet: %s(%.2f)', ipnet, ipnet_score))
    end
    if ip_stats then
      local ip_score = generic_reputation_calc(ip_stats, rule, cfg.scores.ip)
      score = score + ip_score
      table.insert(description_t, string.format('ip: %s(%.2f)', ip, ip_score))
    end

    if math.abs(score) > 1e-3 then
      task:insert_result(rule.symbol, score, table.concat(description_t, ', '))
    end
  end

  local function gen_token_callback(what)
    return function(err, _, values)
      if not err and values then
        if what == 'asn' then
          has_asn = true
          asn_stats = values
        elseif what == 'country' then
          has_country = true
          country_stats = values
        elseif what == 'ipnet' then
          has_ipnet = true
          ipnet_stats = values
        elseif what == 'ip' then
          has_ip = true
          ip_stats = values
        end
      else
        if what == 'asn' then
          has_asn = true
        elseif what == 'country' then
          has_country = true
        elseif what == 'ipnet' then
          has_ipnet = true
        elseif what == 'ip' then
          has_ip = true
        end
      end

      if has_asn and has_country and has_ipnet and has_ip then
        -- Check reputation
        ipstats_check()
      end
    end
  end

  if asn then
    rule.backend.get_token(task, rule, cfg.asn_prefix .. asn, gen_token_callback('asn'))
  end
  if country then
    rule.backend.get_token(task, rule, cfg.country_prefix .. country, gen_token_callback('country'))
  end
  if ipnet then
    rule.backend.get_token(task, rule, cfg.ipnet_prefix .. ipnet, gen_token_callback('ipnet'))
  end

  rule.backend.get_token(task, rule, cfg.ip_prefix .. tostring(ip), gen_token_callback('ip'))
end

-- Used to set scores
local function ip_reputation_idempotent(task, rule)
  if not rule.backend.set_token then return end -- Read only backend
  local ip = task:get_from_ip()

  if not ip or not ip:is_valid() then return end
  if lua_util.is_rspamc_or_controller(task) then return end

  local cfg = rule.selector.config

  local pool = task:get_mempool()
  local asn = pool:get_variable("asn")
  local country = pool:get_variable("country")
  local ipnet = pool:get_variable("ipnet")

  if country and cfg.asn_cc_whitelist then
    if cfg.asn_cc_whitelist:get_key(country) then
      return
    end
    if asn and cfg.asn_cc_whitelist:get_key(asn) then
      return
    end
  end

  local action = task:get_metric_action()
  local token = {
  }
  local need_set = false

  -- TODO: take metric score into consideration
  local k = cfg.keys_map[action]

  if k then
    token[k] = 1.0
    need_set = true
  end

  if need_set then
    if asn then
      rule.backend.set_token(task, rule, cfg.asn_prefix .. asn, token)
    end
    if country then
      rule.backend.set_token(task, rule, cfg.country_prefix .. country, token)
    end
    if ipnet then
      rule.backend.set_token(task, rule, cfg.ipnet_prefix .. ipnet, token)
    end

    rule.backend.set_token(task, rule, cfg.ip_prefix .. tostring(ip), token)
  end
end

-- Selectors are used to extract reputation tokens
local ip_selector = {
  config = {
    -- keys map between actions and hash elements in bucket,
    -- h is for ham,
    -- s is for spam,
    -- p is for probable spam
    keys_map = {
      ['reject'] = 's',
      ['add header'] = 'p',
      ['rewrite subject'] = 'p',
      ['no action'] = 'h'
    },
    scores = { -- how each component is evaluated
      ['asn'] = 0.4,
      ['country'] = 0.01,
      ['ipnet'] = 0.5,
      ['ip'] = 1.0
    },
    symbol = 'IP_SCORE', -- symbol to be inserted
    asn_prefix = 'a:', -- prefix for ASN hashes
    country_prefix = 'c:', -- prefix for country hashes
    ipnet_prefix = 'n:', -- prefix for ipnet hashes
    ip_prefix = 'i:',
    lower_bound = 10, -- minimum number of messages to be scored
    min_score = nil,
    max_score = nil,
    score_divisor = 1,
    outbound = false,
    inbound = true,
  },
  --dependencies = {"ASN"}, -- ASN is a prefilter now...
  init = ip_reputation_init,
  filter = ip_reputation_filter, -- used to get scores
  idempotent = ip_reputation_idempotent -- used to set scores
}

local selectors = {
  ip = ip_selector,
  url = url_selector,
  dkim = dkim_selector
}

local function reputation_dns_init(rule)
  if not rule.backend.config.list then
    rspamd_logger.errx(rspamd_config, "rule %s with DNS backend has no `list` parameter defined",
      rule.symbol)
    return false
  end

  return true
end


local function gen_token_key(token, rule)
  local res = token
  if rule.backend.config.hashed then
    local hash_alg = rule.backend.config.hash_alg or "blake2"
    local encoding = "base32"

    if rule.backend.config.hash_encoding then
      encoding = rule.backend.config.hash_encoding
    end

    local h = hash.create_specific(hash_alg, res)
    if encoding == 'hex' then
      res = h:hex()
    elseif encoding == 'base64' then
      res = h:base64()
    else
      res = h:base32()
    end
  end

  if rule.backend.config.hashlen then
    res = string.sub(res, 1, rule.backend.config.hashlen)
  end

  return res
end

--[[
-- Generic interface for get and set tokens functions:
-- get_token(task, rule, token, continuation), where `continuation` is the following function:
--
-- function(err, token, values) ... end
-- `err`: string value for error (similar to redis or DNS callbacks)
-- `token`: string value of a token
-- `values`: table of key=number, parsed from backend. It is selector's duty
--  to deal with missing, invalid or other values
--
-- set_token(task, rule, token, values, continuation_cb)
-- This function takes values, encodes them using whatever suitable format
-- and calls for continuation:
--
-- function(err, token) ... end
-- `err`: string value for error (similar to redis or DNS callbacks)
-- `token`: string value of a token
--
-- example of tokens: {'s': 0, 'h': 0, 'p': 1}
--]]

local function reputation_dns_get_token(task, rule, token, continuation_cb)
  local r = task:get_resolver()
  local key = gen_token_key(token, rule)
  local dns_name = key .. '.' .. rule.backend.config.list

  local function dns_callback(_, to_resolve, results, err)
    if err and (err ~= 'requested record is not found' and err ~= 'no records with this name') then
      rspamd_logger.errx(task, 'error looking up %s: %s', to_resolve, err)
    end
    if not results then
      rspamd_logger.debugm(N, task, 'DNS RESPONSE: label=%1 results=%2 error=%3 list=%4',
        to_resolve, false, err, rule.backend.config.list)
    else
      rspamd_logger.debugm(N, task, 'DNS RESPONSE: label=%1 results=%2 error=%3 list=%4',
        to_resolve, true, err, rule.backend.config.list)
    end

    -- Now split tokens to list of values
    if not err and results then
      local values = {}
      -- Format: key1=num1;key2=num2...keyn=numn
      fun.each(function(e)
          local vals = lua_util.rspamd_str_split(e, "=")
          if vals and #vals == 2 then
            local nv = tonumber(vals[2])
            if nv then
              values[vals[1]] = nv
            end
          end
        end,
        lua_util.rspamd_str_split(results[1], ";"))
      continuation_cb(nil, to_resolve, values)
    else
      continuation_cb(err, to_resolve, nil)
    end

    task:inc_dns_req()
  end
  r:resolve_a({
    task = task,
    name = dns_name,
    callback = dns_callback,
    forced = true,
  })
end

local function reputation_redis_get_token(task, rule, token, continuation_cb)
  local key = gen_token_key(token, rule)

  local function redis_get_cb(err, data)
    if data then
      if type(data) == 'table' then
        local values = {}
        for i=1,#data,2 do
          local ndata = tonumber(data[i + 1])
          if ndata then
            values[data[i]] = ndata
          end
        end
        continuation_cb(nil, key, values)
      else
        rspamd_logger.errx(task, 'invalid type while getting reputation keys %s: %s',
          key, type(data))
        continuation_cb("invalid type", key, nil)
      end

    elseif err then
      rspamd_logger.errx(task, 'got error while getting reputation keys %s: %s',
        key, err)
      continuation_cb(err, key, nil)
    else
      continuation_cb("unknown error", key, nil)
    end
  end

  local ret = rspamd_redis_make_request(task,
    redis_params, -- connect params
    key, -- hash key
    false, -- is write
    redis_get_cb, --callback
    'HGETALL', -- command
    {key} -- arguments
  )
  if not ret then
    rspamd_logger.errx(task, 'cannot make redis request to check results')
  end
end

local function reputation_redis_set_token(task, rule, token, values, continuation_cb)
  local key = gen_token_key(token, rule)

  local ret,conn

  local function redis_set_cb(err, data)
    if err then
      rspamd_logger.errx(task, 'got error while setting reputation keys %s: %s',
        key, err)
      if continuation_cb then
        continuation_cb(err, key)
      end
    else
      if continuation_cb then
        continuation_cb(nil, key)
      end
    end
  end

  -- We start from expiry update
  ret,conn = rspamd_redis_make_request(task,
    redis_params, -- connect params
    nil, -- hash key
    true, -- is write
    redis_set_cb, --callback
    'EXPIRE', -- command
    {key, tostring(rule.backend.config.expiry)} -- arguments
  )
  -- Update greylisting record expire
  if ret then
    -- Here, we increment all hash keys that are listed in values
    -- E.g. {'s': 1.0} or {'h': -1.0}, floating point allows better flexibility
    fun.each(function(k, v)
      conn:add_cmd('HINCRBYFLOAT', {key, tostring(k), tostring(v)})
    end, values)
    -- Add last modification time (might be not very consistent between updates)
    conn:add_cmd('HSET', {key, 'last', tostring(rspamd_util:get_calendar_ticks())})
  else
    rspamd_logger.errx(task, 'got error while connecting to redis')
  end
end

--[[ Backends are responsible for getting reputation tokens
  -- Common config options:
  -- `hashed`: if `true` then apply hash function to the key
  -- `hash_alg`: use specific hash type (`blake2` by default)
  -- `hash_len`: strip hash to this amount of bytes (no strip by default)
  -- `hash_encoding`: use specific hash encoding (base32 by default)
--]]
local backends = {
  redis = {
    config = {
      expiry = default_expiry
    },
    get_token = reputation_redis_get_token,
    set_token = reputation_redis_set_token,
  },
  dns = {
    config = {
      -- list = rep.example.com
    },
    get_token = reputation_dns_get_token,
    -- No set token for DNS
    init = reputation_dns_init,
  }
}

local function is_rule_applicable(task, rule)
  local ip = task:get_from_ip()
  if not (rule.selector.config.outbound and rule.selector.config.inbound) then
    if rule.selector.config.outbound then
      if not (task:get_user() or (ip and ip:is_local())) then
        return false
      end
    elseif rule.selector.config.inbound then
      if task:get_user() or (ip and ip:is_local()) then
        return false
      end
    end
  end

  if rule.selector.config.whitelisted_ip_map then
    if rule.config.whitelisted_ip_map:get_key(ip) then
      return false
    end
  end

  return true
end

local function reputation_filter_cb(task, rule)
  if (is_rule_applicable(task, rule)) then
    rule.selector.filter(task, rule, rule.backend)
  end
end

local function reputation_postfilter_cb(task, rule)
  if (is_rule_applicable(task, rule)) then
    rule.selector.postfilter(task, rule, rule.backend)
  end
end

local function reputation_idempotent_cb(task, rule)
  if (is_rule_applicable(task, rule)) then
    rule.selector.idempotent(task, rule, rule.backend)
  end
end

local function deepcopy(orig)
  local orig_type = type(orig)
  local copy
  if orig_type == 'table' then
    copy = {}
    for orig_key, orig_value in next, orig, nil do
      copy[deepcopy(orig_key)] = deepcopy(orig_value)
    end
    setmetatable(copy, deepcopy(getmetatable(orig)))
  else -- number, string, boolean, etc
    copy = orig
  end
  return copy
end
local function override_defaults(def, override)
  for k,v in pairs(override) do
    if k ~= 'selector' and k ~= 'backend' then
      if def[k] then
        if type(v) == 'table' then
          override_defaults(def[k], v)
        else
          def[k] = v
        end
      else
        def[k] = v
      end
    end
  end
end

local function callback_gen(cb, rule)
  return function(task)
    cb(task, rule)
  end
end

local function parse_rule(name, tbl)
  local selector = selectors[tbl.selector['type']]

  if not selector then
    rspamd_logger.errx(rspamd_config, "unknown selector defined for rule %s: %s", name,
      tbl.selector.type)
    return
  end

  local backend = tbl.backend
  if not backend or not backend.type then
    rspamd_logger.errx(rspamd_config, "no backend defined for rule %s", name)
    return
  end

  backend = backends[backend.type]
  if not backend then
    rspamd_logger.errx(rspamd_config, "unknown backend defined for rule %s: %s", name,
      tbl.backend.type)
    return
  end
  -- Allow config override
  local rule = {
    selector = deepcopy(selector),
    backend = deepcopy(backend),
    config = {}
  }

  -- Override default config params
  override_defaults(rule.backend.config, tbl.backend)
  override_defaults(rule.selector.config, tbl.selector)
  -- Generic options
  override_defaults(rule.config, tbl)

  if rule.config.whitelisted_ip then
    rule.config.whitelisted_ip_map = lua_maps.rspamd_map_add_from_ucl(rule.whitelisted_ip,
      'radix',
      'Reputation whiteliist for ' .. name)
  end

  local symbol = name
  if tbl.symbol then
    symbol = name
  end

  rule.symbol = symbol

  -- Perform additional initialization if needed
  if rule.selector.init then
    if not rule.selector.init(rule) then
      return
    end
  end
  if rule.backend.init then
    if not rule.backend.init(rule) then
      return
    end
  end

  -- We now generate symbol for checking
  local id = rspamd_config:register_symbol{
    name = symbol,
    type = 'normal',
    callback = callback_gen(reputation_filter_cb, rule),
  }

  if rule.selector.dependencies then
    fun.each(function(d)
      rspamd_config:register_dependency(id, d)
    end, rule.selector.dependencies)
  end

  if rule.selector.postfilter then
    -- Also register a postfilter
    rspamd_config:register_symbol{
      name = symbol .. '_POST',
      type = 'postfilter,nostat',
      callback = callback_gen(reputation_postfilter_cb, rule),
    }
  end

  if rule.selector.idempotent then
    -- Has also idempotent component (e.g. saving data to the backend)
    rspamd_config:register_symbol{
      name = symbol .. '_IDEMPOTENT',
      type = 'idempotent',
      callback = callback_gen(reputation_idempotent_cb, rule),
    }
  end

end

redis_params = rspamd_parse_redis_server('reputation')
local opts = rspamd_config:get_all_opt("reputation")

-- Initialization part
if not (opts and type(opts) == 'table') then
  rspamd_logger.infox(rspamd_config, 'Module is unconfigured')
  return
end

if opts['rules'] then
  for k,v in pairs(opts['rules']) do
    if not ((v or E).selector or E).type then
      rspamd_logger.errx(rspamd_config, "no selector defined for rule %s", k)
    else
      parse_rule(k, v)
    end
  end
else
  lua_util.disable_module(N, "config")
end
