--[[
Action sheets for the plugin's dialogs: SimpleUI's own action sheet when
simpleui.koplugin 3 is installed (so they look like SimpleUI's dialogs), a
KOReader ButtonDialog / ConfirmBox with the same content otherwise.

    Sheet.show({
        title = "Title", icon = "update", message = "Longer text",
        auto_close = true,        -- close the sheet before a callback runs
        on_dismiss = function() end, -- tap outside / Back
        sections = {
            { type = "tiles", items = { item, ... } },     -- icon above label
            { type = "rows", rows = { { item }, { item, item } } },
            { type = "segments", items = { item, ... } },  -- buttons in a row
        },
    })

An item is { text, sui_icon, callback, enabled, checked (rows), selected
(segments) }; `sui_icon` is a key of SimpleUI's icons (see ui/style.lua).
Returns a handle with :close().
--]]

local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Sheet = {}

local action_sheet -- nil: not looked up yet; false: SimpleUI not installed

local function actionSheet()
    if action_sheet == nil then
        local ok, module = pcall(require, "engines/sui_action_sheet")
        action_sheet = (ok and type(module) == "table" and type(module.show) == "function") and module or false
    end
    return action_sheet or nil
end

--- Whether SimpleUI's action sheets are used.
function Sheet.isSimpleUI()
    return actionSheet() ~= nil
end

--- A `rows` section with one item per row.
function Sheet.list(items)
    local rows = {}
    for _, item in ipairs(items) do
        table.insert(rows, { item })
    end
    return { type = "rows", rows = rows }
end

local function copyItem(item)
    local copy = {}
    for key, value in pairs(item) do
        copy[key] = value
    end
    return copy
end

--- The sections with every item copied, so `wrap` can change callbacks
--- without touching the caller's tables.
local function copySections(sections, wrap)
    local copies = {}
    for _, section in ipairs(sections) do
        local copy = { type = section.type }
        if section.rows then
            copy.rows = {}
            for _, row in ipairs(section.rows) do
                local items = {}
                for _, item in ipairs(row) do
                    table.insert(items, wrap(copyItem(item)))
                end
                table.insert(copy.rows, items)
            end
        else
            copy.items = {}
            for _, item in ipairs(section.items or {}) do
                table.insert(copy.items, wrap(copyItem(item)))
            end
        end
        table.insert(copies, copy)
    end
    return copies
end

local function showSimpleUI(module, opts)
    local window
    local sections = copySections(opts.sections, function(item)
        local callback = item.callback
        -- Items without a callback (e.g. "Close") only close the sheet
        if opts.auto_close then
            item.callback = function()
                window:close()
                if callback then
                    callback()
                end
            end
        end
        return item
    end)

    window = module.show({
        name = opts.name or "grimmory_sheet",
        title = opts.title,
        icon = opts.icon,
        message = opts.message,
        fit_width = opts.fit_width,
        on_dismiss = opts.on_dismiss,
        on_close = opts.on_close,
        sections = sections,
    })

    return {
        close = function()
            pcall(function() window:close() end)
        end,
    }
end

local function buttonText(item)
    if item.checked or item.selected then
        return "✓ " .. (item.text or "")
    end
    return item.text or ""
end

local function showButtonDialog(opts)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog

    local buttons = {}
    local function add_row(items)
        local row = {}
        for _, item in ipairs(items) do
            local callback = item.callback
            table.insert(row, {
                text = buttonText(item),
                enabled = item.enabled ~= false,
                callback = function()
                    if opts.auto_close then
                        UIManager:close(dialog)
                    end
                    if callback then
                        callback()
                    end
                end,
            })
        end
        if #row > 0 then
            table.insert(buttons, row)
        end
    end

    for _, section in ipairs(opts.sections) do
        if section.rows then
            for _, row in ipairs(section.rows) do
                add_row(row)
            end
        else
            add_row(section.items or {})
        end
    end

    local title = opts.title
    if opts.message and opts.message ~= "" then
        title = title and (title .. "\n\n" .. opts.message) or opts.message
    end

    dialog = ButtonDialog:new({
        title = title,
        title_align = "center",
        buttons = buttons,
        tap_close_callback = opts.on_dismiss,
    })
    UIManager:show(dialog)

    return {
        close = function()
            UIManager:close(dialog)
        end,
    }
end

function Sheet.show(opts)
    local module = actionSheet()
    if module then
        local ok, handle = pcall(showSimpleUI, module, opts)
        if ok then
            return handle
        end
        -- An incompatible SimpleUI version: use KOReader's dialog from now on
        require("logger").warn("Grimmory: SimpleUI action sheet failed:", handle)
        action_sheet = false
    end
    return showButtonDialog(opts)
end

--- Ask for confirmation: [Cancel] [ok_text].
---@param opts table title, icon, message, ok_text, cancel_text, ok_callback, cancel_callback
function Sheet.confirm(opts)
    if not actionSheet() then
        local ConfirmBox = require("ui/widget/confirmbox")
        local text = opts.title or ""
        if opts.message and opts.message ~= "" then
            text = text ~= "" and (text .. "\n\n" .. opts.message) or opts.message
        end
        local dialog = ConfirmBox:new({
            text = text,
            ok_text = opts.ok_text,
            cancel_text = opts.cancel_text,
            ok_callback = opts.ok_callback,
            cancel_callback = opts.cancel_callback,
        })
        UIManager:show(dialog)
        return {
            close = function()
                UIManager:close(dialog)
            end,
        }
    end

    return Sheet.show({
        title = opts.title,
        icon = opts.icon,
        message = opts.message,
        auto_close = true,
        on_dismiss = opts.cancel_callback,
        sections = {
            {
                type = "segments",
                items = {
                    { text = opts.cancel_text or _("Cancel"), callback = opts.cancel_callback },
                    { text = opts.ok_text or _("OK"), callback = opts.ok_callback },
                },
            },
        },
    })
end

return Sheet
