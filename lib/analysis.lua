-- analysis: one background pass per tape (tools/analyze.sh), cached in
-- norns.state.data/cache/<name>-<hash>/ with hash = fnv(path, size, mtime)
--
-- the job runs detached (setsid, nice 10, best-effort io priority 7), so the
-- tape plays while it runs; Analysis.st has its state for the UI. One job at
-- a time: starting another (or cleanup) stops the running one.

local Analysis = {}

Analysis.st = {
  state = 'none', -- none | running | done | failed
  progress = 0,   -- 0..1
  dir = nil,      -- cache dir of the current tape
  info = nil,     -- key=value table from the cache's `info`
  err = nil,
}
local st = Analysis.st

local watcher = nil
local running_dir = nil

local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

local function fnv(s)
  local h = 0x811c9dc5
  for i = 1, #s do h = ((h ~ s:byte(i)) * 0x01000193) & 0xffffffff end
  return string.format('%08x', h)
end

local function read_file(path)
  local f = io.open(path)
  if not f then return nil end
  local s = f:read('a')
  f:close()
  return s
end

local function read_kv(path)
  local s = read_file(path)
  if not s then return nil end
  local t = {}
  for k, v in s:gmatch('([%w_]+)=([^\n]*)') do t[k] = tonumber(v) or v end
  return t
end

function Analysis.cache_dir(path)
  local stat = util.os_capture('stat -L -c "%s %Y" ' .. q(path)) or ''
  local base = path:match('[^/]*$'):gsub('%.%w+$', ''):gsub('[^%w%-_]', '_'):sub(1, 40)
  return norns.state.data .. 'cache/' .. base .. '-' .. fnv(path .. '|' .. stat) .. '/'
end

-- kill the job writing into `dir` (its pid file holds the process group id)
local function kill_job(dir)
  local pid = tonumber(read_file(dir .. 'pid') or '')
  if not pid then return end
  -- only if that pid is still our script (pids get reused)
  local cmd = read_file('/proc/' .. pid .. '/cmdline') or ''
  if cmd:find('analyze.sh', 1, true) then
    os.execute('kill -TERM -- -' .. pid .. ' 2> /dev/null')
  end
  os.remove(dir .. 'pid')
end

function Analysis.stop()
  if watcher then clock.cancel(watcher) end
  watcher = nil
  if running_dir then kill_job(running_dir) end
  running_dir = nil
end

-- analyse `path` (`frames` long, for the progress) unless its cache is
-- complete; on_done(dir, info) runs when the cache is ready
function Analysis.start(path, frames, on_done)
  Analysis.stop()
  local dir = Analysis.cache_dir(path)
  st.dir, st.info, st.err, st.progress = dir, nil, nil, 0
  if util.file_exists(dir .. 'done') then
    st.info = read_kv(dir .. 'info')
    st.state, st.progress = 'done', 1
    on_done(dir, st.info)
    return
  end
  kill_job(dir) -- a job left over from a crash
  local script = norns.state.path .. 'tools/analyze.sh'
  local bin = norns.state.data .. 'bin/aurpeaks'
  os.execute(string.format(
    'setsid nice -n 10 ionice -c 2 -n 7 bash %s %s %s %s > /dev/null 2>&1 < /dev/null &',
    q(script), q(path), q(dir), q(bin)))
  st.state = 'running'
  running_dir = dir
  local t0 = util.time()
  watcher = clock.run(function()
    while true do
      clock.sleep(1)
      if util.file_exists(dir .. 'done') then
        running_dir = nil
        watcher = nil
        st.info = read_kv(dir .. 'info')
        st.state, st.progress = 'done', 1
        print(string.format('aurotate: analysed %s in %.1f s', path, util.time() - t0))
        on_done(dir, st.info)
        return
      end
      local err = read_file(dir .. 'fail')
      if err then
        running_dir = nil
        watcher = nil
        st.state, st.err = 'failed', err:gsub('%s+$', '')
        print('aurotate: analysis failed: ' .. st.err)
        return
      end
      local done = tonumber(read_file(dir .. 'progress') or '')
      if done and frames and frames > 0 then st.progress = math.min(1, done / frames) end
    end
  end)
end

return Analysis
