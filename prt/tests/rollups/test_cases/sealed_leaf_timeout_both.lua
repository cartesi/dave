require "setup_path"

local scenario =
    require "test_cases.helpers.sealed_leaf_timeout"

scenario.both_eliminate_at_long_deadline()
