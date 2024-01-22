/**
The MIT License (MIT)

Copyright (c) ldrumm 2014

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

#include <errno.h>
#include <string.h>
#include <lua.h>
#include <lauxlib.h>

#if LUA_VERSION_NUM < 502
	#define luaL_newlib(L, l) ( lua_newtable(L), luaL_register(L, NULL, l))
#endif


#if defined(__APPLE__) && defined(__MACH__)
 #include <mach/mach_time.h>
 #ifdef CHRONOS_USE_COREAUDIO
  #include <CoreAudio/HostTime.h>
 #endif
#elif defined(_WIN32)
 #define WIN32_LEAN_AND_MEAN
 #include <windows.h>
#elif defined(__unix__) || defined(__linux__) && !defined(__APPLE__)
 #include <unistd.h>
 #if defined (_POSIX_TIMERS) && _POSIX_TIMERS > 0
  #ifdef _POSIX_MONOTONIC_CLOCK
   #define HAVE_CLOCK_GETTIME
   #include <time.h>
  #else
   #warning "A nanosecond resolution monotonic clock is not available;"
   #warning "falling back to microsecond gettimeofday()"
   #include <sys/time.h>
  #endif
 #endif
#endif

# if !defined(__APPLE__) && (defined(__unix__) || defined(__linux__))
static int chronos_nanotime(lua_State *L)
{
#ifdef HAVE_CLOCK_GETTIME
    /** From man clock_gettime(2)
       CLOCK_MONOTONIC
          Clock  that  cannot  be  set and represents monotonic time since
          some unspecified starting point.  This clock is not affected by
          discontinuous jumps in the system time (e.g., if the system
          administrator manually changes the clock), but is affected by the
          incremental  adjustments  performed by adjtime(3) and NTP.

       CLOCK_MONOTONIC_COARSE (since Linux 2.6.32; Linux-specific)
              A faster but less precise version of CLOCK_MONOTONIC.
              Use when you need very fast, but not fine-grained timestamps.

       CLOCK_MONOTONIC_RAW (since Linux 2.6.28; Linux-specific)
              Similar to CLOCK_MONOTONIC, but provides access to a raw
              hardware-based time that is not subject to NTP adjustments or the
              incremental adjustments performed by adjtime(3).
    */
    struct timespec t_info;
    const double multiplier = 1.0 / 1e9;

    if (clock_gettime(CLOCK_MONOTONIC, &t_info) != 0) {
        return luaL_error(L, "clock_gettime() failed:%s", strerror(errno));
    }
    lua_pushnumber(
        L,
        (lua_Number)t_info.tv_sec + (t_info.tv_nsec * multiplier)
    );
    return 1;

#else
    struct timeval t_info;
    if (gettimeofday(&t_info, NULL) < 0) {
        return luaL_error(L, "gettimeofday() failed!:%s", strerror(errno));
    };
    lua_pushnumber(L, (lua_Number)t_info.tv_sec + t_info.tv_usec / 1.e6);
    return 1;
#endif
}


#elif defined(_WIN32)
static int chronos_nanotime(lua_State * L)
{
    // See http://msdn.microsoft.com/en-us/library/windows/desktop/dn553408(v=vs.85).aspx
    LARGE_INTEGER timer;
    LARGE_INTEGER freq;
    static double multiplier;
    static int init = 1;

    /* Though bool, guaranteed to not return an error after WinXP,
     and the alternatives have fairly crappy resolution.
     However, if you're on XP, you've got bigger problems than timing.
    */
    (void) QueryPerformanceCounter(&timer);
    if(init){
        QueryPerformanceFrequency(&freq);
        multiplier = 1.0 / (double)freq.QuadPart;
        init = 0;
    }
    lua_pushnumber(L, (lua_Number)(timer.QuadPart * multiplier));
    return 1;
}


#elif defined(__APPLE__) && defined(__MACH__)
static int chronos_nanotime(lua_State * L)
{
    //TODO All the apple stuff is untested because, like, I don't even got Apple.
    //If like, you have a mac, let me know whether this works.
    //see https://stackoverflow.com/questions/675626/coreaudio-audiotimestamp-mhosttime-clock-frequency
    //for info.
#ifdef CHRONOS_USE_COREAUDIO
    //Apparently this is just a wrapper around mach_absolute_time() anyway.
    lua_pushnumber(
        L,
        (lua_Number)AudioConvertHostTimeToNanos(AudioGetCurrentHostTime()) * 1.e9
    );
    return 1;
#else
    static int init = 1;
    static double resolution;
    static double multiplier;
    mach_timebase_info_data_t res_info;
    if(init){
        mach_timebase_info(&res_info);
        resolution = (double)res_info.numer / res_info.denom;
        multiplier = 1. / 1.e9;
        init = 0;
    }

    lua_pushnumber(L, (lua_Number)(mach_absolute_time() * resolution) * multiplier);
    return 1;
#endif
}
#else
#error Your platform is not supported
#endif


static const struct luaL_Reg chronos_reg[] = {
    {"nanotime", chronos_nanotime},
    {NULL, NULL}
};


LUA_API int luaopen_chronos(lua_State *L){
    luaL_newlib(L, chronos_reg);
    return 1;
}
