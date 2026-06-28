defmodule Longbridge.AssetContext do
  @moduledoc """
  Account statement context.

  Provides access to Longbridge account statement data (daily and monthly
  statements) and statement file download URLs.

  All functions accept a `Longbridge.Config` struct and return
  `{:ok, data} | {:error, reason}` tuples.

  ## Usage

      config = Longbridge.Config.new(...)

      {:ok, statements} = Longbridge.AssetContext.statements(config, :daily)
      {:ok, url} = Longbridge.AssetContext.download_url(config, "file-key-abc")
  """

  alias Longbridge.{Config, HTTPClient}

  @type statement_type :: :daily | :monthly

  @doc """
  Lists account statements.

  ## Options

  - `:type` — `:daily` (default) or `:monthly`
  - `:page` — page cursor for pagination (integer)
  - `:page_size` — results per page (default: 20)

  Returns `{:ok, %{"list" => [%{"dt" => date_int, "file_key" => key}]}}`
  or `{:error, reason}`.
  """
  @spec statements(Config.t(), keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def statements(%Config{} = config, opts \\ [], http_opts \\ []) do
    st = if Keyword.get(opts, :type) == :monthly, do: 2, else: 1

    params =
      HTTPClient.build_query(
        statement_type: st,
        page: Keyword.get(opts, :page),
        page_size: Keyword.get(opts, :page_size)
      )

    HTTPClient.request_json(
      :get,
      "/v1/statement/list",
      "",
      config,
      Keyword.put(http_opts, :params, params)
    )
  end

  @doc """
  Gets a presigned download URL for a statement file.

  `file_key` comes from the `statements/2` response.
  """
  @spec download_url(Config.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def download_url(%Config{} = config, file_key, opts \\ []) when is_binary(file_key) do
    params = "file_key=#{URI.encode_www_form(file_key)}"

    HTTPClient.request_json(
      :get,
      "/v1/statement/download",
      "",
      config,
      Keyword.put(opts, :params, params)
    )
  end
end
