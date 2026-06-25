defmodule Longbridge.Connection.SessionTest do
  use ExUnit.Case, async: true

  alias Longbridge.Config
  alias Longbridge.Connection.Session

  defp base_state(opts \\ []) do
    config = Config.new(token: "tok")
    parent = self()

    Map.merge(
      %{
        config: config,
        type: :quote,
        host: "127.0.0.1",
        port: 1234,
        socket: nil,
        session_id: nil,
        expires: nil,
        request_id: 0,
        pending: %{},
        subscribers: MapSet.new([parent]),
        buffer: <<>>,
        connection_state: :disconnected,
        reconnect_attempts: 0,
        reconnect_timer: nil,
        idle_timer: nil,
        refresh_token_fn: fn _cfg -> {:ok, %{token: "new"}} end
      },
      Map.new(opts)
    )
  end

  describe "next_request_id/1" do
    test "increments the counter" do
      assert Session.next_request_id(%{request_id: 0}) == 1
      assert Session.next_request_id(%{request_id: 41}) == 42
    end
  end

  describe "broadcast/2" do
    test "sends {:longbridge, self(), message} to every subscriber" do
      s1 = self()
      s2 = spawn(fn -> :ok end)

      state = base_state(subscribers: MapSet.new([s1, s2]))

      assert :ok = Session.broadcast(state, {:hello, 1})
      assert_received {:longbridge, ^s1, {:hello, 1}}
    end
  end

  describe "fail_pending_requests/2" do
    test "returns :ok and replies with error to each pending caller" do
      test_pid = self()

      fake_caller =
        spawn(fn ->
          send(test_pid, :ready)

          receive do
            {_ref, value} -> send(test_pid, {:got, value})
          after
            1_000 -> :ok
          end
        end)

      receive do
        :ready -> :ok
      end

      ref = make_ref()
      tagged_from = {fake_caller, ref}

      state = base_state(pending: %{1 => %{from: tagged_from, ref: nil}})
      assert :ok = Session.fail_pending_requests(state, :closed)

      assert_receive {:got, {:error, {:disconnected, :closed}}}, 500
    end
  end

  describe "schedule_idle_timer/1 + cancel_idle_timer/1" do
    test "schedules a timer when idle_timeout > 0 and clears it on cancel" do
      initial = base_state(config: Config.new(token: "x", idle_timeout: 100))
      assert initial.idle_timer == nil

      scheduled = Session.schedule_idle_timer(initial)
      assert is_reference(scheduled.idle_timer)

      cancelled = Session.cancel_idle_timer(scheduled)
      assert cancelled.idle_timer == nil
    end

    test "no-op when idle_timeout is 0" do
      state = base_state(config: Config.new(token: "x", idle_timeout: 0))
      assert Session.schedule_idle_timer(state) == state
    end
  end

  describe "schedule_reconnect/2" do
    test "increments reconnect_attempts and sets a timer" do
      initial = base_state(reconnect_attempts: 2)
      result = Session.schedule_reconnect(initial, :closed)
      assert result.reconnect_attempts == 3
      assert is_reference(result.reconnect_timer)
    end

    test "gives up after max attempts and broadcasts :reconnect_exhausted" do
      result =
        Session.schedule_reconnect(
          base_state(reconnect_attempts: 10, subscribers: MapSet.new([self()])),
          :closed
        )

      assert result.reconnect_attempts == 10
      assert result.reconnect_timer == nil
      assert_received {:longbridge, _pid, :reconnect_exhausted}
    end
  end

  describe "cancel_reconnect_timer/1" do
    test "cancels the reconnect timer if set" do
      state = Session.schedule_reconnect(base_state(), :closed)
      assert is_reference(state.reconnect_timer)
      assert :ok = Session.cancel_reconnect_timer(state)
    end

    test "no-op when no reconnect timer" do
      assert :ok = Session.cancel_reconnect_timer(base_state())
    end
  end

  describe "do_auth_with_retry/2" do
    test "returns ok on first success without retrying" do
      state = base_state()

      do_auth = fn s -> {:ok, %{s | session_id: "s1"}} end
      assert {:ok, %{session_id: "s1"}} = Session.do_auth_with_retry(state, do_auth)
    end

    test "retries once when refresh succeeds" do
      state = base_state(config: Config.new(token: "x", app_key: "k", app_secret: "s"))
      attempts = :counters.new(1, [])

      do_auth = fn st ->
        n = :counters.get(attempts, 1)
        :counters.add(attempts, 1, 1)

        case n do
          0 -> {:error, {:auth_failed, 5}}
          _ -> {:ok, %{st | session_id: "s2"}}
        end
      end

      assert {:ok, %{session_id: "s2"}} = Session.do_auth_with_retry(state, do_auth)
    end

    test "skips refresh when credentials are missing" do
      state = base_state(config: Config.new(token: "x"))
      do_auth = fn _st -> {:error, {:auth_failed, 5}} end
      assert {:error, {:auth_failed, 5}} = Session.do_auth_with_retry(state, do_auth)
    end

    test "returns {:error, ...} when refresh fails" do
      state =
        Map.put(
          base_state(config: Config.new(token: "x", app_key: "k", app_secret: "s")),
          :refresh_token_fn,
          fn _cfg -> {:error, :http_500} end
        )

      do_auth = fn _st -> {:error, {:auth_failed, 5}} end

      assert {:error, {:auth_failed_and_refresh_failed, :http_500}} =
               Session.do_auth_with_retry(state, do_auth)
    end

    test "wraps refresh-token-fn exceptions as {:refresh_exception, _}" do
      state =
        Map.put(
          base_state(config: Config.new(token: "x", app_key: "k", app_secret: "s")),
          :refresh_token_fn,
          fn _cfg -> raise ArgumentError, "boom" end
        )

      do_auth = fn _st -> {:error, {:auth_failed, 5}} end

      assert {:error, {:auth_failed_and_refresh_failed, {:refresh_exception, %ArgumentError{}}}} =
               Session.do_auth_with_retry(state, do_auth)
    end

    test "rescues RuntimeError from the refresh fn" do
      state =
        Map.put(
          base_state(config: Config.new(token: "x", app_key: "k", app_secret: "s")),
          :refresh_token_fn,
          fn _cfg -> raise "raw runtime" end
        )

      do_auth = fn _st -> {:error, {:auth_failed, 5}} end

      assert {:error, {:auth_failed_and_refresh_failed, {:refresh_exception, _}}} =
               Session.do_auth_with_retry(state, do_auth)
    end
  end

  describe "fatal_error?/1" do
    test "matches documented fatal shapes" do
      assert Session.fatal_error?({:auth_failed, 5})
      assert Session.fatal_error?({:auth_failed_and_refresh_failed, :http_500})
      assert Session.fatal_error?({:unpack, :bad_magic})
      assert Session.fatal_error?(:no_token)
      refute Session.fatal_error?(:closed)
      refute Session.fatal_error?({:connect, :econnrefused})
      refute Session.fatal_error?(nil)
    end
  end

  describe "dispatch_response/3 unexpected req_id" do
    test "logs a warning and returns the state unchanged when the request id has no pending caller" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          state = base_state(pending: %{}, subscribers: MapSet.new([self()]))

          header = %Longbridge.Protocol.Header{
            type: :response,
            verify: false,
            gzip: false,
            body_length: 0,
            cmd_code: 11,
            request_id: 9_999,
            status_code: 0
          }

          assert state == Session.dispatch_response(state, header, "body")
        end)

      assert log =~ "Unexpected response for req_id"
    end
  end
end
