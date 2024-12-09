-- setup client-lua path
package.path = package.path .. ";../../../prt/client-lua/?.lua"
package.path = package.path .. ";../../../prt/tests/compute/?.lua"

-- setup cartesi machine path
package.path = package.path .. ";/opt/cartesi/lib/lua/5.4/?.lua"
package.cpath = package.cpath .. ";/opt/cartesi/lib/lua/5.4/?.so"
