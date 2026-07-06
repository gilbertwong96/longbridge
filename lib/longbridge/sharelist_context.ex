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
    body = JSON.encode!(Map.new(opts))
    HTTPClient.request_json(:post, @base, body, config, http_opts)
  end

  @doc """
  Lists sharelists owned by the current user.

  Endpoint: `GET /v1/sharelists`. Supports `:page` and `:page_size`
  pagination. Each list entry has `id`, `name`, `description`,
  `owner_id`, `created_at`, and `updated_at`.
  """
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

  @doc """
  Lists the most-followed public sharelists (curated by the
  Longbridge community).

  Endpoint: `GET /v1/sharelists/popular`. Useful for discovery when
  the user hasn't built their own list yet.
  """
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

  @doc """
  Returns the details (including the current symbol list) of a
  sharelist by id.

  Endpoint: `GET /v1/sharelists/<id>`. Returns the sharelist
  metadata plus a `symbols` array.
  """
  @spec detail(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def detail(%Config{} = config, sharelist_id, opts \\ []) do
    HTTPClient.request_json(:get, "#{@base}/#{sharelist_id}", "", config, opts)
  end

  @doc """
  Renames a sharelist.

  Endpoint: `POST /v1/sharelists/<id>`. Only the `name` field is
  updatable here; pass the new name as the third argument.
  """
  @spec rename(Config.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def rename(%Config{} = config, sharelist_id, name, opts \\ []) do
    body = JSON.encode!(%{name: name})
    HTTPClient.request_json(:post, "#{@base}/#{sharelist_id}", body, config, opts)
  end

  @doc """
  Adds one or more symbols to a sharelist.

  Endpoint: `POST /v1/sharelists/<id>/items`. Idempotent — adding a
  symbol already in the list is a no-op.
  """
  @spec add_symbols(Config.t(), String.t(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def add_symbols(%Config{} = config, sharelist_id, symbols, opts \\ []) do
    body = JSON.encode!(%{symbols: symbols})
    HTTPClient.request_json(:post, "#{@base}/#{sharelist_id}/items", body, config, opts)
  end

  @doc """
  Removes one or more symbols from a sharelist.

  Endpoint: `DELETE /v1/sharelists/<id>/items`. Removing a symbol
  that's not in the list is a no-op.
  """
  @spec remove_symbols(Config.t(), String.t(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def remove_symbols(%Config{} = config, sharelist_id, symbols, opts \\ []) do
    body = JSON.encode!(%{symbols: symbols})
    HTTPClient.request_json(:delete, "#{@base}/#{sharelist_id}/items", body, config, opts)
  end

  @doc """
  Deletes a sharelist by id.

  Endpoint: `DELETE /v1/sharelists/<id>`. Only the owner can delete;
  the server returns an error if a different account tries.
  """
  @spec delete(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def delete(%Config{} = config, sharelist_id, opts \\ []) do
    HTTPClient.request_json(:delete, "#{@base}/#{sharelist_id}", "", config, opts)
  end
end
