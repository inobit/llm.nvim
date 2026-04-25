local config = require "inobit.llm.config"
local log = require "inobit.llm.log"

describe("Provider Manager", function()
  local test_provider_url = "http://localhost:8000/ai_stream"

  before_each(function()
    vim.fn.setenv("TEST_API_KEY", "test-api-key")
  end)

  after_each(function()
    vim.fn.setenv("TEST_API_KEY", nil)
  end)

  describe("new config format", function()
    it("should store providers keyed by provider name", function()
      config.setup {
        providers = {
          TestProvider = {
            provider = "TestProvider",
            base_url = test_provider_url,
            api_key_name = "TEST_API_KEY",
            provider_type = "chat",
            default_model = "test-model",
            temperature = 0.5,
          },
        },
        default_provider = "TestProvider", -- Just provider name
      }

      assert.is_table(config.providers)
      assert.is_table(config.providers.TestProvider)
      assert.equals("TestProvider", config.providers.TestProvider.provider)
      assert.equals(test_provider_url, config.providers.TestProvider.base_url)
      assert.equals("test-model", config.providers.TestProvider.default_model)
    end)

    it("should support model_overrides", function()
      config.setup {
        providers = {
          TestProvider = {
            provider = "TestProvider",
            base_url = test_provider_url,
            api_key_name = "TEST_API_KEY",
            provider_type = "chat",
            default_model = "model-a",
            temperature = 0.6,
            model_overrides = {
              ["model-a"] = { temperature = 0.4 },
              ["model-b"] = { temperature = 0.8, max_tokens = 8192 },
            },
          },
        },
        default_provider = "TestProvider", -- Just provider name
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
            temperature = 0.3,
          },
        },
        default_provider = "OpenRouter", -- Just provider name
      }

      local entry = config.providers.OpenRouter
      -- Should have default values
      assert.equals("https://openrouter.ai/api/v1", entry.base_url)
      assert.equals("OPENROUTER_API_KEY", entry.api_key_name)
      assert.equals("chat", entry.provider_type)
      -- Should have user override
      assert.equals(0.3, entry.temperature)
      assert.equals("custom-model", entry.default_model)
    end)

    it("should support fetch_models flag", function()
      config.setup {
        providers = {
          TestProvider = {
            provider = "TestProvider",
            base_url = test_provider_url,
            api_key_name = "TEST_API_KEY",
            provider_type = "chat",
            default_model = "test-model",
            fetch_models = true,
          },
        },
        default_provider = "TestProvider", -- Just provider name
      }

      assert.is_true(config.providers.TestProvider.fetch_models)
    end)

    it("should support default_providers with model_overrides", function()
      -- User can add model_overrides to default providers
      config.setup {
        providers = {
          OpenRouter = {
            model_overrides = {
              ["anthropic/claude-opus-4"] = { temperature = 0.4 },
            },
          },
        },
        default_provider = "OpenRouter",
      }

      local entry = config.providers.OpenRouter
      assert.is_table(entry.model_overrides)
      assert.is_table(entry.model_overrides["anthropic/claude-opus-4"])
      assert.equals(0.4, entry.model_overrides["anthropic/claude-opus-4"].temperature)
    end)
  end)

  describe("resolve_provider", function()
    local provider = require "inobit.llm.provider"

    before_each(function()
      vim.fn.setenv("TEST_API_KEY", "test-api-key")
      config.setup {
        providers = {
          TestProvider = {
            provider = "TestProvider",
            base_url = test_provider_url,
            api_key_name = "TEST_API_KEY",
            provider_type = "chat",
            default_model = "default-model",
            temperature = 0.6,
            model_overrides = {
              ["model-a"] = { temperature = 0.4 },
              ["model-b"] = { temperature = 0.8, max_tokens = 8192 },
            },
          },
          OpenRouter = {
            provider = "OpenRouter",
            default_model = "openai/gpt-4.5",
          },
        },
        default_provider = "TestProvider", -- Just provider name
      }
      -- Reset the provider module to pick up new config
      package.loaded["inobit.llm.provider"] = nil
      provider = require "inobit.llm.provider"
    end)

    after_each(function()
      vim.fn.setenv("TEST_API_KEY", nil)
    end)

    it("should resolve provider with merged config", function()
      local resolved = provider:resolve_provider("TestProvider", "model-a")

      assert.is_table(resolved)
      assert.equals("TestProvider", resolved.provider)
      assert.equals("model-a", resolved.model)
      assert.equals(test_provider_url, resolved.base_url)
      assert.equals("TEST_API_KEY", resolved.api_key_name)
      -- Should have model override temperature
      assert.equals(0.4, resolved.temperature)
      -- Should NOT have model_overrides in resolved config
      assert.is_nil(resolved.model_overrides)
    end)

    it("should cache resolved providers", function()
      local resolved1 = provider:resolve_provider("TestProvider", "model-a")
      local resolved2 = provider:resolve_provider("TestProvider", "model-a")

      -- Should return the same cached instance
      assert.is_true(resolved1 == resolved2)
    end)

    it("should resolve provider without model_overrides", function()
      local resolved = provider:resolve_provider("TestProvider", "unknown-model")

      assert.is_table(resolved)
      assert.equals("TestProvider", resolved.provider)
      assert.equals("unknown-model", resolved.model)
      -- Should use base provider config temperature (no override)
      assert.equals(0.6, resolved.temperature)
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

    it("should set default_provider from config", function()
      -- Verify default_provider is set correctly
      assert.is_table(provider.default_provider)
      assert.equals("TestProvider", provider.default_provider.provider)
      assert.equals("default-model", provider.default_provider.model)

      -- Verify chat_provider defaults to default_provider
      assert.is_table(provider.chat_provider)
      assert.equals("TestProvider", provider.chat_provider.provider)

      -- Verify translate_provider defaults to default_provider
      assert.is_table(provider.translate_provider)
      assert.equals("TestProvider", provider.translate_provider.provider)
    end)

    it("should set separate chat_provider and translate_provider", function()
      config.setup {
        providers = {
          ChatProvider = {
            provider = "ChatProvider",
            base_url = test_provider_url,
            api_key_name = "TEST_API_KEY",
            provider_type = "chat",
            default_model = "chat-model",
          },
          TranslateProvider = {
            provider = "TranslateProvider",
            base_url = test_provider_url,
            api_key_name = "TEST_API_KEY",
            provider_type = "translate",
            default_model = "translate-model",
          },
        },
        default_provider = "ChatProvider",
        default_chat_provider = "ChatProvider",
        default_translate_provider = "TranslateProvider",
      }
      -- Reset the provider module to pick up new config
      package.loaded["inobit.llm.provider"] = nil
      provider = require "inobit.llm.provider"

      assert.equals("ChatProvider", provider.default_provider.provider)
      assert.equals("chat-model", provider.default_provider.model)
      assert.equals("ChatProvider", provider.chat_provider.provider)
      assert.equals("chat-model", provider.chat_provider.model)
      assert.equals("TranslateProvider", provider.translate_provider.provider)
      assert.equals("translate-model", provider.translate_provider.model)
    end)
  end)

  -- NOTE: ProviderManager integration tests will be added in Task 11/12
  -- after ProviderManager refactoring (Task 4/5) is complete
end)
