local M = {}

-- Import all submodules and export their contents
local stack = require "inobit.llm.ui.stack"
local base = require "inobit.llm.ui.base"
local chat = require "inobit.llm.ui.chat"
local picker = require "inobit.llm.ui.picker"
local padding = require "inobit.llm.ui.padding"

-- Export WinStack
M.WinStack = stack.WinStack

-- Export BaseWin, FloatingWin, SplitWin
M.BaseWin = base.BaseWin
M.FloatingWin = base.FloatingWin
M.SplitWin = base.SplitWin

-- Export ChatWin classes
M.BaseChatWin = chat.BaseChatWin
M.FloatChatWin = chat.FloatChatWin
M.SplitChatWin = chat.SplitChatWin

-- Export PickerWin classes
M.PickerWin = picker.PickerWin
M.DualPickerWin = picker.DualPickerWin

-- Export PaddingFloatingWin
M.PaddingFloatingWin = padding.PaddingFloatingWin

return M
