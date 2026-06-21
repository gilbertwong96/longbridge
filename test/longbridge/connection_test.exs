defmodule Longbridge.ConnectionTest do
  use ExUnit.Case, async: false

  alias Longbridge.{Config, Connection, Protocol}
  alias Longbridge.Control.V1, as: Ctrl
  alias Longbridge.Protocol.Header

  # ── Fake server helpers ─────────────────────────────────

  defp recv_exact(socket, n, timeout), do: :gen_tcp.recv(socket, n, timeout)

  # Reads a full Longbridge request packet (header + body) from a socket.
  defp recv_request(socket, timeout) do
    with {:ok, <<type_byte>>} <- recv_exact(socket, 1, timeout),
         {:ok, h1} <- recv_exact(socket, 10, timeout) do
      <<_cmd::8, _req_id::32, _timeout::16, body_len_bytes::3-binary>> = h1
      <<body_len::24-big>> = body_len_bytes
      {:ok, body} = recv_exact(socket, body_len, timeout)
      {:ok, <<type_byte, h1::binary, body::binary>>}
    end
  end

  defp build_auth_response(req_id, session_id, expires, status_code \\ 0) do
    auth_resp = %Ctrl.AuthResponse{session_id: session_id, expires: expires}
    {:ok, body_iodata, _} = Protox.encode(auth_resp)
    body = IO.iodata_to_binary(body_iodata)

    h = %Header{
      type: :response,
      verify: false,
      gzip: false,
      body_length: byte_size(body),
      cmd_code: Protocol.cmd_auth(),
      request_id: req_id,
      status_code: status_code
    }

    IO.iodata_to_binary(Protocol.pack(h, body))
  end

  # ── Test cases ──────────────────────────────────────────

  setup do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)

    on_exit(fn -> :gen_tcp.close(listen_socket) end)

    {:ok, port: port, listen_socket: listen_socket}
  end

  describe "start_link/1 + authentication" do
    test "completes handshake and auth against a fake server", %{port: _port} do
      test_pid = self()
      session_id = "sess-#{System.unique_integer([:positive])}"
      expires = System.os_time(:second) + 3600

      fake_server =
        spawn_link(fn ->
          {:ok, listen_socket} =
            :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

          {:ok, port} = :inet.port(listen_socket)
          send(test_pid, {:fake_server_port, port})

          {:ok, client} = :gen_tcp.accept(listen_socket, 5_000)
          send(test_pid, {:fake_server, :accepted, self()})

          # consume the 2-byte handshake
          {:ok, <<0b00010001, 0b00001001>>} = recv_exact(client, 2, 5_000)

          # read the auth request packet
          {:ok, auth_packet} = recv_request(client, 5_000)
          send(test_pid, {:fake_server, :auth_request, auth_packet})

          # decode the auth request to find the req_id
          {:ok, %Header{request_id: req_id}, _auth_body, <<>>} = Protocol.unpack(auth_packet)

          # build a successful auth response
          auth_resp = %Ctrl.AuthResponse{session_id: session_id, expires: expires}
          {:ok, body_iodata, _} = Protox.encode(auth_resp)
          body = IO.iodata_to_binary(body_iodata)

          header = %Header{
            type: :response,
            verify: false,
            gzip: false,
            body_length: byte_size(body),
            cmd_code: Protocol.cmd_auth(),
            request_id: req_id,
            status_code: 0
          }

          :gen_tcp.send(client, IO.iodata_to_binary(Protocol.pack(header, body)))
          send(test_pid, {:fake_server, :auth_response_sent, session_id})

          # keep accepting
          receive do
            :stop -> :ok
          after
            5_000 -> :ok
          end

          :gen_tcp.close(client)
          :gen_tcp.close(listen_socket)
        end)

      assert_receive {:fake_server_port, fake_port}, 2_000

      config = Config.new(token: "test-token", quote_host: "127.0.0.1", quote_port: fake_port)

      {:ok, conn} = Connection.start_link(config: config, type: :quote, parent: test_pid)
      assert_receive {:fake_server, :accepted, _}, 2_000
      assert_receive {:fake_server, :auth_request, _}, 2_000

      assert_receive {:longbridge, ^conn, {:connected, ^session_id}}, 2_000

      # session info
      assert {:ok, ^session_id, ^expires} = Connection.get_session(conn)

      send(fake_server, :stop)
    end

    test "returns {:ok, session_id, expires} after a successful auth" do
      test_pid = self()
      session_id = "sess-info-#{System.unique_integer([:positive])}"
      expires = System.os_time(:second) + 3600

      fake_server =
        spawn_link(fn ->
          {:ok, listen} =
            :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

          {:ok, port} = :inet.port(listen)
          send(test_pid, {:port, port})

          {:ok, client} = :gen_tcp.accept(listen, 5_000)
          {:ok, _} = recv_exact(client, 2, 5_000)
          {:ok, auth_packet} = recv_request(client, 5_000)
          {:ok, %Header{request_id: req_id}, _, <<>>} = Protocol.unpack(auth_packet)

          :gen_tcp.send(client, build_auth_response(req_id, session_id, expires))

          receive do
            :stop -> :ok
          after
            3_000 -> :ok
          end

          :gen_tcp.close(client)
          :gen_tcp.close(listen)
        end)

      assert_receive {:port, port}, 2_000
      config = Config.new(token: "test-token", quote_host: "127.0.0.1", quote_port: port)
      {:ok, conn} = Connection.start_link(config: config, type: :quote, parent: test_pid)
      assert_receive {:longbridge, ^conn, {:connected, _}}, 2_000
      assert {:ok, ^session_id, _} = Connection.get_session(conn)
      send(fake_server, :stop)
    end

    test "broadcasts push data to subscribers" do
      test_pid = self()
      session_id = "sess-broadcast-#{System.unique_integer([:positive])}"
      expires = System.os_time(:second) + 3600

      fake_server =
        spawn_link(fn ->
          {:ok, listen} =
            :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

          {:ok, port} = :inet.port(listen)
          send(test_pid, {:port, port})

          {:ok, client} = :gen_tcp.accept(listen, 5_000)
          {:ok, _} = recv_exact(client, 2, 5_000)
          {:ok, auth_packet} = recv_request(client, 5_000)
          {:ok, %Header{request_id: req_id}, _, <<>>} = Protocol.unpack(auth_packet)

          :gen_tcp.send(client, build_auth_response(req_id, session_id, expires))

          # build a push packet (cmd 101)
          push_body = "push-data"

          push_header = %Header{
            type: :push,
            verify: false,
            gzip: false,
            body_length: byte_size(push_body),
            cmd_code: 101,
            request_id: 0,
            status_code: 0
          }

          :gen_tcp.send(client, IO.iodata_to_binary(Protocol.pack(push_header, push_body)))

          receive do
            :stop -> :ok
          after
            3_000 -> :ok
          end

          :gen_tcp.close(client)
          :gen_tcp.close(listen)
        end)

      assert_receive {:port, port}, 2_000
      config = Config.new(token: "test-token", quote_host: "127.0.0.1", quote_port: port)
      {:ok, conn} = Connection.start_link(config: config, type: :quote, parent: test_pid)
      assert_receive {:longbridge, ^conn, {:connected, _}}, 2_000
      assert_receive {:longbridge, ^conn, {:push, 101, "push-data"}}, 2_000
      send(fake_server, :stop)
    end

    test "retries auth with refreshed token on auth_failed" do
      test_pid = self()
      session_id = "sess-refresh-#{System.unique_integer([:positive])}"
      expires = System.os_time(:second) + 3600

      fake_server =
        spawn_link(fn ->
          {:ok, listen} =
            :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

          {:ok, port} = :inet.port(listen)
          send(test_pid, {:port, port})
          {:ok, client} = :gen_tcp.accept(listen, 5_000)

          # Handshake (read only, no response needed)
          {:ok, _} = recv_exact(client, 2, 5_000)

          # First auth attempt — server rejects
          {:ok, auth1_packet} = recv_request(client, 5_000)
          {:ok, %Header{request_id: req1}, _, <<>>} = Protocol.unpack(auth1_packet)
          :gen_tcp.send(client, build_auth_response(req1, "", 0, 5))

          # Second auth attempt — server accepts
          {:ok, auth2_packet} = recv_request(client, 5_000)
          {:ok, %Header{request_id: req2}, _, <<>>} = Protocol.unpack(auth2_packet)
          :gen_tcp.send(client, build_auth_response(req2, session_id, expires))

          receive do
            :stop -> :ok
          after
            2_000 -> :ok
          end

          :gen_tcp.close(client)
          :gen_tcp.close(listen)
        end)

      assert_receive {:port, port}, 2_000

      config =
        Config.new(
          token: "expired-token",
          app_key: "test-key",
          app_secret: "test-secret",
          quote_host: "127.0.0.1",
          quote_port: port
        )

      {:ok, conn} =
        Connection.start_link(
          config: config,
          type: :quote,
          parent: test_pid,
          refresh_token_fn: fn _cfg ->
            {:ok, %{config | token: "refreshed-token"}}
          end
        )

      assert_receive {:longbridge, ^conn, {:connected, _}}, 2_000
      assert {:ok, ^session_id, _} = Connection.get_session(conn)
      send(fake_server, :stop)
    end

    test "gives up when token refresh fails" do
      test_pid = self()

      fake_server =
        spawn_link(fn ->
          {:ok, listen} =
            :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

          {:ok, port} = :inet.port(listen)
          send(test_pid, {:port, port})
          {:ok, client} = :gen_tcp.accept(listen, 5_000)

          # Handshake
          {:ok, _} = recv_exact(client, 2, 5_000)

          # Auth attempt — server rejects
          {:ok, auth_packet} = recv_request(client, 5_000)
          {:ok, %Header{request_id: req}, _, <<>>} = Protocol.unpack(auth_packet)
          :gen_tcp.send(client, build_auth_response(req, "", 0, 5))

          # Should not receive a second auth attempt (refresh failed)
          receive do
            {:tcp, ^client, data} ->
              send(test_pid, {:unexpected_auth_retry, data})
          after
            2_000 -> :ok
          end

          :gen_tcp.close(client)
          :gen_tcp.close(listen)
        end)

      assert_receive {:port, port}, 2_000

      config =
        Config.new(
          token: "expired-token",
          app_key: "test-key",
          app_secret: "test-secret",
          quote_host: "127.0.0.1",
          quote_port: port
        )

      {:ok, conn} =
        Connection.start_link(
          config: config,
          type: :quote,
          parent: test_pid,
          refresh_token_fn: fn _cfg -> {:error, :refresh_failed} end
        )

      # Connection should fail, broadcasting disconnected
      assert_receive {:longbridge, ^conn, {:disconnected, _}}, 5_000
      refute_receive {:unexpected_auth_retry, _}, 500
      send(fake_server, :stop)
    end

    test "gives up when retried auth also fails" do
      test_pid = self()

      fake_server =
        spawn_link(fn ->
          {:ok, listen} =
            :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

          {:ok, port} = :inet.port(listen)
          send(test_pid, {:port, port})
          {:ok, client} = :gen_tcp.accept(listen, 5_000)

          # Handshake
          {:ok, _} = recv_exact(client, 2, 5_000)

          # First auth attempt — reject
          {:ok, auth1_packet} = recv_request(client, 5_000)
          {:ok, %Header{request_id: req1}, _, <<>>} = Protocol.unpack(auth1_packet)
          :gen_tcp.send(client, build_auth_response(req1, "", 0, 5))

          # Second auth attempt — also reject
          {:ok, auth2_packet} = recv_request(client, 5_000)
          {:ok, %Header{request_id: req2}, _, <<>>} = Protocol.unpack(auth2_packet)
          :gen_tcp.send(client, build_auth_response(req2, "", 0, 8))

          receive do
            :stop -> :ok
          after
            2_000 -> :ok
          end

          :gen_tcp.close(client)
          :gen_tcp.close(listen)
        end)

      assert_receive {:port, port}, 2_000

      config =
        Config.new(
          token: "expired-token",
          app_key: "test-key",
          app_secret: "test-secret",
          quote_host: "127.0.0.1",
          quote_port: port
        )

      {:ok, conn} =
        Connection.start_link(
          config: config,
          type: :quote,
          parent: test_pid,
          refresh_token_fn: fn _cfg ->
            {:ok, %{config | token: "refreshed-token"}}
          end
        )

      # Both attempts fail, connection should broadcast disconnected
      assert_receive {:longbridge, ^conn, {:disconnected, _}}, 5_000
      send(fake_server, :stop)
    end

    test "skips refresh when oauth config has no app_key/app_secret" do
      test_pid = self()

      fake_server =
        spawn_link(fn ->
          {:ok, listen} =
            :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

          {:ok, port} = :inet.port(listen)
          send(test_pid, {:port, port})
          {:ok, client} = :gen_tcp.accept(listen, 5_000)

          {:ok, _} = recv_exact(client, 2, 5_000)
          {:ok, auth_packet} = recv_request(client, 5_000)
          {:ok, %Header{request_id: req}, _, <<>>} = Protocol.unpack(auth_packet)
          :gen_tcp.send(client, build_auth_response(req, "", 0, 5))

          # No second auth attempt expected (refresh skipped)
          receive do
            {:tcp, ^client, data} ->
              send(test_pid, {:unexpected_auth_retry, data})
          after
            2_000 -> :ok
          end

          :gen_tcp.close(client)
          :gen_tcp.close(listen)
        end)

      assert_receive {:port, port}, 2_000

      # OAuth config: no app_key/app_secret
      config = Config.new(token: "oauth-token", quote_host: "127.0.0.1", quote_port: port)
      refute config.app_key
      refute config.app_secret

      {:ok, conn} =
        Connection.start_link(config: config, type: :quote, parent: test_pid)

      # Should fail immediately without attempting refresh
      assert_receive {:longbridge, ^conn, {:disconnected, _}}, 5_000
      refute_receive {:unexpected_auth_retry, _}, 500
      send(fake_server, :stop)
    end

    test "disconnects after idle timeout with no activity" do
      test_pid = self()
      session_id = "sess-idle-#{System.unique_integer([:positive])}"
      expires = System.os_time(:second) + 3600

      fake_server =
        spawn_link(fn ->
          {:ok, listen} =
            :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

          {:ok, port} = :inet.port(listen)
          send(test_pid, {:port, port})
          {:ok, client} = :gen_tcp.accept(listen, 5_000)
          {:ok, _} = recv_exact(client, 2, 5_000)
          {:ok, auth_packet} = recv_request(client, 5_000)
          {:ok, %Header{request_id: req_id}, _, <<>>} = Protocol.unpack(auth_packet)
          :gen_tcp.send(client, build_auth_response(req_id, session_id, expires))

          # Keep connection open, no more data sent
          receive do
            :stop -> :ok
          after
            5_000 -> :ok
          end

          :gen_tcp.close(client)
          :gen_tcp.close(listen)
        end)

      assert_receive {:port, port}, 2_000

      config =
        Config.new(
          token: "test-token",
          idle_timeout: 300,
          quote_host: "127.0.0.1",
          quote_port: port
        )

      {:ok, conn} = Connection.start_link(config: config, type: :quote, parent: test_pid)

      # Connect successfully
      assert_receive {:longbridge, ^conn, {:connected, _}}, 2_000

      # After idle timeout, should disconnect
      assert_receive {:longbridge, ^conn, {:disconnected, :idle_timeout}}, 1_000
      send(fake_server, :stop)
    end

    test "resets idle timer on received TCP data" do
      test_pid = self()
      session_id = "sess-keepalive-#{System.unique_integer([:positive])}"
      expires = System.os_time(:second) + 3600

      fake_server =
        spawn_link(fn ->
          {:ok, listen} =
            :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

          {:ok, port} = :inet.port(listen)
          send(test_pid, {:port, port})
          {:ok, client} = :gen_tcp.accept(listen, 5_000)
          {:ok, _} = recv_exact(client, 2, 5_000)

          # Send auth response
          {:ok, auth_packet} = recv_request(client, 5_000)
          {:ok, %Header{request_id: req_id}, _, <<>>} = Protocol.unpack(auth_packet)
          :gen_tcp.send(client, build_auth_response(req_id, session_id, expires))

          # Brief delay so auth completes and idle timer starts before push arrives
          Process.sleep(50)

          # Send a push packet to reset idle timer
          push_body = "keepalive"

          push_header = %Header{
            type: :push,
            verify: false,
            gzip: false,
            body_length: byte_size(push_body),
            cmd_code: 99,
            request_id: 0,
            status_code: 0
          }

          :gen_tcp.send(client, IO.iodata_to_binary(Protocol.pack(push_header, push_body)))

          receive do
            :stop -> :ok
          after
            1_000 -> :ok
          end

          :gen_tcp.close(client)
          :gen_tcp.close(listen)
        end)

      assert_receive {:port, port}, 2_000

      config =
        Config.new(
          token: "test-token",
          idle_timeout: 500,
          quote_host: "127.0.0.1",
          quote_port: port
        )

      {:ok, conn} = Connection.start_link(config: config, type: :quote, parent: test_pid)
      assert_receive {:longbridge, ^conn, {:connected, _}}, 2_000
      assert_receive {:longbridge, ^conn, {:push, 99, "keepalive"}}, 2_000

      # Timer was reset, verify it hasn't fired after half the timeout period
      refute_receive {:longbridge, ^conn, {:disconnected, :idle_timeout}}, 300
      send(fake_server, :stop)
    end
  end

  describe "request/4" do
    test "sends a request and returns the response body" do
      test_pid = self()
      session_id = "sess-req-#{System.unique_integer([:positive])}"
      expires = System.os_time(:second) + 3600

      fake_server =
        spawn_link(fn ->
          {:ok, listen} =
            :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

          {:ok, port} = :inet.port(listen)
          send(test_pid, {:port, port})

          {:ok, client} = :gen_tcp.accept(listen, 5_000)
          {:ok, _} = recv_exact(client, 2, 5_000)
          {:ok, auth_packet} = recv_request(client, 5_000)
          {:ok, %Header{request_id: req_id}, _, <<>>} = Protocol.unpack(auth_packet)
          :gen_tcp.send(client, build_auth_response(req_id, session_id, expires))

          # read the biz request
          {:ok, biz_packet} = recv_request(client, 5_000)
          {:ok, %Header{request_id: biz_req_id}, biz_body, <<>>} = Protocol.unpack(biz_packet)

          # respond
          resp_header = %Header{
            type: :response,
            verify: false,
            gzip: false,
            body_length: byte_size(biz_body),
            cmd_code: biz_req_id - 0,
            request_id: biz_req_id,
            status_code: 0
          }

          # use original cmd_code from the request
          <<_::binary-size(1), cmd::8, _::binary>> = biz_packet
          cmd_code = :binary.first(<<cmd>>)

          h = %Header{
            type: :response,
            verify: false,
            gzip: false,
            body_length: byte_size(biz_body),
            cmd_code: cmd_code,
            request_id: biz_req_id,
            status_code: 0
          }

          :gen_tcp.send(client, IO.iodata_to_binary(Protocol.pack(h, biz_body)))
          _ = resp_header
          _ = biz_req_id

          receive do
            :stop -> :ok
          after
            3_000 -> :ok
          end

          :gen_tcp.close(client)
          :gen_tcp.close(listen)
        end)

      assert_receive {:port, port}, 2_000
      config = Config.new(token: "test-token", quote_host: "127.0.0.1", quote_port: port)
      {:ok, conn} = Connection.start_link(config: config, type: :quote, parent: test_pid)
      assert_receive {:longbridge, ^conn, {:connected, _}}, 2_000

      assert {:ok, resp_body, _req_id} = Connection.request(conn, 50, "hello", 2_000)
      assert resp_body == "hello"

      send(fake_server, :stop)
    end
  end

  describe "error paths" do
    test "schedules a reconnect when server rejects auth", %{port: _port} do
      test_pid = self()

      fake_server =
        spawn(fn ->
          {:ok, listen} =
            :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

          {:ok, port} = :inet.port(listen)
          send(test_pid, {:fake_server_port, port})

          {:ok, client} = :gen_tcp.accept(listen, 5_000)
          {:ok, _} = recv_exact(client, 2, 5_000)
          {:ok, auth_packet} = recv_request(client, 5_000)
          {:ok, %Header{request_id: req_id}, _, <<>>} = Protocol.unpack(auth_packet)

          header = %Header{
            type: :response,
            verify: false,
            gzip: false,
            body_length: 0,
            cmd_code: Protocol.cmd_auth(),
            request_id: req_id,
            status_code: 5
          }

          :gen_tcp.send(client, IO.iodata_to_binary(Protocol.pack(header, <<>>)))

          receive do
            :stop -> :gen_tcp.close(client)
          after
            5_000 -> :gen_tcp.close(client)
          end

          :gen_tcp.close(listen)
        end)

      assert_receive {:fake_server_port, fake_port}, 2_000

      config = Config.new(token: "test-token", quote_host: "127.0.0.1", quote_port: fake_port)

      parent = self()

      pid =
        spawn(fn ->
          {:ok, _conn} = Connection.start_link(config: config, type: :quote, parent: parent)
          Process.sleep(:infinity)
        end)

      # The connection should NOT stop on auth failure. It should
      # emit a {:disconnected, reason} message and schedule a reconnect.
      assert_receive {:longbridge, _conn_pid, {:disconnected, _}}, 2_000

      # Verify the connection process is still alive (reconnecting).
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, _pid, :normal} -> flunk("connection should not have died")
      after
        200 -> :ok
      end

      send(fake_server, :stop)
      Process.exit(pid, :kill)
    end

    test "schedules a reconnect when server never responds to auth", %{port: _port} do
      test_pid = self()

      fake_server =
        spawn(fn ->
          {:ok, listen} =
            :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

          {:ok, port} = :inet.port(listen)
          send(test_pid, {:fake_server_port, port})

          {:ok, client} = :gen_tcp.accept(listen, 5_000)
          {:ok, _} = recv_exact(client, 2, 5_000)

          # read the auth packet but never reply
          {:ok, _auth_packet} = recv_request(client, 5_000)

          receive do
            :stop -> :gen_tcp.close(client)
          after
            15_000 -> :gen_tcp.close(client)
          end

          :gen_tcp.close(listen)
        end)

      assert_receive {:fake_server_port, fake_port}, 2_000

      config = Config.new(token: "test-token", quote_host: "127.0.0.1", quote_port: fake_port)

      parent = self()

      pid =
        spawn(fn ->
          {:ok, _conn} = Connection.start_link(config: config, type: :quote, parent: parent)
          Process.sleep(:infinity)
        end)

      # The connection should NOT stop on auth timeout. It should
      # emit a {:disconnected, :auth_timeout} message and reconnect.
      assert_receive {:longbridge, _conn_pid, {:disconnected, :auth_timeout}}, 15_000

      # The connection process is still alive.
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, _pid, :normal} -> flunk("connection should not have died")
      after
        200 -> :ok
      end

      send(fake_server, :stop)
      Process.exit(pid, :kill)
    end

    test "returns {:error, :timeout} when a request exceeds its timeout", %{port: _port} do
      test_pid = self()
      session_id = "sess-timeout-#{System.unique_integer([:positive])}"
      expires = System.os_time(:second) + 3600

      fake_server =
        spawn(fn ->
          {:ok, listen} =
            :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

          {:ok, port} = :inet.port(listen)
          send(test_pid, {:fake_server_port, port})

          {:ok, client} = :gen_tcp.accept(listen, 5_000)
          {:ok, _} = recv_exact(client, 2, 5_000)

          # auth
          {:ok, auth_packet} = recv_request(client, 5_000)
          {:ok, %Header{request_id: req_id}, _, <<>>} = Protocol.unpack(auth_packet)
          :gen_tcp.send(client, build_auth_response(req_id, session_id, expires))

          # read the biz request but never reply
          {:ok, _biz_packet} = recv_request(client, 5_000)

          receive do
            :stop -> :gen_tcp.close(client)
          after
            5_000 -> :gen_tcp.close(client)
          end

          :gen_tcp.close(listen)
        end)

      assert_receive {:fake_server_port, fake_port}, 2_000

      config = Config.new(token: "test-token", quote_host: "127.0.0.1", quote_port: fake_port)
      {:ok, conn} = Connection.start_link(config: config, type: :quote, parent: test_pid)

      # wait for auth
      assert_receive {:longbridge, ^conn, {:connected, _}}, 2_000

      # send a request with a short timeout; the server won't reply
      assert {:error, :timeout} = Connection.request(conn, 99, "data", 100)

      send(fake_server, :stop)
      Process.exit(conn, :kill)
    end
  end

  describe "reconnection" do
    test "reconnects after a TCP close and notifies subscribers" do
      test_pid = self()
      session_id = "sess-recon-#{System.unique_integer([:positive])}"
      expires = System.os_time(:second) + 3600

      fake_server =
        spawn(fn ->
          {:ok, listen} =
            :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

          {:ok, port} = :inet.port(listen)
          send(test_pid, {:fake_server_port, port})

          loop = fn loop, n ->
            {:ok, client} = :gen_tcp.accept(listen, 15_000)
            send(test_pid, {:accept, n})
            send(test_pid, {:client_socket, n, client})

            {:ok, _} = recv_exact(client, 2, 5_000)
            {:ok, auth_packet} = recv_request(client, 5_000)
            {:ok, %Header{request_id: req_id}, _, <<>>} = Protocol.unpack(auth_packet)
            :gen_tcp.send(client, build_auth_response(req_id, session_id, expires))

            receive do
              :close ->
                :gen_tcp.close(client)
                loop.(loop, n + 1)

              :stop ->
                :gen_tcp.close(client)
                :gen_tcp.close(listen)
            after
              10_000 -> :gen_tcp.close(client)
            end
          end

          loop.(loop, 1)
        end)

      assert_receive {:fake_server_port, fake_port}, 2_000
      config = Config.new(token: "test-token", quote_host: "127.0.0.1", quote_port: fake_port)

      parent = self()

      pid =
        spawn(fn ->
          {:ok, conn} = Connection.start_link(config: config, type: :quote, parent: parent)
          send(test_pid, {:conn, conn})
          Process.sleep(:infinity)
        end)

      # First connection
      assert_receive {:accept, 1}, 3_000
      assert_receive {:conn, conn}, 2_000
      assert_receive {:longbridge, ^conn, {:connected, _}}, 2_000

      # Simulate a network drop by closing the server-side socket
      assert_receive {:client_socket, 1, sock1}, 2_000
      send(fake_server, :close)

      # The connection should detect the close and broadcast :disconnected
      assert_receive {:longbridge, ^conn, {:disconnected, _}}, 2_000

      # It should reconnect
      assert_receive {:accept, 2}, 5_000
      assert_receive {:longbridge, ^conn, {:connected, _}}, 2_000

      # Cleanup
      send(fake_server, :stop)
      Process.exit(pid, :kill)
    end

    test "fails pending requests on disconnect" do
      test_pid = self()
      session_id = "sess-pending-#{System.unique_integer([:positive])}"
      expires = System.os_time(:second) + 3600

      fake_server =
        spawn(fn ->
          {:ok, listen} =
            :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

          {:ok, port} = :inet.port(listen)
          send(test_pid, {:fake_server_port, port})

          {:ok, client} = :gen_tcp.accept(listen, 5_000)
          send(test_pid, {:client, client})

          {:ok, _} = recv_exact(client, 2, 5_000)
          {:ok, auth_packet} = recv_request(client, 5_000)
          {:ok, %Header{request_id: req_id}, _, <<>>} = Protocol.unpack(auth_packet)
          :gen_tcp.send(client, build_auth_response(req_id, session_id, expires))

          receive do
            :close -> :gen_tcp.close(client)
          after
            5_000 -> :gen_tcp.close(client)
          end

          :gen_tcp.close(listen)
        end)

      assert_receive {:fake_server_port, fake_port}, 2_000
      config = Config.new(token: "test-token", quote_host: "127.0.0.1", quote_port: fake_port)

      parent = self()

      pid =
        spawn(fn ->
          {:ok, conn} = Connection.start_link(config: config, type: :quote, parent: parent)
          send(test_pid, {:conn, conn})
          Process.sleep(:infinity)
        end)

      assert_receive {:conn, conn}, 2_000
      assert_receive {:longbridge, ^conn, {:connected, _}}, 2_000
      assert_receive {:client, _client_socket}, 2_000

      # Issue a request that will be pending
      req_pid =
        spawn(fn ->
          result = Connection.request(conn, 99, "data", 5_000)
          send(test_pid, {:req_result, result})
        end)

      # Give the request time to be sent
      Process.sleep(100)

      # Now drop the connection
      send(fake_server, :close)

      # The pending request should fail with :disconnected
      assert_receive {:req_result, {:error, {:disconnected, _}}}, 5_000
      _ = req_pid

      Process.exit(pid, :kill)
    end

    test "returns :not_connected for requests while disconnected" do
      test_pid = self()

      fake_server =
        spawn(fn ->
          {:ok, listen} =
            :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

          {:ok, port} = :inet.port(listen)
          send(test_pid, {:fake_server_port, port})

          {:ok, client} = :gen_tcp.accept(listen, 5_000)
          {:ok, _} = recv_exact(client, 2, 5_000)
          {:ok, _} = recv_request(client, 5_000)

          receive do
            :close -> :gen_tcp.close(client)
          after
            10_000 -> :gen_tcp.close(client)
          end

          :gen_tcp.close(listen)
        end)

      assert_receive {:fake_server_port, fake_port}, 2_000
      config = Config.new(token: "test-token", quote_host: "127.0.0.1", quote_port: fake_port)

      parent = self()

      pid =
        spawn(fn ->
          {:ok, conn} = Connection.start_link(config: config, type: :quote, parent: parent)
          send(test_pid, {:conn, conn})
          Process.sleep(:infinity)
        end)

      assert_receive {:conn, conn}, 2_000
      # Wait for the :disconnected message (auth_timeout fires at 10s)
      assert_receive {:longbridge, ^conn, {:disconnected, _}}, 15_000

      # Now any request should immediately fail with :not_connected
      assert {:error, :not_connected} = Connection.request(conn, 99, "data", 1_000)

      send(fake_server, :close)
      Process.exit(pid, :kill)
    end
  end
end
