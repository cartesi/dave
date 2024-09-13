assert(#package.loaded == 0)
require "setup_path"

local const0 = require "blockchain.constants"

local new_scoped_require = require "utils.scoped_require"
local scoped_require1 = new_scoped_require(_ENV)
local env1, const1 = scoped_require1 "utils.test"
assert(_ENV ~= env1)
assert(const0 ~= const1)

local scoped_require2 = new_scoped_require(_ENV)
local env2, const2 = scoped_require2 "utils.test"
assert(env1 ~= env2)
assert(const1 ~= const2)
