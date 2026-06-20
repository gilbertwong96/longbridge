defmodule Longbridge.Protocol do
  @moduledoc """
  Longbridge v1 socket protocol implementation.

  Handles binary packet framing/deframing, handshake, and message types
  for the Longbridge OpenAPI protocol.

  ## Protocol Overview

  The Longbridge protocol uses a binary framing format over TCP or WebSocket.
  Packets have a fixed header followed by a Protobuf-encoded body.

  ### Packet Types
  - **Request** (type 1) — client initiates, expects a paired response
  - **Response** (type 2) — server replies to a request
  - **Push** (type 3) — server sends data without a prior request

  ### Handshake
  TCP connections send a 2-byte handshake packet before any other data:
  - Byte 1: `version (4 bits) | codec (4 bits)` = `0b00010001`
  - Byte 2: `platform (4 bits) | reserve (4 bits)` = `0b00001001`
  (version=1, codec=protobuf=1, platform=OpenAPI=9)

  ### Control Commands
  - `0` — Close (server disconnection notice)
  - `1` — Heartbeat (keep-alive ping/pong)
  - `2` — Auth (authenticate with token)
  - `3` — Reconnect (resume with session_id)
  """

  alias Longbridge.Protocol.Header

  # ── Handshake ───────────────────────────────────────────

  @handshake_bytes <<0b00010001, 0b00001001>>
  # ver=1, codec=protobuf=1, platform=OpenAPI=9, reserve=0

  # ── Control commands ────────────────────────────────────

  @cmd_close 0
  @cmd_heartbeat 1
  @cmd_auth 2
  @cmd_reconnect 3

  # Status codes used by response packets
  @status_success 0
  @status_server_timeout 1
  @status_bad_request 3
  @status_unauthenticated 5
  @status_server_internal_error 7

  # ── Public API ───────────────────────────────────────────

  @doc "Returns the 2-byte TCP handshake packet."
  @spec handshake() :: binary()
  def handshake, do: @handshake_bytes

  @doc """
  Packs a complete packet (header + body).

  Returns iodata suitable for writing to a socket.
  """
  @spec pack(Header.t(), body :: iodata()) :: [binary()]
  def pack(%Header{} = header, body) do
    header = %Header{header | body_length: IO.iodata_length(body)}
    header_data = Header.pack(header)
    [header_data, body]
  end

  @doc """
  Unpacks a complete packet from binary data.

  Returns `{:ok, header, body_binary, remaining}` or `{:error, reason}`.
  """
  @spec unpack(binary()) ::
          {:ok, Header.t(), binary(), binary()}
          | {:error, term()}
  def unpack(data) do
    case Header.unpack(data) do
      {:ok, header, rest} ->
        body_len = header.body_length

        if byte_size(rest) < body_len do
          {:error, :incomplete_body}
        else
          <<body::binary-size(^body_len), remaining::binary>> = rest
          {:ok, header, body, remaining}
        end

      {:error, _} = err ->
        err
    end
  end

  # ── Command helpers ──────────────────────────────────────

  @doc "Returns true if the command code is a control command (0-3)."
  @spec control?(non_neg_integer()) :: boolean()
  def control?(cmd), do: cmd <= @cmd_reconnect

  @doc "Returns true for Close command."
  def close?(cmd), do: cmd == @cmd_close

  @doc "Returns true for Heartbeat command."
  def heartbeat?(cmd), do: cmd == @cmd_heartbeat

  @doc "Returns true for Auth command."
  def auth?(cmd), do: cmd == @cmd_auth

  @doc "Returns true for Reconnect command."
  def reconnect?(cmd), do: cmd == @cmd_reconnect

  # ── Constants accessors ──────────────────────────────────

  def cmd_close, do: @cmd_close
  def cmd_heartbeat, do: @cmd_heartbeat
  def cmd_auth, do: @cmd_auth
  def cmd_reconnect, do: @cmd_reconnect

  def status_success, do: @status_success
  def status_server_timeout, do: @status_server_timeout
  def status_bad_request, do: @status_bad_request
  def status_unauthenticated, do: @status_unauthenticated
  def status_server_internal_error, do: @status_server_internal_error

  @doc "Returns the human-readable name for a status code."
  @spec status_name(non_neg_integer()) :: String.t()
  def status_name(0), do: "SUCCESS"
  def status_name(1), do: "SERVER_TIMEOUT"
  def status_name(2), do: "CLIENT_TIMEOUT"
  def status_name(3), do: "BAD_REQUEST"
  def status_name(4), do: "BAD_RESPONSE"
  def status_name(5), do: "UNAUTHENTICATED"
  def status_name(6), do: "PERMISSION_DENIED"
  def status_name(7), do: "SERVER_INTERNAL_ERROR"
  def status_name(8), do: "CLIENT_INTERNAL_ERROR"
  def status_name(_), do: "UNKNOWN"
end
