-- test suite for ljsyscall.

local strict = require "test.strict"

local S = require "syscall"
local helpers = require "syscall.helpers"
local types = require "syscall.types"
local c = require "syscall.constants"
local abi = require "syscall.abi"
local features = require "syscall.features"

local bit = require "bit"
local ffi = require "ffi"

local os = abi.os

if os == "osx" then os = "bsd" end -- use same tests for now

require("test." .. os) -- OS specific tests

local t, pt, s = types.t, types.pt, types.s

local oldassert = assert
local function assert(cond, s)
  collectgarbage("collect") -- force gc, to test for bugs
  return oldassert(cond, tostring(s)) -- annoyingly, assert does not call tostring!
end

local function fork_assert(cond, str) -- if we have forked we need to fail in main thread not fork
  if not cond then
    print(tostring(str))
    print(debug.traceback())
    S.exit("failure")
  end
  return cond, str
end

local function assert_equal(...)
  collectgarbage("collect") -- force gc, to test for bugs
  return assert_equals(...)
end

USE_EXPECTED_ACTUAL_IN_ASSERT_EQUALS = true -- strict wants this to be set
local luaunit = require "test.luaunit"

local sysfile = debug.getinfo(S.open).source
local cov = {active = {}, cov = {}}

-- TODO no longer working as more files now
local function coverage(event, line)
  local ss = debug.getinfo(2, "nLlS")
  if ss.source ~= sysfile then return end
  if event == "line" then
    cov.cov[line] = true
  elseif event == "call" then
    if ss.activelines then for k, _ in pairs(ss.activelines) do cov.active[k] = true end end
  end
end

if arg[1] == "coverage" then debug.sethook(coverage, "lc") end

local teststring = "this is a test string"
local size = 512
local buf = t.buffer(size)
local tmpfile = "XXXXYYYYZZZ4521" .. S.getpid()
local tmpfile2 = "./666666DDDDDFFFF" .. S.getpid()
local tmpfile3 = "MMMMMTTTTGGG" .. S.getpid()
local longfile = "1234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890" .. S.getpid()
local efile = "./tmpexXXYYY" .. S.getpid() .. ".sh"
local largeval = math.pow(2, 33) -- larger than 2^32 for testing
local mqname = "ljsyscallXXYYZZ" .. S.getpid()

local clean = function()
  S.rmdir(tmpfile)
  S.unlink(tmpfile)
  S.unlink(tmpfile2)
  S.unlink(tmpfile3)
  S.unlink(longfile)
  S.unlink(efile)
end

test_basic = {
  test_b64 = function()
    local h, l = t.i6432(-1):to32()
    assert_equal(h, bit.tobit(0xffffffff))
    assert_equal(l, bit.tobit(0xffffffff))
    local h, l = t.i6432(0xfffbffff):to32()
    assert_equal(h, bit.tobit(0x0))
    assert_equal(l, bit.tobit(0xfffbffff))
  end,
  test_major_minor = function()
    local d = t.device(2, 3)
    assert_equal(d:major(), 2)
    assert_equal(d:minor(), 3)
  end,
  test_fd_nums = function() -- TODO should also test on the version from types.lua
    assert_equal(t.fd(18):nogc():getfd(), 18, "should be able to trivially create fd")
  end,
  test_error_string = function()
    local err = t.error(c.E.NOENT)
    assert(tostring(err) == "No such file or directory", "should get correct string error message")
  end,
  test_missing_error_string = function()
    local err = t.error(0)
    assert(tostring(err) == "No error information (error 0)", "should get missing error message")
  end,
  test_no_missing_error_strings = function()
    local noerr = "No error information"
    local allok = true
    for k, v in pairs(c.E) do
      local msg = t.error(v)
      if not msg or tostring(msg):sub(1, #noerr) == noerr then
        print("no error message for " .. k)
        allok = false
      end
    end
    assert(allok, "missing error message")
  end,
  test_booltoc = function()
    assert_equal(helpers.booltoc(true), 1)
    assert_equal(helpers.booltoc[true], 1)
    assert_equal(helpers.booltoc[0], 0)
  end,
  test_constants = function()
    assert_equal(c.O.CREAT, c.O.creat) -- test can use upper and lower case
    assert_equal(c.O.CREAT, c.O.Creat) -- test can use mixed case
    assert(rawget(c.O, "CREAT"))
    assert(not rawget(c.O, "creat"))
    assert(rawget(getmetatable(c.O).__index, "creat")) -- a little implementation dependent
  end,
  test_at_flags = function()
    if not c.AT_FDCWD then return end -- OSX does no support any *at functions
    assert_equal(c.AT_FDCWD[nil], c.AT_FDCWD.FDCWD) -- nil returns current dir
    assert_equal(c.AT_FDCWD.fdcwd, c.AT_FDCWD.FDCWD)
    local fd = t.fd(-1)
    assert_equal(c.AT_FDCWD[fd], -1)
    assert_equal(c.AT_FDCWD[33], 33)
  end,
}

test_open_close = {
  teardown = clean,
  test_open_nofile = function()
    local fd, err = S.open("/tmp/file/does/not/exist", "rdonly")
    assert(err, "expected open to fail on file not found")
    assert(err.NOENT, "expect NOENT from open non existent file")
  end,
  test_close_invalid_fd = function()
    local ok, err = S.close(127)
    assert(err, "expected to fail on close invalid fd")
    assert_equal(err.errno, c.E.BADF, "expect BADF from invalid numberic fd")
  end,
  test_open_valid = function()
    local fd = assert(S.open("/dev/null", "rdonly"))
    assert(fd:getfd() >= 3, "should get file descriptor of at least 3 back from first open")
    local fd2 = assert(S.open("/dev/zero", "RDONLY"))
    assert(fd2:getfd() >= 4, "should get file descriptor of at least 4 back from second open")
    assert(fd:close())
    assert(fd2:close())
  end,
  test_fd_cleared_on_close = function()
    local fd = assert(S.open("/dev/null", "rdonly"))
    assert(fd:close())
    local fd2 = assert(S.open("/dev/zero")) -- reuses same fd
    local ok, err = assert(fd:close()) -- this should not close fd again, but no error as does nothing
    assert(fd2:close()) -- this should succeed
  end,
  test_double_close = function()
    local fd = assert(S.open("/dev/null", "rdonly"))
    local fileno = fd:getfd()
    assert(fd:close())
    local fd, err = S.close(fileno)
    assert(err, "expected to fail on close already closed fd")
    assert(err.badf, "expect BADF from invalid numberic fd")
  end,
  test_access = function()
    assert(S.access("/dev/null", "r"), "expect access to say can read /dev/null")
    assert(S.access("/dev/null", c.OK.R), "expect access to say can read /dev/null")
    assert(S.access("/dev/null", "w"), "expect access to say can write /dev/null")
    assert(not S.access("/dev/null", "x"), "expect access to say cannot execute /dev/null")
  end,
  test_fd_gc = function()
    local fd = assert(S.open("/dev/null", "rdonly"))
    local fileno = fd:getfd()
    fd = nil
    collectgarbage("collect")
    local _, err = S.read(fileno, buf, size)
    assert(err, "should not be able to read from fd after gc")
    assert(err.BADF, "expect BADF from already closed fd")
  end,
  test_fd_nogc = function()
    local fd = assert(S.open("/dev/zero", "RDONLY"))
    local fileno = fd:getfd()
    fd:nogc()
    fd = nil
    collectgarbage("collect")
    local n = assert(S.read(fileno, buf, size))
    assert(S.close(fileno))
  end
}

test_read_write = {
  teardown = clean,
  test_read = function()
    local fd = assert(S.open("/dev/zero"))
    for i = 0, size - 1 do buf[i] = 255 end
    local n = assert(fd:read(buf, size))
    assert(n >= 0, "should not get error reading from /dev/zero")
    assert_equal(n, size, "should not get truncated read from /dev/zero")
    for i = 0, size - 1 do assert(buf[i] == 0, "should read zeroes from /dev/zero") end
    assert(fd:close())
  end,
  test_read_to_string = function()
    local fd = assert(S.open("/dev/zero"))
    local str = assert(fd:read(nil, 10))
    assert_equal(#str, 10, "string returned from read should be length 10")
    assert(fd:close())
  end,
  test_write_ro = function()
    local fd = assert(S.open("/dev/zero"))
    local n, err = fd:write(buf, size)
    assert(err, "should not be able to write to file opened read only")
    assert(err.BADF, "expect BADF when writing read only file")
    assert(fd:close())
  end,
  test_write = function()
    local fd = assert(S.open("/dev/zero", "RDWR"))
    local n = assert(fd:write(buf, size))
    assert(n >= 0, "should not get error writing to /dev/zero")
    assert_equal(n, size, "should not get truncated write to /dev/zero")
    assert(fd:close())
  end,
  test_write_string = function()
    local fd = assert(S.open("/dev/zero", "RDWR"))
    local n = assert(fd:write(teststring))
    assert_equal(n, #teststring, "write on a string should write out its length")
    assert(fd:close())
  end,
  test_pread_pwrite = function()
    local fd = assert(S.open("/dev/zero", "RDWR"))
    local offset = 1
    local n
    n = assert(fd:pread(buf, size, offset))
    assert_equal(n, size, "should not get truncated pread on /dev/zero")
    n = assert(fd:pwrite(buf, size, offset))
    assert_equal(n, size, "should not get truncated pwrite on /dev/zero")
    assert(fd:close())
  end,
  test_readv_writev = function()
    local fd = assert(S.open(tmpfile, "rdwr,creat", "rwxu"))
    local n = assert(fd:writev{"test", "ing", "writev"})
    assert_equal(n, 13, "expect length 13")
    assert(fd:seek())
    local b1, b2, b3 = t.buffer(6), t.buffer(4), t.buffer(3)
    local n = assert(fd:readv{b1, b2, b3})
    assert_equal(n, 13, "expect length 13")
    assert_equal(ffi.string(b1, 6), "testin")
    assert_equal(ffi.string(b2, 4), "gwri")
    assert_equal(ffi.string(b3, 3), "tev")
    assert(S.unlink(tmpfile))
  end,
  test_preadv_pwritev = function()
    if not features.preadv() then return true end
    local offset = 0
    local fd = assert(S.open(tmpfile, "rdwr,creat", "rwxu"))
    local n = assert(fd:pwritev({"test", "ing", "writev"}, offset))
    assert_equal(n, 13, "expect length 13")
    local b1, b2, b3 = t.buffer(6), t.buffer(4), t.buffer(3)
    local n = assert(fd:preadv({b1, b2, b3}, offset))
    assert_equal(n, 13, "expect length 13")
    assert_equal(ffi.string(b1, 6), "testin")
    assert_equal(ffi.string(b2, 4), "gwri")
    assert_equal(ffi.string(b3, 3), "tev")
    assert(fd:seek(offset))
    local n = assert(fd:readv{b1, b2, b3})
    assert_equal(n, 13, "expect length 13")
    assert_equal(ffi.string(b1, 6), "testin")
    assert_equal(ffi.string(b2, 4), "gwri")
    assert_equal(ffi.string(b3, 3), "tev")
    assert(S.unlink(tmpfile))
  end,
  test_preadv_pwritev_large = function()
    if not features.preadv() then return true end
    local offset = largeval
    local fd = assert(S.open(tmpfile, "rdwr,creat", "rwxu"))
    local n = assert(fd:pwritev({"test", "ing", "writev"}, offset))
    assert_equal(n, 13, "expect length 13")
    local b1, b2, b3 = t.buffer(6), t.buffer(4), t.buffer(3)
    local n = assert(fd:preadv({b1, b2, b3}, offset))
    assert_equal(n, 13, "expect length 13")
    assert_equal(ffi.string(b1, 6), "testin")
    assert_equal(ffi.string(b2, 4), "gwri")
    assert_equal(ffi.string(b3, 3), "tev")
    assert(fd:seek(offset))
    local n = assert(fd:readv{b1, b2, b3})
    assert_equal(n, 13, "expect length 13")
    assert_equal(ffi.string(b1, 6), "testin")
    assert_equal(ffi.string(b2, 4), "gwri")
    assert_equal(ffi.string(b3, 3), "tev")
    assert(S.unlink(tmpfile))
  end,
}

test_address_names = {
  test_ipv4_names = function()
    assert_equal(tostring(t.in_addr("127.0.0.1")), "127.0.0.1", "print ipv4")
    assert_equal(tostring(t.in_addr("255.255.255.255")), "255.255.255.255", "print ipv4")
  end,
  test_ipv6_names = function()
    local sa = assert(t.sockaddr_in6(1234, "2002::4:5"))
    assert_equal(sa.port, 1234, "want same port back")
    assert_equal(tostring(sa.sin6_addr), "2002::4:5", "expect same address back")
  end,
}

test_sockets_tmp = { -- TODO delete once rest moved here
  test_unix_socketpair = function()
    local sv = assert(S.socketpair("unix", "stream"))
    assert(sv[1]:write("test"))
    local r = assert(sv[2]:read())
    assert_equal(r, "test")
    assert(sv:close())
  end,
}

-- note at present we check for uid 0, but could check capabilities instead.
if S.geteuid() == 0 then
  if abi.os == "linux" then
  -- some tests are causing issues, eg one of my servers reboots on pivot_root
  if not arg[1] and arg[1] ~= "all" then
    test_misc_root.test_pivot_root = nil
  elseif arg[1] == "all" then
    arg[1] = nil
  end

  -- cut out this section if you want to (careful!) debug on real interfaces
  -- TODO add to features as may not be supported
  assert(S.unshare("newnet, newns, newuts"), "tests as root require kernel namespaces") -- do not interfere with anything on host during tests
  local nl = require "linux.nl"
  local i = assert(nl.interfaces())
  local lo = assert(i.lo)
  assert(lo:up())
  assert(S.mount("none", "/sys", "sysfs"))
  else -- not Linux
    -- run all tests, no namespaces available
  end
else -- remove tests that need root
  for k in pairs(_G) do
    if k:match("test") then
      if k:match("root")
      then _G[k] = nil;
      else
        for j in pairs(_G[k]) do
          if j:match("test") and j:match("root") then _G[k][j] = nil end
        end
      end
    end
  end
end

local f
if arg[1] and arg[1] ~= "coverage" then f = luaunit:run(arg[1]) else f = luaunit:run() end

clean()

debug.sethook()

if f ~= 0 then S.exit("failure") end

-- TODO iterate through all functions in S and upvalues for active rather than trace
-- also check for non interesting cases, eg fall through to end
-- TODO add more files, this is not very applicable since code made modular

if arg[1] == "coverage" then
  cov.covered = 0
  cov.count = 0
  cov.nocov = {}
  cov.max = 1
  for k, _ in pairs(cov.active) do
    cov.count = cov.count + 1
    if k > cov.max then cov.max = k end
  end
  for k, _ in pairs(cov.cov) do
    cov.active[k] = nil
    cov.covered = cov.covered + 1
  end
  for k, _ in pairs(cov.active) do
    cov.nocov[k] = true
  end
  local gs, ge
  for i = 1, cov.max do
    if cov.nocov[i] then
      if gs then ge = i else gs, ge = i, i end
    else
      if gs then
        if gs == ge then
          print("no coverage of line " .. gs)
        else
          print("no coverage of lines " .. gs .. "-" .. ge)
        end
      end
      gs, ge = nil, nil
    end
  end
  print("\ncoverage is " .. cov.covered .. " of " .. cov.count .. " " .. math.floor(cov.covered / cov.count * 100) .. "%")
end

collectgarbage("collect")

S.exit("success")



