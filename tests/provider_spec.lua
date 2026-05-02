local config = require "inobit.llm.config"
local log = require "inobit.llm.log"

describe("Provider Manager", function()
  local test_provider_url = "http://localhost:8000/ai_stream"

  before_each(function()
    vim.fn.setenv("TEST_API_KEY", "test-api-key")
    vim.fn.setenv("OPENROUTER_API_KEY", "test-or-key")
  end)

  after_each(function()
    vim.fn.setenv("TEST_API_KEY", nil)
    vim.fn.setenv("OPENROUTER_API_KEY", nil)
  end)

  describe("new config format", function()
    it("should store providers keyed by provider name", function()
      config.setup {
        providers = {
          TestProvider = {
            base_url = test_provider_url,
            api_key_name = "TEST_API_KEY",
            supports_scenarios = "all",
            default_model = "test-model",
            params = { temperature = 0.5 },
          },
        },
        scenario_defaults = {
          chat = "TestProvider",
        },
      }

      assert.is_table(config.providers)
      assert.is_table(config.providers.TestProvider)
      assert.equals(test_provider_url, config.providers.TestProvider.base_url)
      assert.equals("test-model", config.providers.TestProvider.default_model)
    end)

    it("should support model_overrides", function()
      config.setup {
        providers = {
          TestProvider = {
            base_url = test_provider_url,
            api_key_name = "TEST_API_KEY",
            supports_scenarios = "all",
            default_model = "model-a",
            params = { temperature = 0.6 },
            model_overrides = {
              ["model-a"] = { temperature = 0.4 },
              ["model-b"] = { temperature = 0.8, max_tokens = 8192 },
            },
          },
        },
        scenario_defaults = {
          chat = "TestProvider",
        },
      }

      local entry = config.providers.TestProvider
      assert.is_table(entry.model_overrides)
      assert.equals(0.4, entry.model_overrides["model-a"].temperature)
      assert.equals(0.8, entry.model_overrides["model-b"].temperature)
      assert.equals(8192, entry.model_overrides["model-b"].max_tokens)
    end)

    it("should merge user providers with defaults", function()
      config.setup {
        providers = {
          OpenRouter = {
            default_model = "custom-model",
            params = { temperature = 0.3 },
          },
        },
        scenario_defaults = {
          chat = "OpenRouter",
        },
      }

      local entry = config.providers.OpenRouter
      -- Should have default values
      assert.equals("https://openrouter.ai/api/v1", entry.base_url)
      assert.equals("OPENROUTER_API_KEY", entry.api_key_name)
      assert.equals("all", entry.supports_scenarios)
      -- Should have user override
      assert.equals(0.3, entry.params.temperature)
      assert.equals("custom-model", entry.default_model)
    end)

    it("should support fetch_models flag", function()
      config.setup {
        providers = {
          TestProvider = {
            base_url = test_provider_url,
            api_key_name = "TEST_API_KEY",
            supports_scenarios = "all",
            default_model = "test-model",
            fetch_models = true,
          },
        },
        scenario_defaults = {
          chat = "TestProvider",
        },
      }

      assert.is_true(config.providers.TestProvider.fetch_models)
    end)

    it("should support model_overrides with string array format", function()
      -- User can add model_overrides as simple string array
      config.setup {
        providers = {
          OpenRouter = {
            model_overrides = {
              "anthropic/claude-opus-4",
              "anthropic/claude-sonnet-4",
            },
          },
        },
        scenario_defaults = {
          chat = "OpenRouter",
        },
      }

      local entry = config.providers.OpenRouter
      assert.is_table(entry.model_overrides)
      -- String array format should be normalized to empty tables
      local normalized = config.normalize_model_overrides(entry.model_overrides)
      assert.is_table(normalized["anthropic/claude-opus-4"])
      assert.is_table(normalized["anthropic/claude-sonnet-4"])
    end)
  end)

  describe("resolve_provider", function()
    local provider

    before_each(function()
      vim.fn.setenv("TEST_API_KEY", "test-api-key")
      config.setup {
        providers = {
          OpenRouter = {
            default_model = "openai/gpt-4.5",
            params = { temperature = 0.6 },
            model_overrides = {
              ["model-a"] = { temperature = 0.4 },
              ["model-b"] = { temperature = 0.8, max_tokens = 8192 },
            },
          },
        },
        scenario_defaults = {
          chat = "OpenRouter",
        },
      }
      -- Reset the provider module to pick up new config
      package.loaded["inobit.llm.provider"] = nil
      provider = require "inobit.llm.provider"
    end)

    after_each(function()
      vim.fn.setenv("TEST_API_KEY", nil)
    end)

    it("should resolve provider with merged config", function()
      local resolved = provider:resolve_provider("OpenRouter", "model-a")

      assert.is_table(resolved)
      assert.equals("OpenRouter", resolved.provider)
      assert.equals("model-a", resolved.model)
      assert.equals("https://openrouter.ai/api/v1", resolved.base_url)
      assert.equals("OPENROUTER_API_KEY", resolved.api_key_name)
      -- Should have model override temperature
      assert.equals(0.4, resolved.params.temperature)
    end)

    it("should cache resolved providers", function()
      local resolved1 = provider:resolve_provider("OpenRouter", "model-a")
      local resolved2 = provider:resolve_provider("OpenRouter", "model-a")

      -- Should return the same cached instance
      assert.is_true(resolved1 == resolved2)
    end)

    it("should resolve provider without model_overrides", function()
      local resolved = provider:resolve_provider("OpenRouter", "unknown-model")

      assert.is_table(resolved)
      assert.equals("OpenRouter", resolved.provider)
      assert.equals("unknown-model", resolved.model)
      -- Should use base provider config temperature (no override)
      assert.equals(0.6, resolved.params.temperature)
    end)

    it("should error on unknown provider", function()
      assert.has_error(function()
        provider:resolve_provider("UnknownProvider", "some-model")
      end, "Unknown provider: UnknownProvider")
    end)

    it("should return OpenRouterProvider for OpenRouter provider", function()
      local resolved = provider:resolve_provider("OpenRouter", "anthropic/claude-opus-4")

      assert.is_table(resolved)
      assert.equals("OpenRouter", resolved.provider)
      assert.equals("anthropic/claude-opus-4", resolved.model)
      -- Should be an OpenRouterProvider instance
      assert.is_function(resolved.build_request_opts)
    end)

    it("should set scenario_providers from config", function()
      -- Verify scenario_providers is set correctly
      assert.is_table(provider.scenario_providers)
      assert.is_table(provider.scenario_providers.chat)
      assert.equals("OpenRouter", provider.scenario_providers.chat.provider)
    end)

    it("should support scenario-specific models", function()
      config.setup {
        providers = {
          OpenRouter = {
            default_model = "default-model",
            scenario_models = {
              chat = "chat-model",
              translate = "translate-model",
            },
          },
        },
        scenario_defaults = {
          chat = "OpenRouter",
          translate = "OpenRouter",
        },
      }
      -- Reset the provider module
      package.loaded["inobit.llm.provider"] = nil
      local test_provider = require "inobit.llm.provider"

      -- Check that scenario providers are set
      assert.is_table(test_provider.scenario_providers.chat)
      assert.equals("OpenRouter", test_provider.scenario_providers.chat.provider)
    end)
  end)

  describe("provider_supports_scenario", function()
    local provider

    before_each(function()
      config.setup {
        providers = {
          -- Use existing registered providers for testing
          OpenRouter = {
            base_url = "https://openrouter.ai/api/v1",
            api_key_name = "OPENROUTER_API_KEY",
            supports_scenarios = { "chat" },
            default_model = "chat-model",
          },
          DeepL = {
            base_url = "https://api-free.deepl.com/v2",
            api_key_name = "DEEPL_API_KEY",
            supports_scenarios = { "translate" },
            default_model = "deepl",
          },
        },
        scenario_defaults = {
          chat = "OpenRouter",
          translate = "DeepL",
        },
      }
      package.loaded["inobit.llm.provider"] = nil
      provider = require "inobit.llm.provider"
    end)

    it("should return true for chat scenario with chat provider", function()
      assert.is_true(provider:provider_supports_scenario("OpenRouter", "chat"))
    end)

    it("should return false for translate scenario with chat-only provider", function()
      assert.is_false(provider:provider_supports_scenario("OpenRouter", "translate"))
    end)

    it("should return true for translate scenario with translate provider", function()
      assert.is_true(provider:provider_supports_scenario("DeepL", "translate"))
    end)

    it("should return true for all scenarios with all-supporting provider", function()
      -- Aliyun supports all scenarios by default
      assert.is_true(provider:provider_supports_scenario("Aliyun", "chat"))
      assert.is_true(provider:provider_supports_scenario("Aliyun", "translate"))
    end)

    it("should get providers for specific scenario", function()
      local chat_providers = provider:get_providers_for_scenario("chat")
      assert.is_table(chat_providers)
      -- Should include OpenRouter (chat-only) and Aliyun (all scenarios)
      assert.is_true(vim.tbl_contains(chat_providers, "OpenRouter"))
      assert.is_true(vim.tbl_contains(chat_providers, "Aliyun"))
      -- Should not include DeepL (translate-only)
      assert.is_false(vim.tbl_contains(chat_providers, "DeepL"))
    end)
  end)
end)
