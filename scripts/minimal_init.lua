-- Prevent loading user config
vim.opt.runtimepath:remove(vim.fn.stdpath "config")
vim.opt.packpath:remove(vim.fn.stdpath "data")

-- Add current directory and plenary to runtime path
vim.opt.rtp:append "."
vim.opt.rtp:append(vim.fn.stdpath "data" .. "/lazy/plenary.nvim/")

-- Load plenary
vim.cmd [[runtime! plugin/plenary.vim]]
