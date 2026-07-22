require "setup_path"

local scenario =
    require "test_cases.helpers.sealed_leaf_timeout"

scenario.longer_wins_after_midpoint()
