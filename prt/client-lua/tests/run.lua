local script_directory = assert(arg[0]:match("^(.*)/[^/]+$"))
local client_directory = assert(script_directory:match("^(.*)/tests$"))
package.path = client_directory .. "/?.lua;" .. package.path

local suites = {
    "tests.computation_test",
    "tests.domain_test",
    "tests.fold_test",
    "tests.adapter_test",
    "tests.semantic_reader_test",
    "tests.planner_test",
    "tests.gc_planner_test",
    "tests.context_test",
    "tests.fulfiller_test",
    "tests.dispatcher_test",
    "tests.actor_test",
}

local passed = 0
local failed = 0
for _, suite_name in ipairs(suites) do
    local suite = require(suite_name)
    for _, test_case in ipairs(suite) do
        local ok, failure = xpcall(test_case.run, debug.traceback)
        if ok then
            passed = passed + 1
            io.write(string.format("ok %d - %s\n", passed + failed, test_case.name))
        else
            failed = failed + 1
            io.stderr:write(string.format(
                "not ok %d - %s\n%s\n",
                passed + failed,
                test_case.name,
                failure
            ))
        end
    end
end

io.write(string.format("%d Lua client tests passed", passed))
if failed > 0 then
    io.write(string.format(", %d failed", failed))
end
io.write("\n")
if failed > 0 then
    os.exit(1)
end
