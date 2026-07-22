local Test = {}

function Test.case(name, run)
    return {
        name = name,
        run = run,
    }
end

function Test.equal(actual, expected, message)
    assert(actual == expected, message or string.format(
        "expected %s, got %s",
        tostring(expected),
        tostring(actual)
    ))
end

function Test.truthy(value, message)
    assert(value, message or "expected a truthy value")
end

function Test.error_like(pattern, run)
    local ok, error_message = pcall(run)
    assert(not ok, "expected the operation to fail")
    assert(tostring(error_message):find(pattern, 1, true), string.format(
        "expected error containing %q, got %q",
        pattern,
        tostring(error_message)
    ))
end

return Test
