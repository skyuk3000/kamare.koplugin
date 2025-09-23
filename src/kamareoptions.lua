local _ = require("gettext")

local KamareOptions = {
    prefix = "kamare",
    {
        icon = "appbar.pagefit",
        options = {
            {
                name = "zoom_mode_type",
                name_text = _("Fit"),
                toggle = {_("full"), _("width"), _("height")},
                alternate = false,
                values = {2, 1, 0},
                default_value = 2,
                event = "DefineZoom",
                args = {"full", "width", "height"},
                help_text = _([[Set how the page should be resized to fit the screen.]]),
            }
        }
    },
    {
        icon = "appbar.settings",
        options = {
            {
                name = "footer_mode",
                name_text = _("Footer Display"),
                toggle = {_("Off"), _("Progress"), _("Pages left"), _("Time")},
                values = {0, 1, 2, 3},
                args = {0, 1, 2, 3},
                event = "SetFooterMode",
                help_text = _("Choose what information to display in the footer."),
            }
        }
    }
}

return KamareOptions
