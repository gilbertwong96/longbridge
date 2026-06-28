defmodule Longbridge.SharelistContext do
  @moduledoc """
  Community sharelist context.

  Manages shared watchlists: create, list, add/remove symbols,
  rename, and delete.

  All functions accept a `Longbridge.Config` struct and return
  `{:ok, data} | {:error, reason}` tuples.

  ## Usage

      config = Longbridge.Config.new(...)

      {:ok, list} = Longbridge.SharelistContext.create(config,
        name: "Tech Watch",
        symbols: ["AAPL.US", "MSFT.US", "GOOG.US"]
      )
  """

  alias Longbridge.{Config, HTTPClient}

  @base "/v1/sharelists"

  @doc """
  Creates a new sharelist.

  ## Options

  - `:name` — sharelist name (required)
  - `:description` — optional description
  - `:symbols` — initial list of symbols (default: `[]`)
  """
  @spec create(Config.t(), keyword(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(%Config{} = config, opts, http_opts \\ []) do
    body = Jason.encode!(Map.new(opts))
    HTTPClient.request_json(:post, @base, body, config, http_opts)
  end

  @doc "Lists sharelists owned by the current user."
  @spec list(Config.t(), keyword(), keyword()) :: {:ok, map()} | {:error, term()}
  def list(%Config{} = config, opts \\ [], http_opts \\ []) do
    HTTPClient.request_json(
      :get,
      @base,
      "",
      config,
      Keyword.put(http_opts, :params, HTTPClient.build_query(opts))
    )
  end

  @doc "Lists the most-followed public sharelists."
  @spec popular(Config.t(), keyword(), keyword()) :: {:ok, map()} | {:error, term()}
  def popular(%Config{} = config, opts \\ [], http_opts \\ []) do
    HTTPClient.request_json(
      :get,
      @base <> "/popular",
      "",
      config,
      Keyword.put(http_opts, :params, HTTPClient.build_query(opts))
    )
  end

  @doc "Gets the details (including symbols) of a sharelist by id."
  @spec detail(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def detail(%Config{} = config, sharelist_id, opts \\ []) do
    HTTPClient.request_json(:get, "#{@base}/#{sharelist_id}", "", config, opts)
  end

  @doc "Renames a sharelist."
  @spec rename(Config.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def rename(%Config{} = config, sharelist_id, name, opts \\ []) do
    body = Jason.encode!(%{name: name})
    HTTPClient.request_json(:post, "#{@base}/#{sharelist_id}", body, config, opts)
  end

  @doc "Adds one or more symbols to a sharelist."
  @spec add_symbols(Config.t(), String.t(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def add_symbols(%Config{} = config, sharelist_id, symbols, opts \\ []) do
    body = Jason.encode!(%{symbols: symbols})
    HTTPClient.request_json(:post, "#{@base}/#{sharelist_id}/items", body, config, opts)
  end

  @doc "Removes one or more symbols from a sharelist."
  @spec remove_symbols(Config.t(), String.t(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def remove_symbols(%Config{} = config, sharelist_id, symbols, opts \\ []) do
    body = Jason.encode!(%{symbols: symbols})
    HTTPClient.request_json(:delete, "#{@base}/#{sharelist_id}/items", body, config, opts)
  end

  @doc "Deletes a sharelist by id."
  @spec delete(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def delete(%Config{} = config, sharelist_id, opts \\ []) do
    HTTPClient.request_json(:delete, "#{@base}/#{sharelist_id}", "", config, opts)
  end
end
