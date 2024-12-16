assert(#package.loaded == 0)
require "setup_path"
local const = assert(require "blockchain.constants")
return _ENV, const
