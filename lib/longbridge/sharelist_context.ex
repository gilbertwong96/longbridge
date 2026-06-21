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

  @doc """
  Creates a new sharelist.

  ## Options

  - `:name` — sharelist name (required)
  - `:symbols` — initial list of symbols (default: `[]`)
  - `:description` — optional description
  """
  @spec create(Config.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(%Config{} = config, opts) do
    body = Jason.encode!(Map.new(opts))
    HTTPClient.request_json(:post, "/v1/sharelist/create", body, config)
  end

  @doc "Lists all sharelists owned by the current user."
  @spec list(Config.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def list(%Config{} = config, opts \\ []) do
    HTTPClient.request_json(:get, "/v1/sharelist/list", "", config,
      params: HTTPClient.build_query(opts)
    )
  end

  @doc "Gets the symbols in a specific sharelist by `sharelist_id`."
  @spec detail(Config.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def detail(%Config{} = config, sharelist_id) do
    HTTPClient.request_json(:get, "/v1/sharelist/detail", "", config,
      params: "sharelist_id=#{sharelist_id}"
    )
  end

  @doc "Renames a sharelist."
  @spec rename(Config.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def rename(%Config{} = config, sharelist_id, name) do
    body = Jason.encode!(%{sharelist_id: sharelist_id, name: name})
    HTTPClient.request_json(:post, "/v1/sharelist/rename", body, config)
  end

  @doc "Adds one or more symbols to a sharelist."
  @spec add_symbols(Config.t(), String.t(), [String.t()]) ::
          {:ok, map()} | {:error, term()}
  def add_symbols(%Config{} = config, sharelist_id, symbols) do
    body = Jason.encode!(%{sharelist_id: sharelist_id, symbols: symbols})
    HTTPClient.request_json(:post, "/v1/sharelist/add_symbols", body, config)
  end

  @doc "Removes one or more symbols from a sharelist."
  @spec remove_symbols(Config.t(), String.t(), [String.t()]) ::
          {:ok, map()} | {:error, term()}
  def remove_symbols(%Config{} = config, sharelist_id, symbols) do
    body = Jason.encode!(%{sharelist_id: sharelist_id, symbols: symbols})
    HTTPClient.request_json(:post, "/v1/sharelist/remove_symbols", body, config)
  end

  @doc "Deletes a sharelist by `sharelist_id`."
  @spec delete(Config.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def delete(%Config{} = config, sharelist_id) do
    body = Jason.encode!(%{sharelist_id: sharelist_id})
    HTTPClient.request_json(:post, "/v1/sharelist/delete", body, config)
  end
end
