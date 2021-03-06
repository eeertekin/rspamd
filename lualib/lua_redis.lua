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

local logger = require "rspamd_logger"
local lutil = require "lua_util"
local rspamd_util = require "rspamd_util"

local exports = {}

local E = {}

-- This function parses redis server definition using either
-- specific server string for this module or global
-- redis section
local function rspamd_parse_redis_server(module_name, module_opts, no_fallback)

  local result = {}
  local default_port = 6379
  local default_timeout = 1.0
  local default_expand_keys = false
  local upstream_list = require "rspamd_upstream_list"

  local function try_load_redis_servers(options)
    -- Try to get read servers:
    local upstreams_read, upstreams_write

    if options['read_servers'] then
      upstreams_read = upstream_list.create(rspamd_config,
        options['read_servers'], default_port)
    elseif options['servers'] then
      upstreams_read = upstream_list.create(rspamd_config,
        options['servers'], default_port)
    elseif options['server'] then
      upstreams_read = upstream_list.create(rspamd_config,
        options['server'], default_port)
    end

    if upstreams_read then
      if options['write_servers'] then
        upstreams_write = upstream_list.create(rspamd_config,
          options['write_servers'], default_port)
      else
        upstreams_write = upstreams_read
      end
    end

    -- Store options
    if not result['timeout'] or result['timeout'] == default_timeout then
      if options['timeout'] then
        result['timeout'] = tonumber(options['timeout'])
      else
        result['timeout'] = default_timeout
      end
    end

    if options['prefix'] and not result['prefix'] then
      result['prefix'] = options['prefix']
    end

    if type(options['expand_keys']) == 'boolean' then
      result['expand_keys'] = options['expand_keys']
    else
      result['expand_keys'] = default_expand_keys
    end

    if not result['db'] then
      if options['db'] then
        result['db'] = tostring(options['db'])
      elseif options['dbname'] then
        result['db'] = tostring(options['dbname'])
      end
    end
    if options['password'] and not result['password'] then
      result['password'] = options['password']
    end

    if upstreams_write and upstreams_read then
      result.read_servers = upstreams_read
      result.write_servers = upstreams_write

      return true
    end

    return false
  end

  -- Try local options
  local opts
  if not module_opts then
    opts = rspamd_config:get_all_opt(module_name)
  else
    opts = module_opts
  end

  if opts then
    local ret

    if opts.redis then
      ret = try_load_redis_servers(opts.redis, result)

      if ret then
        return result
      end
    end

    ret = try_load_redis_servers(opts, result)

    if ret then
      return result
    end
  end

  if no_fallback then return nil end

  -- Try global options
  opts = rspamd_config:get_all_opt('redis')

  if opts then
    local ret

    if opts[module_name] then
      ret = try_load_redis_servers(opts[module_name], result)
      if ret then
        return result
      end
    else
      ret = try_load_redis_servers(opts, result)

      -- Exclude disabled
      if opts['disabled_modules'] then
        for _,v in ipairs(opts['disabled_modules']) do
          if v == module_name then
            logger.infox(rspamd_config, "NOT using default redis server for module %s: it is disabled",
              module_name)

              return nil
          end
        end
      end

      if ret then
        logger.infox(rspamd_config, "using default redis server for module %s",
          module_name)
      end
    end
  end

  if result.read_servers then
    return result
  else
    return nil
  end
end

exports.rspamd_parse_redis_server = rspamd_parse_redis_server
exports.parse_redis_server = rspamd_parse_redis_server

local process_cmd = {
  bitop = function(args)
    local idx_l = {}
    for i = 2, #args do
      table.insert(idx_l, i)
    end
    return idx_l
  end,
  blpop = function(args)
    local idx_l = {}
    for i = 1, #args -1 do
      table.insert(idx_l, i)
    end
    return idx_l
  end,
  eval = function(args)
    local idx_l = {}
    local numkeys = args[2]
    if numkeys >= 1 then
      for i = 3, numkeys + 2 do
        table.insert(idx_l, i)
      end
    end
    return idx_l
  end,
  set = function(args)
    return {1}
  end,
  mget = function(args)
    local idx_l = {}
    for i = 1, #args do
      table.insert(idx_l, i)
    end
    return idx_l
  end,
  mset = function(args)
    local idx_l = {}
    for i = 1, #args, 2 do
      table.insert(idx_l, i)
    end
    return idx_l
  end,
  sdiffstore = function(args)
    local idx_l = {}
    for i = 2, #args do
      table.insert(idx_l, i)
    end
    return idx_l
  end,
  smove = function(args)
    return {1, 2}
  end,
  script = function() end
}
process_cmd.append = process_cmd.set
process_cmd.auth = process_cmd.script
process_cmd.bgrewriteaof = process_cmd.script
process_cmd.bgsave = process_cmd.script
process_cmd.bitcount = process_cmd.set
process_cmd.bitfield = process_cmd.set
process_cmd.bitpos = process_cmd.set
process_cmd.brpop = process_cmd.blpop
process_cmd.brpoplpush = process_cmd.blpop
process_cmd.client = process_cmd.script
process_cmd.cluster = process_cmd.script
process_cmd.command = process_cmd.script
process_cmd.config = process_cmd.script
process_cmd.dbsize = process_cmd.script
process_cmd.debug = process_cmd.script
process_cmd.decr = process_cmd.set
process_cmd.decrby = process_cmd.set
process_cmd.del = process_cmd.mget
process_cmd.discard = process_cmd.script
process_cmd.dump = process_cmd.set
process_cmd.echo = process_cmd.script
process_cmd.evalsha = process_cmd.eval
process_cmd.exec = process_cmd.script
process_cmd.exists = process_cmd.mget
process_cmd.expire = process_cmd.set
process_cmd.expireat = process_cmd.set
process_cmd.flushall = process_cmd.script
process_cmd.flushdb = process_cmd.script
process_cmd.geoadd = process_cmd.set
process_cmd.geohash = process_cmd.set
process_cmd.geopos = process_cmd.set
process_cmd.geodist = process_cmd.set
process_cmd.georadius = process_cmd.set
process_cmd.georadiusbymember = process_cmd.set
process_cmd.get = process_cmd.set
process_cmd.getbit = process_cmd.set
process_cmd.getrange = process_cmd.set
process_cmd.getset = process_cmd.set
process_cmd.hdel = process_cmd.set
process_cmd.hexists = process_cmd.set
process_cmd.hget = process_cmd.set
process_cmd.hgetall = process_cmd.set
process_cmd.hincrby = process_cmd.set
process_cmd.hincrbyfloat = process_cmd.set
process_cmd.hkeys = process_cmd.set
process_cmd.hlen = process_cmd.set
process_cmd.hmget = process_cmd.set
process_cmd.hscan = process_cmd.set
process_cmd.hset = process_cmd.set
process_cmd.hsetnx = process_cmd.set
process_cmd.hstrlen = process_cmd.set
process_cmd.hvals = process_cmd.set
process_cmd.incr = process_cmd.set
process_cmd.incrby = process_cmd.set
process_cmd.incrbyfloat = process_cmd.set
process_cmd.info = process_cmd.script
process_cmd.keys = process_cmd.script
process_cmd.lastsave = process_cmd.script
process_cmd.lindex = process_cmd.set
process_cmd.linsert = process_cmd.set
process_cmd.llen = process_cmd.set
process_cmd.lpop = process_cmd.set
process_cmd.lpush = process_cmd.set
process_cmd.lpushx = process_cmd.set
process_cmd.lrange = process_cmd.set
process_cmd.lrem = process_cmd.set
process_cmd.lset = process_cmd.set
process_cmd.ltrim = process_cmd.set
process_cmd.migrate = process_cmd.script
process_cmd.monitor = process_cmd.script
process_cmd.move = process_cmd.set
process_cmd.msetnx = process_cmd.mset
process_cmd.multi = process_cmd.script
process_cmd.object = process_cmd.script
process_cmd.persist = process_cmd.set
process_cmd.pexpire = process_cmd.set
process_cmd.pexpireat = process_cmd.set
process_cmd.pfadd = process_cmd.set
process_cmd.pfcount = process_cmd.set
process_cmd.pfmerge = process_cmd.mget
process_cmd.ping = process_cmd.script
process_cmd.psetex = process_cmd.set
process_cmd.psubscribe = process_cmd.script
process_cmd.pubsub = process_cmd.script
process_cmd.pttl = process_cmd.set
process_cmd.publish = process_cmd.script
process_cmd.punsubscribe = process_cmd.script
process_cmd.quit = process_cmd.script
process_cmd.randomkey = process_cmd.script
process_cmd.readonly = process_cmd.script
process_cmd.readwrite = process_cmd.script
process_cmd.rename = process_cmd.mget
process_cmd.renamenx = process_cmd.mget
process_cmd.restore = process_cmd.set
process_cmd.role = process_cmd.script
process_cmd.rpop = process_cmd.set
process_cmd.rpoplpush = process_cmd.mget
process_cmd.rpush = process_cmd.set
process_cmd.rpushx = process_cmd.set
process_cmd.sadd = process_cmd.set
process_cmd.save = process_cmd.script
process_cmd.scard = process_cmd.set
process_cmd.sdiff = process_cmd.mget
process_cmd.select = process_cmd.script
process_cmd.setbit = process_cmd.set
process_cmd.setex = process_cmd.set
process_cmd.setnx = process_cmd.set
process_cmd.sinterstore = process_cmd.sdiff
process_cmd.sismember = process_cmd.set
process_cmd.slaveof = process_cmd.script
process_cmd.slowlog = process_cmd.script
process_cmd.smembers = process_cmd.script
process_cmd.sort = process_cmd.set
process_cmd.spop = process_cmd.set
process_cmd.srandmember = process_cmd.set
process_cmd.srem = process_cmd.set
process_cmd.strlen = process_cmd.set
process_cmd.subscribe = process_cmd.script
process_cmd.sunion = process_cmd.mget
process_cmd.sunionstore = process_cmd.mget
process_cmd.swapdb = process_cmd.script
process_cmd.sync = process_cmd.script
process_cmd.time = process_cmd.script
process_cmd.touch = process_cmd.mget
process_cmd.ttl = process_cmd.set
process_cmd.type = process_cmd.set
process_cmd.unsubscribe = process_cmd.script
process_cmd.unlink = process_cmd.mget
process_cmd.unwatch = process_cmd.script
process_cmd.wait = process_cmd.script
process_cmd.watch = process_cmd.mget
process_cmd.zadd = process_cmd.set
process_cmd.zcard = process_cmd.set
process_cmd.zcount = process_cmd.set
process_cmd.zincrby = process_cmd.set
process_cmd.zinterstore = process_cmd.eval
process_cmd.zlexcount = process_cmd.set
process_cmd.zrange = process_cmd.set
process_cmd.zrangebylex = process_cmd.set
process_cmd.zrank = process_cmd.set
process_cmd.zrem = process_cmd.set
process_cmd.zrembylex = process_cmd.set
process_cmd.zrembyrank = process_cmd.set
process_cmd.zrembyscore = process_cmd.set
process_cmd.zrevrange = process_cmd.set
process_cmd.zrevrangebyscore = process_cmd.set
process_cmd.zrevrank = process_cmd.set
process_cmd.zscore = process_cmd.set
process_cmd.zunionstore = process_cmd.eval
process_cmd.scan = process_cmd.script
process_cmd.sscan = process_cmd.set
process_cmd.hscan = process_cmd.set
process_cmd.zscan = process_cmd.set

local function get_key_indexes(cmd, args)
  local idx_l = {}
  cmd = string.lower(cmd)
  if process_cmd[cmd] then
    idx_l = process_cmd[cmd](args)
  else
    logger.warnx(rspamd_config, "Don't know how to extract keys for %s Redis command", cmd)
  end
  return idx_l
end

local gen_meta = {
  principal_recipient = function(task)
    return task:get_principal_recipient()
  end,
  principal_recipient_domain = function(task)
    local p = task:get_principal_recipient()
    if not p then return end
    return string.match(p, '.*@(.*)')
  end,
  ip = function(task)
    local i = task:get_ip()
    if i and i:is_valid() then return i:to_string() end
  end,
  from = function(task)
    return ((task:get_from('smtp') or E)[1] or E)['addr']
  end,
  from_domain = function(task)
    return ((task:get_from('smtp') or E)[1] or E)['domain']
  end,
  from_domain_or_helo_domain = function(task)
    local d = ((task:get_from('smtp') or E)[1] or E)['domain']
    if d and #d > 0 then return d end
    return task:get_helo()
  end,
  mime_from = function(task)
    return ((task:get_from('mime') or E)[1] or E)['addr']
  end,
  mime_from_domain = function(task)
    return ((task:get_from('mime') or E)[1] or E)['domain']
  end,
}

local function gen_get_esld(f)
  return function(task)
    local d = f(task)
    if not d then return end
    return rspamd_util.get_tld(d)
  end
end

gen_meta.smtp_from = gen_meta.from
gen_meta.smtp_from_domain = gen_meta.from_domain
gen_meta.smtp_from_domain_or_helo_domain = gen_meta.from_domain_or_helo_domain
gen_meta.esld_principal_recipient_domain = gen_get_esld(gen_meta.principal_recipient_domain)
gen_meta.esld_from_domain = gen_get_esld(gen_meta.from_domain)
gen_meta.esld_smtp_from_domain = gen_meta.esld_from_domain
gen_meta.esld_mime_from_domain = gen_get_esld(gen_meta.mime_from_domain)
gen_meta.esld_from_domain_or_helo_domain = gen_get_esld(gen_meta.from_domain_or_helo_domain)
gen_meta.esld_smtp_from_domain_or_helo_domain = gen_meta.esld_from_domain_or_helo_domain

local function get_key_expansion_metadata(task)

  local md_mt = {
    __index = function(self, k)
      k = string.lower(k)
      local v = rawget(self, k)
      if v then
        return v
      end
      if gen_meta[k] then
        v = gen_meta[k](task)
        rawset(self, k, v)
      end
      return v
    end,
  }

  local lazy_meta = {}
  setmetatable(lazy_meta, md_mt)
  return lazy_meta

end

-- Performs async call to redis hiding all complexity inside function
-- task - rspamd_task
-- redis_params - valid params returned by rspamd_parse_redis_server
-- key - key to select upstream or nil to select round-robin/master-slave
-- is_write - true if need to write to redis server
-- callback - function to be called upon request is completed
-- command - redis command
-- args - table of arguments
local function rspamd_redis_make_request(task, redis_params, key, is_write, callback, command, args)
  local addr
  local function rspamd_redis_make_request_cb(err, data)
    if err then
      addr:fail()
    else
      addr:ok()
    end
    callback(err, data, addr)
  end
  if not task or not redis_params or not callback or not command then
    return false,nil,nil
  end

  local rspamd_redis = require "rspamd_redis"

  if key then
    if is_write then
      addr = redis_params['write_servers']:get_upstream_by_hash(key)
    else
      addr = redis_params['read_servers']:get_upstream_by_hash(key)
    end
  else
    if is_write then
      addr = redis_params['write_servers']:get_upstream_master_slave(key)
    else
      addr = redis_params['read_servers']:get_upstream_round_robin(key)
    end
  end

  if not addr then
    logger.errx(task, 'cannot select server to make redis request')
  end

  if redis_params['expand_keys'] then
    local m = get_key_expansion_metadata(task)
    local indexes = get_key_indexes(command, args)
    for _, i in ipairs(indexes) do
      args[i] = lutil.template(args[i], m)
    end
  end

  local ip_addr = addr:get_addr()
  local options = {
    task = task,
    callback = rspamd_redis_make_request_cb,
    host = ip_addr,
    timeout = redis_params['timeout'],
    cmd = command,
    args = args
  }

  if redis_params['password'] then
    options['password'] = redis_params['password']
  end

  if redis_params['db'] then
    options['dbname'] = redis_params['db']
  end

  local ret,conn = rspamd_redis.make_request(options)

  if not ret then
    addr:fail()
    logger.warnx(task, "cannot make redis request to: %s", tostring(ip_addr))
  end

  return ret,conn,addr
end

exports.rspamd_redis_make_request = rspamd_redis_make_request
exports.redis_make_request = rspamd_redis_make_request

local function redis_make_request_taskless(ev_base, cfg, redis_params, key, is_write, callback, command, args)
  if not ev_base or not redis_params or not callback or not command then
    return false,nil,nil
  end

  local addr
  local function rspamd_redis_make_request_cb(err, data)
    if err then
      addr:fail()
    else
      addr:ok()
    end
    callback(err, data, addr)
  end

  local rspamd_redis = require "rspamd_redis"

  if key then
    if is_write then
      addr = redis_params['write_servers']:get_upstream_by_hash(key)
    else
      addr = redis_params['read_servers']:get_upstream_by_hash(key)
    end
  else
    if is_write then
      addr = redis_params['write_servers']:get_upstream_master_slave(key)
    else
      addr = redis_params['read_servers']:get_upstream_round_robin(key)
    end
  end

  if not addr then
    logger.errx(cfg, 'cannot select server to make redis request')
  end

  local options = {
    ev_base = ev_base,
    config = cfg,
    callback = rspamd_redis_make_request_cb,
    host = addr:get_addr(),
    timeout = redis_params['timeout'],
    cmd = command,
    args = args
  }

  if redis_params['password'] then
    options['password'] = redis_params['password']
  end

  if redis_params['db'] then
    options['dbname'] = redis_params['db']
  end

  local ret,conn = rspamd_redis.make_request(options)
  if not ret then
    logger.errx('cannot execute redis request')
    addr:fail()
  end

  return ret,conn,addr
end

exports.rspamd_redis_make_request_taskless = redis_make_request_taskless
exports.redis_make_request_taskless = redis_make_request_taskless

local redis_scripts = {
}

local function script_set_loaded(script)
  if script.sha then
    script.loaded = true
  end

  local wait_table = {}
  for _,s in ipairs(script.waitq) do
    table.insert(wait_table, s)
  end

  script.waitq = {}

  for _,s in ipairs(wait_table) do
    s(script.loaded)
  end
end

local function prepare_redis_call(script)
  local function merge_tables(t1, t2)
    for k,v in pairs(t2) do t1[k] = v end
  end

  local servers = {}
  local options = {}

  if script.redis_params.read_servers then
    merge_tables(servers, script.redis_params.read_servers:all_upstreams())
  end
  if script.redis_params.write_servers then
    merge_tables(servers, script.redis_params.write_servers:all_upstreams())
  end

  -- Call load script on each server, set loaded flag
  script.in_flight = #servers
  for _,s in ipairs(servers) do
    local cur_opts = {
      host = s:get_addr(),
      timeout = script.redis_params['timeout'],
      cmd = 'SCRIPT',
      args = {'LOAD', script.script },
      upstream = s
    }

    if script.redis_params['password'] then
      cur_opts['password'] = script.redis_params['password']
    end

    if script.redis_params['db'] then
      cur_opts['dbname'] = script.redis_params['db']
    end

    table.insert(options, cur_opts)
  end

  return options
end

local function load_script_task(script, task)
  local rspamd_redis = require "rspamd_redis"
  local opts = prepare_redis_call(script)

  for _,opt in ipairs(opts) do
    opt.task = task
    opt.callback = function(err, data)
      if err then
        opt.upstream:fail()
      else
        opt.upstream:ok()
        logger.infox(task,
          "loaded redis script with id %s, sha: %s", script.id, data)
        script.sha = data -- We assume that sha is the same on all servers
      end
      script.in_flight = script.in_flight - 1

      if script.in_flight == 0 then
        script_set_loaded(script)
      end
    end

    local ret = rspamd_redis.make_request(opt)

    if not ret then
      logger.errx('cannot execute redis request to load script')
      script.in_flight = script.in_flight - 1
      opt.upstream:fail()
    end

    if script.in_flight == 0 then
      script_set_loaded(script)
    end
  end
end

local function load_script_taskless(script, cfg, ev_base)
  local rspamd_redis = require "rspamd_redis"
  local opts = prepare_redis_call(script)

  for _,opt in ipairs(opts) do
    opt.config = cfg
    opt.ev_base = ev_base
    opt.callback = function(err, data)
      if err then
        opt.upstream:fail()
      else
        opt.upstream:ok()
        logger.infox(cfg,
          "loaded redis script with id %s, sha: %s", script.id, data)
        script.sha = data -- We assume that sha is the same on all servers
      end
      script.in_flight = script.in_flight - 1

      if script.in_flight == 0 then
        script_set_loaded(script)
      end
    end
    local ret = rspamd_redis.make_request(opt)

    if not ret then
      logger.errx('cannot execute redis request to load script')
      script.in_flight = script.in_flight - 1
      opt.upstream:fail()
    end

    if script.in_flight == 0 then
      script_set_loaded(script)
    end
  end
end

local function load_redis_script(script, cfg, ev_base, _)
  load_script_taskless(script, cfg, ev_base)
end

local function add_redis_script(script, redis_params)
  local new_script = {
    loaded = false,
    redis_params = redis_params,
    script = script,
    waitq = {}, -- callbacks pending for script being loaded
    id = #redis_scripts + 1
  }

  -- Register on load function
  rspamd_config:add_on_load(function(cfg, ev_base, worker)
    load_redis_script(new_script, cfg, ev_base, worker)
  end)

  table.insert(redis_scripts, new_script)

  return #redis_scripts
end
exports.add_redis_script = add_redis_script

local function exec_redis_script(id, params, callback, args)
  local args_modified = false

  if not redis_scripts[id] then
      logger.errx("cannot find registered script with id %s", id)
    return false
  end

  local script = redis_scripts[id]

  local function do_call(can_reload)
    local function redis_cb(err, data)
      if not err then
        callback(err, data)
      elseif string.match(err, 'NOSCRIPT') then
        -- Schedule restart
        script.sha = nil
        if can_reload then
          table.insert(script.waitq, do_call)
          if script.in_flight == 0 then
            -- Reload scripts if this has not been initiated yet
            if params.task then
              load_script_task(script, params.task)
            else
              load_script_taskless(script, rspamd_config, params.ev_base)
            end
          end
        else
          callback(err, data)
        end
      else
        callback(err, data)
      end
    end

    if not args_modified then
      table.insert(args, 1, tostring(#args))
      table.insert(args, 1, script.sha)
      args_modified = true
    end

    if params.task then
      if not rspamd_redis_make_request(params.task, script.redis_params,
        params.key, params.is_write, redis_cb, 'EVALSHA', args) then
        callback('Cannot make redis request', nil)
      end
    else
      if not redis_make_request_taskless(params.ev_base, rspamd_config,
        script.redis_params,
        params.key, params.is_write, redis_cb, 'EVALSHA', args) then
        callback('Cannot make redis request', nil)
      end
    end
  end

  if script.loaded then
    do_call(true)
  else
    -- Delayed until scripts are loaded
    if not params.task then
      table.insert(script.waitq, do_call)
    else
      -- TODO: fix taskfull requests
      callback('NOSCRIPT', nil)
    end
  end

  return true
end

exports.exec_redis_script = exec_redis_script

return exports
