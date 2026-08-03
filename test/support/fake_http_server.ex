defmodule Longbridge.TestSupport.FakeHTTPServer do
  @moduledoc false
  # Real HTTP server for tests, backed by Bandit.
  #
  # Bandit properly manages HTTP/1.1 keep-alive, connection pooling,
  # and Content-Length framing — which a hand-rolled raw-TCP server
  # gets subtly wrong, causing tests to fail with Mint.TransportError
  # when the next request reuses a dead connection.
  #
  # Each test calls `start_with_finch/1` with a handler function
  # `(Conn.t() -> Conn.t())`. The server runs for the
  # duration of the test and is stopped via `stop_with_finch/1`.
  #
  # The per-test handler is stored in an Agent (shared across
  # Bandit's pool worker processes). `start/1` also starts a fresh
  # Finch pool whose name is stashed in the test process's dictionary
  # so `Longbridge.HTTPClient` picks it up automatically.

  alias Plug.Conn

  defmodule HandlerStore do
    @moduledoc false
    # Holds the per-test handler. An Agent (rather than :persistent_term
    # or the process dictionary) because Bandit dispatches requests in
    # its own pool worker processes, which don't share the test process's
    # dictionary and shouldn't clobber a global :persistent_term slot.
    use Agent

    def start_link(handler), do: Agent.start_link(fn -> handler end)
    def get(pid), do: Agent.get(pid, & &1)
    def set(pid, handler), do: Agent.update(pid, fn _ -> handler end)
  end

  @doc """
  Starts a real HTTP server on a random localhost port.

  `handler` is a function `(Conn.t() -> Conn.t())` called
  for every request. Returns `%{port: pos_integer(), sup: pid(),
  store: pid()}`.
  """
  @spec start((Conn.t() -> Conn.t())) :: %{
          port: pos_integer(),
          sup: pid(),
          store: pid()
        }
  def start(handler) when is_function(handler, 1) do
    {:ok, store} = HandlerStore.start_link(handler)

    port = free_port()

    # Bandit accepts a 2-arity function as a plug: `fn conn, _opts -> ... end`.
    # The handler is looked up from the Agent on each request so tests
    # can swap it via `set_handler/2`.
    plug_fn = fn conn, _opts -> call(conn, store) end

    {:ok, sup} =
      Supervisor.start_link(
        [{Bandit, plug: {plug_fn, []}, port: port}],
        strategy: :one_for_one
      )

    # Unlink so a Bandit crash (e.g. a test assertion failure inside
    # the handler) doesn't take down the test process.
    Process.unlink(sup)

    %{port: port, sup: sup, store: store}
  end

  @doc false
  # Looks up the handler from the store and delegates.
  # Wraps in try/catch so a test assertion failure inside the handler
  # (which runs in Bandit's pool worker) doesn't crash the server —
  # the exception is stashed in the store for the test to retrieve.
  def call(conn, store) do
    handler = HandlerStore.get(store)

    try do
      handler.(conn)
    catch
      kind, reason ->
        exception = Exception.normalize(kind, reason, __STACKTRACE__)
        HandlerStore.set(store, {:error, exception, __STACKTRACE__})
        Conn.send_resp(conn, 500, "test handler crashed")
    end
  end

  # Pre-created Finch names, one per concurrently-running test server.
  # Tests run sequentially, so this pool never runs dry; the whereis
  # check reuses a slot as soon as the previous server's Finch is gone.
  @finch_names for i <- 0..31, do: :"longbridge_test_finch_#{i}"
  @finch_supervisor_names for name <- @finch_names, into: %{}, do: {name, :"#{name}.Supervisor"}

  @doc """
  Starts a server AND a fresh Finch pool whose name is stored in the
  test process's dictionary so `HTTPClient` auto-picks it up.
  """
  @spec start_with_finch((Conn.t() -> Conn.t())) :: %{
          port: pos_integer(),
          sup: pid(),
          store: pid(),
          finch: atom()
        }
  def start_with_finch(handler) when is_function(handler, 1) do
    finch_name = finch_name()

    {:ok, _pid} =
      Finch.start_link(
        name: finch_name,
        pools: %{default: [size: 2, count: 1]}
      )

    Process.put(:longbridge_test_finch, finch_name)
    server = start(handler)
    Map.put(server, :finch, finch_name)
  end

  @doc """
  Stops a server started with `start/1`.
  """
  @spec stop(%{sup: pid(), store: pid()}) :: :ok
  def stop(%{sup: sup, store: store}) do
    if Process.alive?(sup), do: Supervisor.stop(sup, :shutdown)
    if Process.alive?(store), do: Agent.stop(store)
    :ok
  end

  @doc """
  Stops a server and Finch pool started with `start_with_finch/1`.
  """
  @spec stop_with_finch(%{sup: pid(), store: pid(), finch: atom()}) :: :ok
  def stop_with_finch(%{sup: sup, store: store, finch: finch_name}) do
    if Process.alive?(sup), do: Supervisor.stop(sup, :shutdown)
    if Process.alive?(store), do: Agent.stop(store)

    # Unlink before stopping: the Finch supervisor was started from the
    # test process, and a linked caller dies with the supervisor's
    # :shutdown exit signal. Stopping synchronously guarantees the name
    # slot is free before the next test reuses it.
    if finch_sup = Process.whereis(@finch_supervisor_names[finch_name]) do
      Process.unlink(finch_sup)
      Supervisor.stop(finch_sup, :shutdown)
    end

    :ok
  end

  @doc """
  Updates the handler for an already-started server. Useful for tests
  that change the response between requests.
  """
  @spec set_handler(%{store: pid()}, (Conn.t() -> Conn.t())) :: :ok
  def set_handler(%{store: store}, handler) when is_function(handler, 1) do
    HandlerStore.set(store, handler)
  end

  @doc """
  Reads the per-test Finch name from the process dictionary.
  """
  @spec current_finch() :: atom() | nil
  def current_finch, do: Process.get(:longbridge_test_finch)

  # ── Request helpers (used by tests via local defp wrappers) ──

  @doc """
  Reads a Plug.Conn's request body and returns a map with
  `:method`, `:path_with_query`, and `:body` keys — the same shape
  the old raw-TCP `parse_request/1` returned.
  """
  @spec parse_conn(Conn.t()) :: %{
          method: binary(),
          path_with_query: binary(),
          body: binary()
        }
  def parse_conn(conn) do
    {:ok, body, _conn} = Conn.read_body(conn)

    path_with_query =
      case conn.query_string do
        "" -> conn.request_path
        qs -> conn.request_path <> "?" <> qs
      end

    %{method: conn.method, path_with_query: path_with_query, body: body}
  end

  @doc """
  Sends a JSON response. Returns the updated `Plug.Conn`.
  """
  @spec json(Conn.t(), non_neg_integer(), binary() | map()) :: Conn.t()
  def json(conn, status, data) when is_binary(data) do
    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(status, data)
  end

  def json(conn, status, data) when is_map(data) do
    json(conn, status, JSON.encode!(data))
  end

  @doc """
  Convenience for a 200 JSON response.
  """
  @spec ok(Conn.t(), binary() | map()) :: Conn.t()
  def ok(conn, data), do: json(conn, 200, data)

  # ── Internal ──────────────────────────────────────────────

  defp finch_name do
    Enum.find(@finch_names, fn name ->
      # The registry (registered under `name`) and the supervisor
      # (registered under `name.Supervisor`) are the last processes to
      # unregister during teardown; check both so a crashed test that
      # skipped `stop_with_finch/1` doesn't collide with the next start.
      is_nil(Process.whereis(name)) and is_nil(Process.whereis(@finch_supervisor_names[name]))
    end) || raise "all #{length(@finch_names)} fake Finch names are in use"
  end

  defp free_port do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    port
  end
end
