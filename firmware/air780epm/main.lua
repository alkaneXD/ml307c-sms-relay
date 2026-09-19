-- SMS Relay AT bridge for Air780EPM (LuatOS).
-- Speaks the PDU-mode SMS AT subset the macOS app already uses.
-- Flash with Luatools: hold BOOT, tap RST / power-cycle, then download this script
-- together with an Air780EPM kernel that includes the sms library (1/2/103–106).

PROJECT = "smsrelay-at"
VERSION = "0.5.5"

sys = require("sys")
if wdt then
    wdt.init(9000)
    sys.timerLoopStart(wdt.feed, 3000)
end

local UART_ID = uart.VUART_0
local NETLED_PIN = 27
local netlight = 1
local echo = false
local linebuf = ""
local cmgs_wait = false
local cmgs_buf = ""
local inbox = {}
local next_idx = 1
local sms_ready = false
local cached_number = ""
local flymode = false
local sms_mem = "SM"
local cell = {}

local function write(s)
    uart.write(UART_ID, s)
end

local function ok(extra)
    if extra and extra ~= "" then write(extra .. "\r\n") end
    write("OK\r\n")
end

local function err()
    write("ERROR\r\n")
end

local function hex_to_bytes(hex)
    hex = hex:gsub("%s", ""):upper()
    if #hex % 2 == 1 then return nil end
    local t = {}
    for i = 1, #hex, 2 do
        t[#t + 1] = tonumber(hex:sub(i, i + 1), 16)
        if not t[#t] then return nil end
    end
    return t
end

local function bytes_to_hex(t)
    local out = {}
    for i = 1, #t do
        local v = t[i] % 256
        if v < 0 then v = v + 256 end
        out[i] = string.format("%02X", v)
    end
    return table.concat(out)
end

local function bcd_swap(digits)
    if #digits % 2 == 1 then digits = digits .. "F" end
    local out = {}
    for i = 1, #digits, 2 do
        out[#out + 1] = tonumber(digits:sub(i + 1, i + 1) .. digits:sub(i, i), 16)
    end
    return out
end

local function from_semi(bytes, n_digits)
    local s = {}
    for i = 1, #bytes do
        local v = bytes[i]
        s[#s + 1] = string.format("%X", v % 16)
        s[#s + 1] = string.format("%X", math.floor(v / 16) % 16)
    end
    local d = table.concat(s):gsub("F", "")
    if n_digits and #d > n_digits then d = d:sub(1, n_digits) end
    return d
end

local function utf16be_to_utf8(bytes)
    local out = {}
    local i = 1
    while i < #bytes do
        local u = bytes[i] * 256 + bytes[i + 1]
        i = i + 2
        if u >= 0xD800 and u <= 0xDBFF and i < #bytes then
            local l = bytes[i] * 256 + bytes[i + 1]
            i = i + 2
            u = 0x10000 + (u - 0xD800) * 0x400 + (l - 0xDC00)
        end
        out[#out + 1] = utf8.char(u)
    end
    return table.concat(out)
end

local function utf8_to_utf16be(s)
    local out = {}
    local function append_cp(cp)
        if cp <= 0xFFFF then
            out[#out + 1] = math.floor(cp / 256)
            out[#out + 1] = cp % 256
        else
            cp = cp - 0x10000
            local hi = 0xD800 + math.floor(cp / 0x400)
            local lo = 0xDC00 + (cp % 0x400)
            out[#out + 1] = math.floor(hi / 256); out[#out + 1] = hi % 256
            out[#out + 1] = math.floor(lo / 256); out[#out + 1] = lo % 256
        end
    end
    -- iOS/Android emoji is UTF-8 from LuatOS. Invalid octets fall back to U+00xx.
    if utf8.len(s) then
        for _, cp in utf8.codes(s) do append_cp(cp) end
    else
        for i = 1, #s do
            out[#out + 1] = 0
            out[#out + 1] = s:byte(i)
        end
    end
    return out
end

local GSM7 = {
    "@","£","$","¥","è","é","ù","ì","ò","Ç","\n","Ø","ø","\r","Å","å",
    "Δ","_","Φ","Γ","Λ","Ω","Π","Ψ","Σ","Θ","Ξ","\x1B","Æ","æ","ß","É",
    " ","!","\"","#","¤","%","&","'","(",")","*","+",",","-",".","/",
    "0","1","2","3","4","5","6","7","8","9",":",";","<","=",">","?",
    "¡","A","B","C","D","E","F","G","H","I","J","K","L","M","N","O",
    "P","Q","R","S","T","U","V","W","X","Y","Z","Ä","Ö","Ñ","Ü","§",
    "¿","a","b","c","d","e","f","g","h","i","j","k","l","m","n","o",
    "p","q","r","s","t","u","v","w","x","y","z","ä","ö","ñ","ü","à",
}

local function gsm7_unpack(data, septet_count, skip_bits)
    local septets = {}
    for i = 0, septet_count - 1 do
        local bit = skip_bits + i * 7
        local bi, off = math.floor(bit / 8), bit % 8
        local v = 0
        if data[bi + 1] then v = v + (data[bi + 1] >> off) end
        if off > 1 and data[bi + 2] then
            v = v + ((data[bi + 2] << (8 - off)) & 0x7F)
        end
        septets[#septets + 1] = v & 0x7F
    end
    local chars = {}
    local i = 1
    while i <= #septets do
        local s = septets[i]
        if s == 0x1B and i < #septets then
            local ext = ({ [0x0A] = "\f", [0x14] = "^", [0x28] = "{", [0x29] = "}",
                [0x2F] = "\\", [0x3C] = "[", [0x3D] = "~", [0x3E] = "]", [0x40] = "|", [0x65] = "€" })[septets[i + 1]]
            chars[#chars + 1] = ext or "?"
            i = i + 2
        else
            chars[#chars + 1] = GSM7[s + 1] or "?"
            i = i + 1
        end
    end
    return table.concat(chars)
end

local function scts_now()
    local t = os.date("*t")
    local function bcd(n) return math.floor(n / 10) + (n % 10) * 16 end
    -- timezone +08: 32 quarters of an hour, GSM nibble-swapped → 0x23
    return { bcd(t.year % 100), bcd(t.month), bcd(t.day), bcd(t.hour), bcd(t.min), bcd(t.sec), 0x23 }
end

local GSM7_REV = {}
for i, ch in ipairs(GSM7) do
    if ch ~= "\x1B" then GSM7_REV[ch] = i - 1 end
end
local GSM7_EXT = {
    ["\f"] = 0x0A, ["^"] = 0x14, ["{"] = 0x28, ["}"] = 0x29, ["\\"] = 0x2F,
    ["["] = 0x3C, ["~"] = 0x3D, ["]"] = 0x3E, ["|"] = 0x40, ["€"] = 0x65,
}

local function to_septets(s)
    if not utf8.len(s) then return nil end
    local sep = {}
    for _, cp in utf8.codes(s) do
        local ch = utf8.char(cp)
        if GSM7_REV[ch] then
            sep[#sep + 1] = GSM7_REV[ch]
        elseif GSM7_EXT[ch] then
            sep[#sep + 1] = 0x1B
            sep[#sep + 1] = GSM7_EXT[ch]
        else
            return nil
        end
    end
    return sep
end

local function pack_septets(sep, skip_bits)
    skip_bits = skip_bits or 0
    local nbytes = math.floor((skip_bits + #sep * 7 + 7) / 8)
    local out = {}
    for i = 1, nbytes do out[i] = 0 end
    local bit = skip_bits
    for i = 1, #sep do
        local s = sep[i]
        for b = 0, 6 do
            if (s >> b) & 1 == 1 then
                local bi = math.floor(bit / 8) + 1
                out[bi] = out[bi] + (1 << (bit % 8))
            end
            bit = bit + 1
        end
    end
    return out
end

local function encode_oa(num)
    local s = tostring(num or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return { 0, 0x81 } end
    local digits = s:gsub("[^0-9]", "")
    local compact = s:gsub("[%s%-%(%)%+]", "")
    if #digits >= 3 and digits == compact then
        local toa = (s:find("+", 1, true) or #digits >= 11) and 0x91 or 0x81
        local oa = { #digits, toa }
        for _, b in ipairs(bcd_swap(digits)) do oa[#oa + 1] = b end
        return oa
    end
    local sep = to_septets(s)
    if not sep or #sep == 0 then
        if #digits >= 3 then
            local oa = { #digits, 0x91 }
            for _, b in ipairs(bcd_swap(digits)) do oa[#oa + 1] = b end
            return oa
        end
        return { 0, 0x81 }
    end
    local packed = pack_septets(sep, 0)
    local oa = { math.ceil(#sep * 7 / 4), 0xD0 }
    for _, b in ipairs(packed) do oa[#oa + 1] = b end
    return oa
end

-- LuatOS concatenates long SMS into one string. Each AT PDU must stay ≤140 user octets.
local function deliver_pdus(num, text)
    text = text or ""
    local oa = encode_oa(num)
    local sep = to_septets(text)
    local chunks = {}
    if sep then
        if #sep <= 160 then
            chunks[1] = { kind = "gsm7", sep = sep }
        else
            local i = 1
            while i <= #sep do
                local e = math.min(i + 152, #sep)
                if e < #sep and sep[e] == 0x1B then e = e - 1 end
                local part = {}
                for j = i, e do part[#part + 1] = sep[j] end
                chunks[#chunks + 1] = { kind = "gsm7", sep = part }
                i = e + 1
            end
        end
    else
        local ud = utf8_to_utf16be(text)
        if #ud <= 140 then
            chunks[1] = { kind = "ucs2", bytes = ud }
        else
            local i = 1
            while i <= #ud do
                local e = math.min(i + 133, #ud)
                if (e - i + 1) % 2 == 1 then e = e - 1 end
                if e >= i + 1 then
                    local unit = ud[e - 1] * 256 + ud[e]
                    if unit >= 0xD800 and unit <= 0xDBFF then e = e - 2 end
                end
                local part = {}
                for j = i, e do part[#part + 1] = ud[j] end
                chunks[#chunks + 1] = { kind = "ucs2", bytes = part }
                i = e + 1
            end
        end
    end
    local total = math.min(#chunks, 10)
    local ref = math.random(0, 255)
    local out = {}
    for seq = 1, total do
        local ch = chunks[seq]
        local first = 0x04
        local udh = {}
        if total > 1 then
            first = first + 0x40
            udh = { 0x05, 0x00, 0x03, ref, total, seq }
        end
        local ud, udl, dcs
        if ch.kind == "gsm7" then
            dcs = 0x00
            local header_bits = #udh * 8
            local header_septets = math.floor((header_bits + 6) / 7)
            local skip = (#udh > 0) and (header_septets * 7 - header_bits) or 0
            local packed = pack_septets(ch.sep, skip)
            ud = {}
            for _, b in ipairs(udh) do ud[#ud + 1] = b end
            for _, b in ipairs(packed) do ud[#ud + 1] = b end
            udl = header_septets + #ch.sep
        else
            dcs = 0x08
            ud = {}
            for _, b in ipairs(udh) do ud[#ud + 1] = b end
            for _, b in ipairs(ch.bytes) do ud[#ud + 1] = b end
            udl = #ud
        end
        if udl > 255 then udl = 255 end
        local tpdu = { first }
        for _, b in ipairs(oa) do tpdu[#tpdu + 1] = b end
        tpdu[#tpdu + 1] = 0x00
        tpdu[#tpdu + 1] = dcs
        for _, b in ipairs(scts_now()) do tpdu[#tpdu + 1] = b end
        tpdu[#tpdu + 1] = udl
        for _, b in ipairs(ud) do tpdu[#tpdu + 1] = b end
        local pdu = { 0x00 }
        for _, b in ipairs(tpdu) do pdu[#pdu + 1] = b end
        out[#out + 1] = bytes_to_hex(pdu)
    end
    return out
end

local function decode_submit(hex)
    local b = hex_to_bytes(hex)
    if not b or #b < 8 then return nil, nil end
    local i = 1
    local smsc_len = b[i]; i = i + 1
    i = i + smsc_len
    if i + 4 > #b then return nil, nil end
    local fo = b[i]; i = i + 1
    i = i + 1 -- TP-MR
    local da_len = b[i]; i = i + 1
    local da_type = b[i]; i = i + 1
    local da_oct = math.floor((da_len + 1) / 2)
    local da = {}
    for n = 1, da_oct do da[n] = b[i]; i = i + 1 end
    local digits = from_semi(da, da_len)
    local num = ((da_type & 0x70) == 0x10 and "+" or "") .. digits
    i = i + 1 -- PID
    local dcs = b[i]; i = i + 1
    -- no VP in our encoder (first octet 0x01)
    if (fo & 0x18) == 0x10 then i = i + 1 end
    if (fo & 0x18) == 0x08 then i = i + 7 end
    local udl = b[i]; i = i + 1
    local ud = {}
    for n = i, #b do ud[#ud + 1] = b[n] end
    local has_udh = (fo & 0x40) ~= 0
    local skip = 0
    local ud_body = ud
    if has_udh and #ud > 0 then
        local udhl = ud[1]
        skip = 1 + udhl
        ud_body = {}
        for n = skip + 1, #ud do ud_body[#ud_body + 1] = ud[n] end
    end
    local text
    if (dcs & 0x0C) == 0x08 then
        text = utf16be_to_utf8(ud_body)
    else
        local header_bits = skip * 8
        local header_septets = math.floor((header_bits + 6) / 7)
        local skip_bits = has_udh and (header_septets * 7 - header_bits) or 0
        local septets = udl - (has_udh and header_septets or 0)
        text = gsm7_unpack(ud_body, math.max(septets, 0), skip_bits)
    end
    return num, text
end

-- sms.send is async: a true return only means "queued". AT+CMGS must wait for SMS_SENT
-- (SMSC accept/reject). auto_phone_fix must stay false or a +63… number becomes 8663….
local function dest_phone(num)
    return tostring(num or ""):gsub("^%+", "")
end

local function inbox_count()
    local n = 0
    for _ in pairs(inbox) do n = n + 1 end
    return n
end

local function refresh_cell()
    pcall(function()
        local c = mobile.scell()
        if type(c) == "table" then cell = c end
    end)
    return cell
end

local function plmn()
    local c = refresh_cell()
    local mcc, mnc = tonumber(c.mcc), tonumber(c.mnc)
    if mcc and mnc then
        if mnc >= 100 then return string.format("%03d%03d", mcc, mnc) end
        return string.format("%03d%02d", mcc, mnc)
    end
    local imsi = mobile.imsi() or ""
    if #imsi < 5 then return "" end
    local three = {
        ["310"] = 1, ["311"] = 1, ["316"] = 1, ["302"] = 1, ["334"] = 1,
        ["338"] = 1, ["342"] = 1, ["344"] = 1, ["346"] = 1, ["348"] = 1,
        ["365"] = 1, ["376"] = 1, ["708"] = 1, ["722"] = 1, ["732"] = 1,
    }
    if three[imsi:sub(1, 3)] and #imsi >= 6 then return imsi:sub(1, 6) end
    return imsi:sub(1, 5)
end

local function hexid(n)
    n = tonumber(n) or 0
    if n < 0 then n = 0 end
    return string.format("%X", n)
end

local function creg_line(tag)
    local st = tonumber(mobile.status()) or 4
    local c = refresh_cell()
    local tac, eci = c.tac, c.eci or c.cid
    if not tac then pcall(function() tac = mobile.tac() end) end
    if not eci then pcall(function() eci = mobile.eci() end) end
    if tac and tac ~= -1 and tac ~= 0 and eci and eci ~= -1 and eci ~= 0 then
        return string.format("%s%d,\"%s\",\"%s\",7", tag, st, hexid(tac), hexid(eci))
    end
    return string.format("%s%d,,,7", tag, st)
end

local function cesq_line()
    local rsrp, rsrq = 0, 0
    pcall(function() rsrp = tonumber(mobile.rsrp()) or 0 end)
    pcall(function() rsrq = tonumber(mobile.rsrq()) or 0 end)
    local c = refresh_cell()
    if (rsrp == 0 or not rsrp) and c.rsrp then rsrp = tonumber(c.rsrp) or 0 end
    if (rsrq == 0 or not rsrq) and c.rsrq then rsrq = tonumber(c.rsrq) or 0 end
    local rsrp_i, rsrq_i = 255, 255
    if rsrp <= -44 and rsrp >= -140 then
        rsrp_i = math.floor(rsrp + 140)
        if rsrp_i < 0 then rsrp_i = 0 end
        if rsrp_i > 97 then rsrp_i = 97 end
    end
    if rsrq ~= 0 and rsrq <= -3 and rsrq >= -19.5 then
        rsrq_i = math.floor((rsrq + 19.5) * 2 + 0.5)
        if rsrq_i < 0 then rsrq_i = 0 end
        if rsrq_i > 34 then rsrq_i = 34 end
    end
    return string.format("+CESQ: 99,99,255,255,%d,%d", rsrq_i, rsrp_i)
end

local function read_number()
    pcall(function()
        local v = mobile.number(0)
        if v and tostring(v) ~= "" and tostring(v) ~= "nil" then
            cached_number = tostring(v)
        end
    end)
    return cached_number
end

local function send_sms(num, text)
    local phone = dest_phone(num)
    if phone == "" or not text or text == "" then return false, 0, 500 end
    if not sms_ready then
        local got = sys.waitUntil("SMS_READY", 8000)
        if got then sms_ready = true end
    end
    local queued = sms.send(phone, text, false, false)
    if not queued then
        log.info("smsrelay-at", "sms.send queue fail", phone)
        return false, 0, 500
    end
    local r = { sys.waitUntil("SMS_SENT", 55000) }
    log.info("smsrelay-at", "SMS_SENT", r[1], r[2], r[3], r[4], r[5], r[6])
    if r[1] == false or r[1] == nil then
        return false, 0, 332
    end
    local result, msg_ref, error_code
    if r[1] == true then
        result = r[2]
        msg_ref = r[5]
        error_code = r[6]
        if result == nil then result = true end
    else
        result = r[1]
        msg_ref = r[4]
        error_code = r[5]
    end
    if result == true then
        return true, tonumber(msg_ref) or 0, 0
    end
    local code = tonumber(error_code) or 500
    if code == 0 then code = 500 end
    return false, 0, code
end

local function set_netlight(on)
    netlight = on and 1 or 0
    pcall(function() gpio.setup(NETLED_PIN, netlight) end)
end

local function sim_ready()
    local id = mobile.iccid()
    return id and id ~= ""
end

local function creg_stat()
    local st = tonumber(mobile.status()) or 4
    return st
end

local function handle_at(cmd)
    cmd = cmd:gsub("^%s+", ""):gsub("%s+$", "")
    if cmd == "" then return end
    local u = cmd:upper()

    if u == "AT" or u == "ATE0" or u == "ATE1" then
        if u == "ATE0" then echo = false end
        if u == "ATE1" then echo = true end
        ok()
    elseif u == "ATI" then
        write("Manufacturer: AirM2M\r\nModel: Air780EPM\r\nRevision: smsrelay-at " .. VERSION .. "\r\n")
        ok()
    elseif u == "AT+CGMM" or u == "AT+GMM" then
        -- informationText (no +prefix) so the Mac app fills Model / probe blob
        write("Air780EPM\r\n")
        ok()
    elseif u == "AT+CGMI" then
        write("AirM2M\r\n")
        ok()
    elseif u == "AT+CGMR" or u == "AT+GMR" then
        write("smsrelay-at " .. VERSION .. "\r\n")
        ok()
    elseif u == "AT+CGSN" or u == "AT+GSN" then
        write((mobile.imei() or "") .. "\r\n")
        ok()
    elseif u == "AT+CIMI" then
        write((mobile.imsi() or "") .. "\r\n")
        ok()
    elseif u == "AT+CCID" or u == "AT+ICCID" or u == "AT+MCCID" then
        local id = mobile.iccid() or ""
        if u == "AT+MCCID" then write("+MCCID: " .. id .. "\r\n")
        elseif u == "AT+ICCID" then write("+ICCID: " .. id .. "\r\n")
        else write(id .. "\r\n") end
        ok()
    elseif u == "AT+CPIN?" then
        write(sim_ready() and "+CPIN: READY\r\n" or "+CPIN: SIM not inserted\r\n")
        ok()
    elseif u == "AT+CSQ" then
        local n = tonumber(mobile.csq()) or 99
        if n == 0 then n = 99 end
        write(string.format("+CSQ: %d,99\r\n", n))
        ok()
    elseif u == "AT+CESQ" then
        write(cesq_line() .. "\r\n")
        ok()
    elseif u:match("^AT%+CFUN") then
        if u == "AT+CFUN?" then
            write(string.format("+CFUN: %d\r\n", flymode and 4 or 1)); ok()
        elseif u == "AT+CFUN=4" then
            flymode = true
            pcall(function() mobile.flymode(0, true) end); ok()
        elseif u:match("^AT%+CFUN=1") then
            flymode = false
            pcall(function() mobile.flymode(0, false) end); ok()
        else ok() end
    elseif u == "AT+CREG?" or u == "AT+CEREG?" then
        local tag = u:find("CEREG") and "+CEREG: 2," or "+CREG: 2,"
        write(creg_line(tag) .. "\r\n")
        ok()
    elseif u == "AT+CREG=2" or u == "AT+CEREG=2" or u == "AT+CREG=1" or u == "AT+CEREG=1" then
        ok()
    elseif u == "AT+CGATT?" then
        local st = creg_stat()
        write(((st == 1 or st == 5 or st == 6 or st == 7 or st == 9 or st == 10) and "+CGATT: 1\r\n") or "+CGATT: 0\r\n")
        ok()
    elseif u:match("^AT%+CGATT=") then
        ok()
    elseif u == "AT+COPS?" then
        -- Must be ASCII 7 (LTE). A Lua octal BEL in this string hid the operator in the Mac app.
        write(string.format("+COPS: 0,2,\"%s\",7\r\n", plmn()))
        ok()
    elseif u == "AT+CNUM" or u == "AT+CNUM?" then
        local n = read_number()
        if n ~= "" then
            local typ = (n:sub(1, 1) == "+" or #n > 10) and 145 or 129
            write(string.format("+CNUM: \"\",\"%s\",%d\r\n", n, typ))
        end
        ok()
    elseif u == "AT+CSCA?" then
        write("+CSCA: \"\",129\r\n")
        ok()
    elseif u:match("^AT%+CSCA=") then
        ok()
    elseif u == "AT+CMEE=2" or u == "AT+CMEE=1" then
        ok()
    elseif u == "AT+CMGF?" then
        write("+CMGF: 0\r\n"); ok()
    elseif u:match("^AT%+CMGF=") then
        ok()
    elseif u:match("^AT%+CPMS=") then
        sms_mem = u:match('"([A-Z]+)"') or sms_mem
        local n = inbox_count()
        write(string.format("+CPMS: %d,40,%d,40,%d,40\r\n", n, n, n))
        ok()
    elseif u:match("^AT%+CPMS%?") then
        local n = inbox_count()
        write(string.format("+CPMS: \"%s\",%d,40,\"%s\",%d,40,\"%s\",%d,40\r\n",
            sms_mem, n, sms_mem, n, sms_mem, n))
        ok()
    elseif u:match("^AT%+CNMI=") or u:match("^AT%+CSMS") then
        ok()
    elseif u == "AT+CNETLIGHT?" then
        write("+CNETLIGHT: " .. tostring(netlight) .. "\r\n")
        ok()
    elseif u:match("^AT%+CNETLIGHT=") then
        set_netlight(u:sub(-1) ~= "0")
        ok()
    elseif u:match("^AT%+MLED=") then
        set_netlight(not u:match(",0%s*$"))
        ok()
    elseif u:match("^AT%+CMGL") then
        for idx, rec in pairs(inbox) do
            write(string.format("+CMGL: %d,%d,,%d\r\n%s\r\n", idx, rec.status, math.floor(#rec.pdu / 2) - 1, rec.pdu))
        end
        ok()
    elseif u:match("^AT%+CMGR=") then
        local idx = tonumber(u:match("=(%d+)"))
        local rec = idx and inbox[idx]
        if not rec then err(); return end
        write(string.format("+CMGR: %d,,%d\r\n%s\r\n", rec.status, math.floor(#rec.pdu / 2) - 1, rec.pdu))
        ok()
    elseif u:match("^AT%+CMGD=") then
        local idx = tonumber(u:match("=(%d+)"))
        if idx then inbox[idx] = nil end
        ok()
    elseif u:match("^AT%+CMGS=") then
        cmgs_wait = true
        cmgs_buf = ""
        write("\r\n> ")
    elseif u:match("^AT%+CNMA") then
        ok()
    else
        -- ML307-only knobs: ignore so configure() can proceed.
        if u:find("MLPMCFG") or u:find("MDIALUP") or u:find("MUECONFIG")
            or u:find("CIREG") or u:find("CASIMS") or u:find("CNUM") then
            ok()
        else
            err()
        end
    end
end

local function ingest_serial(chunk)
    if cmgs_wait then
        -- ESC aborts a half-finished CMGS; without this the shim stays stuck.
        if chunk:find("\027", 1, true) or (cmgs_buf .. chunk):find("\027", 1, true) then
            cmgs_wait = false
            cmgs_buf = ""
            write("\r\nERROR\r\n")
            return
        end
        cmgs_buf = cmgs_buf .. chunk
        local z = cmgs_buf:find("\026", 1, true)
        if not z then return end
        local hex = cmgs_buf:sub(1, z - 1):gsub("[\r\n]", "")
        cmgs_wait = false
        cmgs_buf = ""
        local num, text = decode_submit(hex)
        if not num or not text or text == "" then
            err()
            return
        end
        sys.taskInit(function()
            local ok_send, mr, code = send_sms(num, text)
            if ok_send then
                write(string.format("+CMGS: %d\r\nOK\r\n", mr or 0))
            else
                write(string.format("+CMS ERROR: %d\r\n", code or 500))
            end
        end)
        return
    end
    linebuf = linebuf .. chunk
    while true do
        local a, b = linebuf:find("\r")
        if not a then break end
        local line = linebuf:sub(1, a - 1):gsub("\n", "")
        linebuf = linebuf:sub(b + 1)
        if echo and line ~= "" then write(line .. "\r\n") end
        handle_at(line)
    end
end

uart.setup(UART_ID, 115200, 8, 1)
uart.on(UART_ID, "receive", function(id)
    local s = uart.read(id, 512)
    while s and #s > 0 do
        ingest_serial(s)
        s = uart.read(id, 512)
    end
end)

pcall(function()
    mobile.flymode(0, true)
    mobile.config(mobile.CONF_USB_ETHERNET, 0)
    mobile.flymode(0, false)
end)
pcall(function() sms.autoLong(true) end)
set_netlight(1)

sys.subscribe("SMS_READY", function()
    sms_ready = true
    log.info("smsrelay-at", "SMS_READY")
end)

sms.setNewSmsCb(function(num, txt, metas)
    local ok, err = pcall(function()
        if (not num or num == "") and type(metas) == "table" then
            num = metas.num or metas.oa or num
        end
        log.info("smsrelay-at", "SMS", tostring(num), txt and #tostring(txt) or 0)
        local parts = deliver_pdus(num, tostring(txt or ""))
        for i = 1, #parts do
            local idx = next_idx
            next_idx = next_idx + 1
            inbox[idx] = { pdu = parts[i], status = 0 }
            write(string.format("\r\n+CMTI: \"%s\",%d\r\n", sms_mem, idx))
        end
    end)
    if not ok then log.info("smsrelay-at", "SMS encode fail", err) end
end)

sys.subscribe("IP_READY", function()
    write("\r\n+CEREG: 1\r\n+CREG: 1\r\n")
end)

sys.subscribe("SIM_IND", function(status)
    log.info("smsrelay-at", "SIM_IND", status)
    if status == "GET_NUMBER" then read_number() end
    if status == "RDY" then pcall(function() mobile.reqCellInfo(10) end) end
end)

sys.subscribe("SCELL_INFO", function()
    refresh_cell()
end)

sys.taskInit(function()
    sys.wait(4000)
    pcall(function() mobile.reqCellInfo(15) end)
    read_number()
end)

log.info("smsrelay-at", VERSION, rtos.bsp())
sys.run()
