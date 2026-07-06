defmodule Longbridge.OAuth.TokenStorage do
  @moduledoc """
  Behaviour for persisting OAuth tokens.

  Mirrors `TokenStorage` from `longbridge/openapi` Rust SDK
  (added in 4.2.0). The default file-based implementation is
  `Longbridge.OAuth.FileTokenStorage`.

  ## Implementing a custom storage

      defmodule MyApp.RedisStorage do
        @behaviour Longbridge.OAuth.TokenStorage

        @impl true
        def load(client_id) do
          case Redix.command(:redix, ["GET", "oauth:token:\#{client_id}"]) do
            {:ok, nil} -> :error
            {:ok, json} -> {:ok, decode(json)}
            {:error, _} -> :error
          end
        end

        @impl true
        def save(client_id, token) do
          json = JSON.encode!(token)
          Redix.command(:redix, ["SET", "oauth:token:\#{client_id}", json])
          :ok
        end
      end

  Then pass it to the OAuth functions:

      Longbridge.OAuth.authorize(client_id, storage: MyApp.RedisStorage)

  The default file-based implementation is used when no storage
  option is given.

  ## Token shape

  `load/1` returns the same shape that `save/2` accepts — a map
  with at minimum `:access_token` and `:expires_at`, optionally
  `:refresh_token`, `:token_type`, `:scope`, `:user_id`,
  `:sub_accounts`, `:http_url`.
  """

  @doc """
  Loads the persisted token for `client_id`.

  Returns `{:ok, token}` on success, `{:error, reason}` on
  failure (e.g. file not found, malformed data, network error).
  """
  @callback load(String.t()) :: {:ok, map()} | {:error, term()}

  @doc """
  Persists `token` for `client_id`.

  Called after every successful authorization or refresh.
  Returns `:ok` on success, `{:error, reason}` otherwise.
  """
  @callback save(String.t(), map()) :: :ok | {:error, term()}
end
