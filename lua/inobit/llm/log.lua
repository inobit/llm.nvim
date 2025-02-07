local p_debug = vim.env.DEBUG_LLM

return require("plenary.log").new {
  plugin = "llm",
  level = p_debug or "info",
}
