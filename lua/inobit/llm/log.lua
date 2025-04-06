local p_debug = vim.env.DEBUG_LLM

return require("plenary.log").new {
  plugin = "llm",
  use_console = false,
  level = p_debug or "info",
}
