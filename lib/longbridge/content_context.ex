defmodule Longbridge.ContentContext do
  @moduledoc """
  Content context.

  Provides access to community topics and per-symbol news. Both endpoints
  take a stock symbol; for browsing all-symbol news or announcements use
  the upstream Longbridge web app.

  All functions accept a `Longbridge.Config` struct and return
  `{:ok, data} | {:error, reason}` tuples.

  ## Usage

      config = Longbridge.Config.new(...)

      {:ok, news} = Longbridge.ContentContext.news(config, "AAPL.US")
  """

  alias Longbridge.{Config, HTTPClient}

  @doc """
  Lists news articles for a symbol.

  `symbol` is required (e.g. `"AAPL.US"`, `"700.HK"`).

  ## Options

  - `:lang` — language (`"zh-CN"`, `"zh-HK"`, `"en"`)
  """
  @spec news(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def news(%Config{} = config, symbol, opts \\ []) when is_binary(symbol) do
    params = HTTPClient.build_query(opts)
    HTTPClient.request_json(:get, "/v1/content/#{symbol}/news", "", config, params: params)
  end

  @doc """
  Lists community topics for a symbol.

  `symbol` is required.

  ## Options

  - `:page` — page cursor
  - `:page_size` — results per page
  """
  @spec topics(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def topics(%Config{} = config, symbol, opts \\ []) when is_binary(symbol) do
    params = HTTPClient.build_query(opts)
    HTTPClient.request_json(:get, "/v1/content/#{symbol}/topics", "", config, params: params)
  end

  @doc """
  Lists company announcements for a symbol.

  The upstream OpenAPI does not currently expose announcements as a REST
  endpoint; the topic listing (`topics/2`) is the closest equivalent.

  Returns `{:error, :not_implemented}` to make the absence explicit.
  """
  @spec announcements(Config.t(), String.t()) :: {:error, :not_implemented}
  def announcements(%Config{}, _symbol), do: {:error, :not_implemented}
end
