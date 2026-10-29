// The externals of Data.Time (the time package).
//
// A ClockTime is CTime n, n seconds since the epoch. A CalendarTime is
// CalendarTime year month day hour minute second tz, with month 1-12 and
// tz the offset from UTC in seconds, as KiCS2's Data.Time.kics2 has it.

#include <time.h>
#include "ext.h"
#include "Data/Time.h"

static field mk_calendar(const struct tm* t, long tz)
{
    return make_Data_DOTime__CalendarTime(ext_mk_int(t->tm_year + 1900),
                                          ext_mk_int(t->tm_mon + 1),
                                          ext_mk_int(t->tm_mday),
                                          ext_mk_int(t->tm_hour),
                                          ext_mk_int(t->tm_min),
                                          ext_mk_int(t->tm_sec),
                                          ext_mk_int(tz), 0);
}

// The seconds in a ClockTime argument. Runs the machine.
static time_t clock_seconds(field ct)
{
    return (time_t)ext_int(child_at(ext_hnf(ct), 0));
}

EXT(Data_DOTime__getClockTime)
{
    ext_return(root, make_Data_DOTime__CTime(ext_mk_int((long)time(NULL)), 0));
}

EXT(Data_DOTime__prim_UStoCalendarTime)
{
    GC_ROOT(root);
    time_t secs = clock_seconds(child_at(root, 0));
    GC_UNROOT(1);
    struct tm t;
    localtime_r(&secs, &t);
    ext_return(root, mk_calendar(&t, t.tm_gmtoff));
}

EXT(Data_DOTime__prim_UStoUTCTime)
{
    GC_ROOT(root);
    time_t secs = clock_seconds(child_at(root, 0));
    GC_UNROOT(1);
    struct tm t;
    gmtime_r(&secs, &t);
    ext_return(root, mk_calendar(&t, 0));
}

// The calendar time's fields are in its own time zone, so convert them as
// UTC and then take the offset away.
EXT(Data_DOTime__prim_UStoClockTime)
{
    GC_ROOT(root);
    field ct = ext_hnf(child_at(root, 0));
    GC_ROOT(ct);
    long f[7];
    for(int i = 0; i < 7; i++)
    {
        f[i] = ext_int(child_at_v(ct, i));
    }
    GC_UNROOT(2);
    struct tm t = { .tm_year = (int)f[0] - 1900, .tm_mon = (int)f[1] - 1,
                    .tm_mday = (int)f[2], .tm_hour = (int)f[3],
                    .tm_min = (int)f[4], .tm_sec = (int)f[5] };
    long secs = (long)timegm(&t) - f[6];
    ext_return(root, make_Data_DOTime__CTime(ext_mk_int(secs), 0));
}
