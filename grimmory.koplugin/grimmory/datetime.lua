-- Small date/time helpers.
--
-- `os.time()` always interprets a date table as *local* time, so UTC
-- values (ISO-8601 "...Z" from the server) must not be parsed with it.

local GrimmoryDateTime = {}

---@param t table date table holding UTC fields (year, month, day, hour, min, sec)
---@return integer | nil timestamp epoch seconds
function GrimmoryDateTime.timegm(t)
    local year = tonumber(t.year)
    local month = tonumber(t.month)
    local day = tonumber(t.day)

    if year == nil or month == nil or day == nil then
        return nil
    end

    -- Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant's
    -- days_from_civil).  Pure arithmetic: independent of the local time
    -- zone and of daylight saving time.
    if month <= 2 then
        year = year - 1
    end

    local era = math.floor(year / 400)
    local year_of_era = year - era * 400
    local shifted_month = (month + 9) % 12
    local day_of_year = math.floor((153 * shifted_month + 2) / 5) + day - 1
    local day_of_era = year_of_era * 365 + math.floor(year_of_era / 4)
        - math.floor(year_of_era / 100) + day_of_year
    local days = era * 146097 + day_of_era - 719468

    return days * 86400
        + (tonumber(t.hour) or 0) * 3600
        + (tonumber(t.min) or 0) * 60
        + (tonumber(t.sec) or 0)
end

---@param value string | nil "YYYY-MM-DD?HH:MM:SS" in UTC
---@return integer | nil
function GrimmoryDateTime.parseUtc(value)
    if type(value) ~= "string" then
        return nil
    end

    local year, month, day, hour, min, sec = value:match(
        "(%d+)-(%d+)-(%d+)[T ](%d+):(%d+):(%d+)"
    )

    if year == nil then
        return nil
    end

    return GrimmoryDateTime.timegm({
        year = year, month = month, day = day,
        hour = hour, min = min, sec = sec,
    })
end

---@param value string | nil "YYYY-MM-DD HH:MM:SS" in local time
---@return integer | nil
function GrimmoryDateTime.parseLocal(value)
    if type(value) ~= "string" then
        return nil
    end

    local year, month, day, hour, min, sec = value:match(
        "(%d+)-(%d+)-(%d+)[T ](%d+):(%d+):(%d+)"
    )

    if year == nil then
        return nil
    end

    local ok, timestamp = pcall(os.time, {
        year = tonumber(year), month = tonumber(month), day = tonumber(day),
        hour = tonumber(hour), min = tonumber(min), sec = tonumber(sec),
    })

    if not ok then
        return nil
    end

    return timestamp
end

return GrimmoryDateTime
