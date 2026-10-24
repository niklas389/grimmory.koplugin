local assert = require 'luassert'

package.path = "grimmory.koplugin/?.lua;" .. package.path

local shown, closed

local function reset_fakes()
    shown, closed = {}, {}

    package.loaded["grimmory/ui/sheet"] = nil
    package.loaded["engines/sui_action_sheet"] = nil
    package.preload["engines/sui_action_sheet"] = nil

    package.loaded["gettext"] = function(text) return text end
    package.loaded["logger"] = { warn = function() end }
    package.loaded["ui/uimanager"] = {
        show = function(_, widget) table.insert(shown, widget) end,
        close = function(_, widget) table.insert(closed, widget) end,
    }

    local function widget_class()
        return {
            new = function(_, o)
                return o
            end,
        }
    end
    package.loaded["ui/widget/buttondialog"] = widget_class()
    package.loaded["ui/widget/confirmbox"] = widget_class()
end

--- SimpleUI's action sheet, remembering what it was asked to show
local function fake_action_sheet()
    local fake = { opts = nil, closed = false }
    fake.show = function(opts)
        fake.opts = opts
        return { close = function() fake.closed = true end }
    end
    package.preload["engines/sui_action_sheet"] = function() return fake end
    return fake
end

describe("Sheet", function()
    before_each(reset_fakes)

    -- Leave no fakes behind for other spec files
    teardown(function()
        for _, name in ipairs({
            "gettext", "logger", "ui/uimanager", "ui/widget/buttondialog", "ui/widget/confirmbox",
            "engines/sui_action_sheet", "grimmory/ui/sheet",
        }) do
            package.loaded[name] = nil
        end
        package.preload["engines/sui_action_sheet"] = nil
    end)

    describe("without SimpleUI", function()
        it("shows the sections as a ButtonDialog, marking chosen items", function()
            local Sheet = require("grimmory/ui/sheet")

            Sheet.show({
                title = "Library",
                message = "Choose",
                sections = {
                    { type = "segments", items = { { text = "Grid", selected = true }, { text = "List" } } },
                    Sheet.list({ { text = "Refresh" }, { text = "Sync", checked = true } }),
                },
            })

            local dialog = shown[1]
            assert.are.equal("Library\n\nChoose", dialog.title)
            assert.are.equal(3, #dialog.buttons)
            assert.are.equal("✓ Grid", dialog.buttons[1][1].text)
            assert.are.equal("List", dialog.buttons[1][2].text)
            assert.are.equal("Refresh", dialog.buttons[2][1].text)
            assert.are.equal("✓ Sync", dialog.buttons[3][1].text)
        end)

        it("closes the dialog before an action when auto_close is set", function()
            local Sheet = require("grimmory/ui/sheet")
            local order = {}

            Sheet.show({
                auto_close = true,
                sections = { Sheet.list({ { text = "Go", callback = function()
                    table.insert(order, #closed == 1 and "closed first" or "not closed")
                end } }) },
            })
            shown[1].buttons[1][1].callback()

            assert.are.same({ "closed first" }, order)
        end)

        it("asks for confirmation with a ConfirmBox", function()
            local Sheet = require("grimmory/ui/sheet")
            local confirmed = false

            Sheet.confirm({
                title = "Delete?",
                message = "It is removed.",
                ok_text = "Delete",
                ok_callback = function() confirmed = true end,
            })

            assert.are.equal("Delete?\n\nIt is removed.", shown[1].text)
            assert.are.equal("Delete", shown[1].ok_text)
            shown[1].ok_callback()
            assert.is_true(confirmed)
        end)
    end)

    describe("with SimpleUI", function()
        it("uses SimpleUI's action sheet", function()
            local fake = fake_action_sheet()
            local Sheet = require("grimmory/ui/sheet")

            assert.is_true(Sheet.isSimpleUI())
            Sheet.show({ title = "Library", icon = "library", sections = { Sheet.list({ { text = "Refresh" } }) } })

            assert.are.equal("Library", fake.opts.title)
            assert.are.equal("library", fake.opts.icon)
            assert.are.equal("Refresh", fake.opts.sections[1].rows[1][1].text)
            assert.are.equal(0, #shown)
        end)

        it("closes the sheet before an action, also for items without one", function()
            local fake = fake_action_sheet()
            local Sheet = require("grimmory/ui/sheet")
            local ran = false
            local item = { text = "Go", callback = function() ran = fake.closed end }

            Sheet.show({
                auto_close = true,
                sections = { { type = "segments", items = { { text = "Close" }, item } } },
            })
            local items = fake.opts.sections[1].items

            items[2].callback()
            assert.is_true(ran)

            fake.closed = false
            items[1].callback()
            assert.is_true(fake.closed)

            -- The caller's item is not changed
            assert.are_not.equal(item.callback, items[2].callback)
        end)

        it("confirms with Cancel and the action as segments", function()
            local fake = fake_action_sheet()
            local Sheet = require("grimmory/ui/sheet")
            local confirmed = false

            Sheet.confirm({ title = "Delete?", ok_text = "Delete", ok_callback = function() confirmed = true end })

            local items = fake.opts.sections[1].items
            assert.are.equal("Cancel", items[1].text)
            assert.are.equal("Delete", items[2].text)
            items[2].callback()
            assert.is_true(confirmed)
            assert.is_true(fake.closed)
        end)

        it("falls back to KOReader's dialog when SimpleUI's sheet fails", function()
            package.preload["engines/sui_action_sheet"] = function()
                return { show = function() error("incompatible") end }
            end
            local Sheet = require("grimmory/ui/sheet")

            Sheet.show({ title = "Library", sections = { Sheet.list({ { text = "Refresh" } }) } })

            assert.are.equal("Library", shown[1].title)
            assert.is_false(Sheet.isSimpleUI())
        end)
    end)
end)
