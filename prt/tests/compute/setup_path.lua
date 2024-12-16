-- setup client-lua path
package.path = package.path .. ";../common/?.lua"
package.path = package.path .. ";../../client-lua/?.lua"

-- setup cartesi machine path
package.path = package.path .. ";/opt/cartesi/lib/lua/5.4/?.lua"
package.cpath = package.cpath .. ";/opt/cartesi/lib/lua/5.4/?.so"
