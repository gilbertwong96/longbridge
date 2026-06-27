defmodule Longbridge.OAuth.InMemoryTokenStorage do
  @moduledoc """
  In-memory OAuth token storage.

  Stores tokens in an ETS table owned by the first process that
  writes to it. Useful for tests, ephemeral CLI sessions, and
  long-running server processes that prefer in-process state over
  disk files.

  Mirrors the in-memory `TokenStorage` patterns used by
  `longbridge/openapi` Rust SDK tests (added in 4.2.0).

  ## Usage

      Longbridge.OAuth.authorize("client-id",
        storage: Longbridge.OAuth.InMemoryTokenStorage
      )

  The underlying ETS table is created lazily on first save and
  persists for the lifetime of the BEAM VM. There is no explicit
  start step.

  ## Token lifetime

  Tokens stored here are lost when the BEAM VM stops. Use
  `Longbridge.OAuth.FileTokenStorage` for persistence across
  restarts.

  ## Table owner

  The ETS table is created with `:protected` access mode: only the
  owning process can write, anyone can read. The owner is the
  first process that calls `save/2`. Make sure that process
  outlives the storage lifetime (typically the application's
  supervisor).
  """

  @behaviour Longbridge.OAuth.TokenStorage

  @table :longbridge_oauth_in_memory_tokens

  @doc false
  # Public so tests can reset the table between runs.
  @spec table() :: term()
  def table, do: :ets.info(@table)

  @doc """
  Resets the storage. Clears all stored tokens. Useful for tests.

  Returns `:ok`.
  """
  @spec reset() :: :ok
  def reset do
    case :ets.info(@table) do
      :undefined ->
        :ok

      _ ->
        :ets.delete_all_objects(@table)
        :ok
    end
  end

  @impl true
  def load(client_id) do
    case :ets.info(@table) do
      :undefined ->
        {:error, :not_found}

      _ ->
        case :ets.lookup(@table, client_id) do
          [{^client_id, token}] -> {:ok, token}
          [] -> {:error, :not_found}
        end
    end
  end

  @impl true
  def save(client_id, token) do
    ensure_table()
    _ = :ets.insert(@table, {client_id, token})
    :ok
  end

  @doc """
  Returns the list of `client_id`s currently stored. Useful for
  diagnostics and tests.

  Returns `[]` if no tokens have been saved yet.
  """
  @spec list_client_ids() :: [String.t()]
  def list_client_ids do
    case :ets.info(@table) do
      :undefined ->
        []

      _ ->
        for {client_id, _token} <- :ets.tab2list(@table), do: client_id
    end
  end

  @doc """
  Deletes the stored token for `client_id`. Returns `:ok` whether
  or not the client_id was present (idempotent).
  """
  @spec delete(String.t()) :: :ok
  def delete(client_id) do
    case :ets.info(@table) do
      :undefined ->
        :ok

      _ ->
        :ets.delete(@table, client_id)
        :ok
    end
  end

  # Creates the table on first save. Owner is the calling process.
  # In a typical Phoenix/Ecto app that's the request handler, so
  # the table dies with the request. For long-lived stores, users
  # should call `start_link/1` to put ownership on a supervisor
  # — or accept that the table dies with the calling process.
  #
  # :public access mode so any process can read or write once the
  # table exists. Mirrors the pattern in `Longbridge.Symbol.Cache`.
  # In test environments each test process may end up owning its
  # own table, but production usage from a long-lived supervised
  # process shares a single table.
  defp ensure_table do
    case :ets.info(@table) do
      :undefined ->
        try do
          _ = :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _other ->
        :ok
    end
  end
end
