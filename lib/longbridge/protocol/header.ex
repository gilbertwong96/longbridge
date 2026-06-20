defmodule Longbridge.Protocol.Header do
  @moduledoc """
  Binary packet header for the Longbridge v1 protocol.

  The header layout differs by packet type:

  **Request** (11 bytes):
  ```
  type:4|ver:1|gzip:1|resv:2 | cmd_code:8 | request_id:32 | timeout:16 | body_len:24
  ```

  **Response** (10 bytes):
  ```
  type:4|ver:1|gzip:1|resv:2 | cmd_code:8 | request_id:32 | status_code:8 | body_len:24
  ```

  **Push** (5 bytes):
  ```
  type:4|ver:1|gzip:1|resv:2 | cmd_code:8 | body_len:24
  ```

  After the body, optional nonce (8 bytes) and signature (16 bytes) when verify is enabled.
  """

  import Bitwise

  @type packet_type :: :request | :response | :push

  @type t :: %__MODULE__{
          type: packet_type(),
          verify: boolean(),
          gzip: boolean(),
          cmd_code: non_neg_integer(),
          request_id: non_neg_integer() | nil,
          timeout: non_neg_integer() | nil,
          status_code: non_neg_integer() | nil,
          body_length: non_neg_integer(),
          nonce: non_neg_integer() | nil,
          signature: binary() | nil
        }

  defstruct [
    :type,
    :verify,
    :gzip,
    :cmd_code,
    :request_id,
    :timeout,
    :status_code,
    :body_length,
    :nonce,
    :signature
  ]

  @packet_type_map %{1 => :request, 2 => :response, 3 => :push}
  @packet_type_rev %{request: 1, response: 2, push: 3}

  @max_body_length 16_777_215
  @nonce_length 8
  @signature_length 16

  @doc """
  Packs a header struct into its binary representation.
  Returns iodata.
  """
  @spec pack(t()) :: [binary(), ...]
  def pack(%__MODULE__{} = h) do
    validate_body_length!(h.body_length)

    type_byte = pack_type_byte(h)
    type_val = Map.fetch!(@packet_type_rev, h.type)

    case type_val do
      1 -> pack_request(type_byte, h)
      2 -> pack_response(type_byte, h)
      3 -> pack_push(type_byte, h)
    end
  end

  @doc """
  Unpacks binary data into a header struct.
  Returns `{:ok, header, remaining_binary}` or `{:error, reason}`.
  """
  @spec unpack(binary()) :: {:ok, t(), binary()} | {:error, term()}
  def unpack(data) when byte_size(data) >= 1 do
    <<type_byte::8, rest::binary>> = data

    type_val = type_byte &&& 0x0F
    verify = (type_byte >>> 4 &&& 0x01) == 1
    gzip = (type_byte >>> 5 &&& 0x01) == 1

    case Map.fetch(@packet_type_map, type_val) do
      {:ok, type} ->
        unpack_by_type(type, verify, gzip, type_byte, rest)

      :error ->
        {:error, {:unknown_packet_type, type_val}}
    end
  end

  # ── pack helpers ──────────────────────────────────────────

  defp pack_type_byte(h) do
    type_val = Map.fetch!(@packet_type_rev, h.type)
    v = if h.verify, do: 1, else: 0
    g = if h.gzip, do: 1, else: 0
    <<type_val ||| v <<< 4 ||| g <<< 5::8>>
  end

  defp pack_request(type_byte, h) do
    [
      type_byte,
      <<h.cmd_code::8>>,
      <<h.request_id::32-big>>,
      <<h.timeout::16-big>>,
      pack_body_length(h.body_length)
    ]
  end

  defp pack_response(type_byte, h) do
    [
      type_byte,
      <<h.cmd_code::8>>,
      <<h.request_id::32-big>>,
      <<h.status_code::8>>,
      pack_body_length(h.body_length)
    ]
  end

  defp pack_push(type_byte, h) do
    [
      type_byte,
      <<h.cmd_code::8>>,
      pack_body_length(h.body_length)
    ]
  end

  defp pack_body_length(len) do
    <<len::24-big>>
  end

  defp validate_body_length!(len) when len <= @max_body_length, do: :ok
  defp validate_body_length!(_len), do: raise("body length exceeds max (#{@max_body_length})")

  # ── unpack helpers ────────────────────────────────────────

  defp unpack_by_type(:request, verify, gzip, _type_byte, data) do
    if byte_size(data) < 10 do
      {:error, :incomplete_header}
    else
      <<cmd_code::8, request_id::32-big, timeout::16-big, body_len_bytes::3-binary, rest::binary>> =
        data

      <<body_len::24-big>> = body_len_bytes

      header = %__MODULE__{
        type: :request,
        verify: verify,
        gzip: gzip,
        cmd_code: cmd_code,
        request_id: request_id,
        timeout: timeout,
        body_length: body_len
      }

      {:ok, header, rest}
    end
  end

  defp unpack_by_type(:response, verify, gzip, _type_byte, data) do
    if byte_size(data) < 9 do
      {:error, :incomplete_header}
    else
      <<cmd_code::8, request_id::32-big, status_code::8, body_len_bytes::3-binary, rest::binary>> =
        data

      <<body_len::24-big>> = body_len_bytes

      header = %__MODULE__{
        type: :response,
        verify: verify,
        gzip: gzip,
        cmd_code: cmd_code,
        request_id: request_id,
        status_code: status_code,
        body_length: body_len
      }

      {:ok, header, rest}
    end
  end

  defp unpack_by_type(:push, verify, gzip, _type_byte, data) do
    if byte_size(data) < 4 do
      {:error, :incomplete_header}
    else
      <<cmd_code::8, body_len_bytes::3-binary, rest::binary>> = data
      <<body_len::24-big>> = body_len_bytes

      header = %__MODULE__{
        type: :push,
        verify: verify,
        gzip: gzip,
        cmd_code: cmd_code,
        body_length: body_len
      }

      {:ok, header, rest}
    end
  end

  @doc """
  Extract optional nonce and signature from data following the body.
  Only called when verify is true.
  Returns `{nonce, signature, remaining}`.
  """
  def unpack_auth_tail(data) do
    <<nonce::64-big, signature::@signature_length-binary, rest::binary>> = data
    {nonce, signature, rest}
  end

  @doc false
  def max_body_length, do: @max_body_length
  @doc false
  def nonce_length, do: @nonce_length
  @doc false
  def signature_length, do: @signature_length
end
