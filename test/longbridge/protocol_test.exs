defmodule Longbridge.ProtocolTest do
  use ExUnit.Case, async: true

  alias Longbridge.{Protocol, Protocol.Header}

  describe "handshake/0" do
    test "returns the fixed 2-byte handshake" do
      assert Protocol.handshake() == <<0b00010001, 0b00001001>>
      assert byte_size(Protocol.handshake()) == 2
    end
  end

  describe "command predicates" do
    test "control?/1 is true for 0..3" do
      for cmd <- 0..3, do: assert(Protocol.control?(cmd), "expected control?/1 true for #{cmd}")
    end

    test "control?/1 is false for >= 4" do
      refute Protocol.control?(4)
      refute Protocol.control?(100)
      refute Protocol.control?(255)
    end

    test "close?/1" do
      assert Protocol.close?(0)
      refute Protocol.close?(1)
    end

    test "heartbeat?/1" do
      assert Protocol.heartbeat?(1)
      refute Protocol.heartbeat?(0)
    end

    test "auth?/1" do
      assert Protocol.auth?(2)
      refute Protocol.auth?(3)
    end

    test "reconnect?/1" do
      assert Protocol.reconnect?(3)
      refute Protocol.reconnect?(4)
    end
  end

  describe "command code accessors" do
    test "control commands" do
      assert Protocol.cmd_close() == 0
      assert Protocol.cmd_heartbeat() == 1
      assert Protocol.cmd_auth() == 2
      assert Protocol.cmd_reconnect() == 3
    end
  end

  describe "status code accessors" do
    test "returns the documented status constants" do
      assert Protocol.status_success() == 0
      assert Protocol.status_server_timeout() == 1
      assert Protocol.status_bad_request() == 3
      assert Protocol.status_unauthenticated() == 5
      assert Protocol.status_server_internal_error() == 7
    end
  end

  describe "status_name/1" do
    test "covers every documented status code" do
      assert Protocol.status_name(0) == "SUCCESS"
      assert Protocol.status_name(1) == "SERVER_TIMEOUT"
      assert Protocol.status_name(2) == "CLIENT_TIMEOUT"
      assert Protocol.status_name(3) == "BAD_REQUEST"
      assert Protocol.status_name(4) == "BAD_RESPONSE"
      assert Protocol.status_name(5) == "UNAUTHENTICATED"
      assert Protocol.status_name(6) == "PERMISSION_DENIED"
      assert Protocol.status_name(7) == "SERVER_INTERNAL_ERROR"
      assert Protocol.status_name(8) == "CLIENT_INTERNAL_ERROR"
    end

    test "returns UNKNOWN for codes outside the table" do
      assert Protocol.status_name(9) == "UNKNOWN"
      assert Protocol.status_name(99) == "UNKNOWN"
      assert Protocol.status_name(255) == "UNKNOWN"
    end
  end

  describe "pack/2 + unpack/1 round-trip" do
    test "request packet" do
      header = %Header{
        type: :request,
        verify: false,
        gzip: false,
        body_length: 0,
        cmd_code: 11,
        request_id: 1,
        timeout: 5000
      }

      body = "hello"
      data = IO.iodata_to_binary(Protocol.pack(header, body))

      assert {:ok, %Header{body_length: 5, type: :request, cmd_code: 11}, "hello", <<>>} =
               Protocol.unpack(data)
    end

    test "response packet" do
      header = %Header{
        type: :response,
        verify: false,
        gzip: false,
        body_length: 0,
        cmd_code: 11,
        request_id: 42,
        status_code: 0
      }

      body = <<>>

      data = IO.iodata_to_binary(Protocol.pack(header, body))

      assert {:ok, %Header{type: :response, status_code: 0, request_id: 42}, <<>>, <<>>} =
               Protocol.unpack(data)
    end

    test "push packet" do
      header = %Header{
        type: :push,
        verify: false,
        gzip: false,
        body_length: 0,
        cmd_code: 101
      }

      body = ""

      data = IO.iodata_to_binary(Protocol.pack(header, body))

      assert {:ok, %Header{type: :push, cmd_code: 101, request_id: nil}, <<>>, <<>>} =
               Protocol.unpack(data)
    end

    test "overwrites body_length with the actual iodata length" do
      header = %Header{
        type: :request,
        verify: false,
        gzip: false,
        body_length: 0,
        cmd_code: 1,
        request_id: 1,
        timeout: 1000
      }

      data = IO.iodata_to_binary(Protocol.pack(header, "abcdef"))
      assert {:ok, %Header{body_length: 6}, "abcdef", <<>>} = Protocol.unpack(data)
    end
  end

  describe "unpack/1 error paths" do
    test "incomplete body returns :incomplete_body" do
      # header says body_length=10, but only 3 bytes follow
      data = <<0b00000001, 11, 0, 0, 0, 1, 0x13, 0x88, 0, 0, 10, "abc">>
      assert Protocol.unpack(data) == {:error, :incomplete_body}
    end

    test "unpacks header and returns remaining bytes for the next packet" do
      # 11-byte request header with body_length=3, followed by 3 bytes of body,
      # then 5 more bytes of a new (incomplete) packet.
      data =
        <<0b00000001, 11, 0, 0, 0, 1, 0x13, 0x88, 0, 0, 3, "abc", 0xDE, 0xAD, 0xBE, 0xEF, 0x00>>

      assert {:ok, %Header{body_length: 3, type: :request}, "abc",
              <<0xDE, 0xAD, 0xBE, 0xEF, 0x00>>} =
               Protocol.unpack(data)
    end

    test "passes through Header.unpack errors" do
      # unknown packet type nibble = 7
      assert Protocol.unpack(<<0b00000111>>) == {:error, {:unknown_packet_type, 7}}
    end

    test "incomplete request header" do
      # request type but only the type byte
      assert Protocol.unpack(<<0b00000001>>) == {:error, :incomplete_header}
    end

    test "incomplete response header" do
      # response type but only the type byte
      assert Protocol.unpack(<<0b00000010>>) == {:error, :incomplete_header}
    end

    test "incomplete push header" do
      # push type but only the type byte
      assert Protocol.unpack(<<0b00000011>>) == {:error, :incomplete_header}
    end
  end

  describe "unpack/1 gzip decompression" do
    test "decompresses body when header.gzip is true" do
      payload = "this is a long enough body to be worth compressing"
      gzipped = :zlib.gzip(payload)

      header = %Header{
        type: :response,
        verify: false,
        gzip: true,
        body_length: byte_size(gzipped),
        cmd_code: 11,
        request_id: 7,
        status_code: 0
      }

      data = IO.iodata_to_binary(Protocol.pack(header, gzipped))
      assert {:ok, %Header{gzip: true}, ^payload, <<>>} = Protocol.unpack(data)
    end

    test "leaves body untouched when header.gzip is false" do
      payload = "plain protobuf body, no compression"

      header = %Header{
        type: :response,
        verify: false,
        gzip: false,
        body_length: byte_size(payload),
        cmd_code: 11,
        request_id: 8,
        status_code: 0
      }

      data = IO.iodata_to_binary(Protocol.pack(header, payload))
      assert {:ok, %Header{gzip: false}, ^payload, <<>>} = Protocol.unpack(data)
    end

    test "raises if gzip flag is set but body is not a valid gzip stream" do
      # Build a header claiming gzip=true but pass raw protobuf bytes.
      # The first byte 0x0a is not a valid gzip magic byte (gzip = 0x1f 0x8b),
      # so :zlib.gunzip will fail.
      payload = <<10, 7, "AAPL.US">>

      header = %Header{
        type: :response,
        verify: false,
        gzip: true,
        body_length: byte_size(payload),
        cmd_code: 18,
        request_id: 9,
        status_code: 0
      }

      data = IO.iodata_to_binary(Protocol.pack(header, payload))

      assert_raise RuntimeError, ~r/gzip decompression failed/, fn ->
        Protocol.unpack(data)
      end
    end
  end
end
