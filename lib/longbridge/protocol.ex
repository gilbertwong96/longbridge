defmodule Longbridge.Protocol do
  @moduledoc """
  Longbridge v1 socket protocol implementation.

  Handles binary packet framing/deframing, handshake, and message types
  for the Longbridge OpenAPI protocol. Used by `Longbridge.WSConnection`
  (the only transport — the SDK previously supported raw TCP but is
  WebSocket-only now).

  ## Protocol Overview

  Each WebSocket binary message contains one or more **length-prefixed**
  protocol packets concatenated together:

  ```
  ┌──────────────────────────┐
  │ length (4 bytes BE u32)  │
  ├──────────────────────────┤
  │ header (5/10/11 bytes)   │
  ├──────────────────────────┤
  │ body (Protobuf-encoded)  │
  └──────────────────────────┘
  ```

  The WebSocket layer's first protocol packet after upgrade is a
  2-byte **handshake**: `<<0b00010001, 0b00001001>>`
  (version=1, codec=protobuf=1, platform=OpenAPI=9, reserve=0).

  ### Packet Types

    * **Request** (type 1) — client initiates, expects a paired response.
    * **Response** (type 2) — server replies to a request. Status code
      in the header indicates success/error.
    * **Push** (type 3) — server-sent data without a prior request.

  ### Control Commands

    * `0` — Close (server disconnection notice)
    * `1` — Heartbeat (keep-alive ping/pong)
    * `2` — Auth (authenticate with token)
    * `3` — Reconnect (resume with session_id)

  ### Status Codes (response header)

    * `0` SUCCESS
    * `1` SERVER_TIMEOUT
    * `2` CLIENT_TIMEOUT
    * `3` BAD_REQUEST
    * `4` BAD_RESPONSE
    * `5` UNAUTHENTICATED
    * `6` PERMISSION_DENIED
    * `7` SERVER_INTERNAL_ERROR
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

  @doc """
  Returns the 2-byte protocol handshake sent as the first packet
  after the WebSocket upgrade.

  The same bytes are used regardless of transport (legacy TCP
  connections sent them on the raw socket; the WebSocket transport
  sends them as a WS binary message). Bytes are
  `<<0b00010001, 0b00001001>>` (version=1, codec=protobuf=1,
  platform=OpenAPI=9, reserve=0).
  """
  @spec handshake() :: binary()
  def handshake, do: @handshake_bytes

  @doc """
  Packs a complete packet (header + body) into iodata ready to send.

  The header's `:body_length` field is overwritten with the actual
  body size, so callers can pass a header with `body_length: 0` and
  trust this function to fill it in.

  Returns a two-element list `[header_binary, body]` suitable for
  `IO.iodata_to_binary/1` or writing directly to a socket.
  """
  @spec pack(Header.t(), body :: iodata()) :: [binary()]
  def pack(%Header{} = header, body) do
    header = %Header{header | body_length: IO.iodata_length(body)}
    header_data = Header.pack(header)
    [header_data, body]
  end

  @doc """
  Unpacks one packet from the front of `data` and returns any
  trailing bytes unchanged.

  Used by `Longbridge.WSConnection` to split a single WebSocket binary
  message that may contain multiple length-prefixed packets
  concatenated together. The returned `remaining` is fed back in on
  the next call.

  If the response header has `gzip: true`, the body is
  transparently decompressed — `Longbridge.QuoteContext` and friends
  can then pass the result straight to `Protox.decode!/2` without
  caring about compression.

  Returns:

    * `{:ok, header, body, remaining}` — `body` is the raw or
      gunzipped body bytes; `remaining` is whatever was left after
      `body_length` bytes.
    * `{:error, :incomplete_body}` — not enough bytes yet; buffer
      and try again when more data arrives.
    * `{:error, reason}` — header decode failed.
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
          body = decompress_body(header, body)
          {:ok, header, body, remaining}
        end

      {:error, _} = err ->
        err
    end
  end

  # The Longbridge server gzip-compresses response bodies when the payload
  # exceeds its internal threshold, regardless of the `gzip` flag we send on
  # the request. The header's `gzip` bit is the source of truth: when set, the
  # body is a gzip stream and must be inflated before protobuf decoding.
  defp decompress_body(%Header{gzip: true}, body) do
    :zlib.gunzip(body)
  rescue
    e -> reraise "longbridge gzip decompression failed: #{Exception.message(e)}", __STACKTRACE__
  end

  defp decompress_body(%Header{gzip: false}, body), do: body

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
