defmodule Longbridge.ContentContext do
  @moduledoc """
  Content context.

  Provides access to news, community topics, and announcements.

  All functions accept a `Longbridge.Config` struct and return
  `{:ok, data} | {:error, reason}` tuples.

  ## Usage

      config = Longbridge.Config.new(...)

      {:ok, news} = Longbridge.ContentContext.news(config, market: "US")
  """

  alias Longbridge.{Config, HTTPClient}

  @doc """
  Lists news articles. Supports pagination.

  ## Options

  - `:market` — market filter (`"US"`, `"HK"`, `"CN"`, `"SG"`)
  - `:symbol` — filter by symbol
  - `:page` — page cursor
  - `:page_size` — results per page
  - `:lang` — language (`"zh-CN"`, `"zh-HK"`, `"en"`)
  """
  @spec news(Config.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def news(%Config{} = config, opts \\ []) do
    params = HTTPClient.build_query(opts)
    HTTPClient.request_json(:get, "/v1/content/news", "", config, params: params)
  end

  @doc """
  Lists community topics/posts. Supports pagination.

  ## Options

  - `:symbol` — filter by symbol
  - `:page` — page cursor
  - `:page_size` — results per page
  """
  @spec topics(Config.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def topics(%Config{} = config, opts \\ []) do
    params = HTTPClient.build_query(opts)
    HTTPClient.request_json(:get, "/v1/content/topics", "", config, params: params)
  end

  @doc """
  Lists company announcements.

  ## Options

  - `:symbol` — filter by symbol
  - `:page` — page cursor
  - `:page_size` — results per page
  """
  @spec announcements(Config.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def announcements(%Config{} = config, opts \\ []) do
    params = HTTPClient.build_query(opts)
    HTTPClient.request_json(:get, "/v1/content/announcements", "", config, params: params)
  end
end
