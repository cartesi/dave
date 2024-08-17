#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include "playpal2rgb.c"

// Lua wrapper for the sum function
int lua_playpal2rgb(lua_State *L) {
    const char* str = luaL_checkstring(L, 1);
    int result = playpal2rgb(str);
    lua_pushinteger(L, result);
    return 1;  // number of return values
}

// Function to register our sum function in Lua
int luaopen_playpal2rgb_lua(lua_State *L) {
    lua_newtable(L);
    lua_pushcfunction(L, lua_playpal2rgb);
    lua_setfield(L, -2, "convert");
    return 1;
}
