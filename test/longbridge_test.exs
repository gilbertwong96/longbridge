defmodule LongbridgeTest do
  use ExUnit.Case

  alias Longbridge.{Config, Protocol}
  alias Longbridge.Control.V1, as: Ctrl
  alias Longbridge.Protocol.Header
  alias Longbridge.Quote.V1, as: QuoteV1

  test "config defaults" do
    config = Config.new()
    assert config.quote_ws_url == "wss://openapi-quote.longbridge.com"
    assert config.trade_ws_url == "wss://openapi-trade.longbridge.com"
    assert config.china == false
    assert config.heartbeat_interval == 15_000
  end

  test "config china endpoints" do
    config = Config.new(china: true)
    assert config.quote_ws_url == "wss://openapi-quote.longbridge.cn"
    assert config.trade_ws_url == "wss://openapi-trade.longbridge.cn"
  end

  test "config custom endpoints" do
    config = Config.new(quote_ws_url: "wss://custom.example.com")
    assert config.quote_ws_url == "wss://custom.example.com"
  end

  test "protocol handshake bytes" do
    handshake = Protocol.handshake()
    assert byte_size(handshake) == 2
    assert handshake == <<0b00010001, 0b00001001>>
  end

  test "protocol command predicates" do
    assert Protocol.control?(0)
    assert Protocol.control?(3)
    refute Protocol.control?(10)

    assert Protocol.close?(0)
    assert Protocol.heartbeat?(1)
    assert Protocol.auth?(2)
    assert Protocol.reconnect?(3)
  end

  test "protocol status names" do
    assert Protocol.status_name(0) == "SUCCESS"
    assert Protocol.status_name(5) == "UNAUTHENTICATED"
    assert Protocol.status_name(99) == "UNKNOWN"
  end

  test "header packs request" do
    header = %Header{
      type: :request,
      verify: false,
      gzip: false,
      cmd_code: 11,
      request_id: 1,
      timeout: 5000,
      body_length: 100
    }

    data = IO.iodata_to_binary(Header.pack(header))
    assert byte_size(data) == 11
    # type=1, cmd=11, req_id=1, timeout=5000(0x1388), body_len=100(0x000064)
    assert <<0b00000001, 11, 0, 0, 0, 1, 0x13, 0x88, 0, 0, 100>> = data
  end

  test "header unpack request" do
    data = <<0b00000001, 11, 0::16, 1::16, 5000::16, 0::16, 100::8, "hello">>

    assert {:ok, header, rest} = Header.unpack(data)
    assert header.type == :request
    assert header.cmd_code == 11
    assert header.request_id == 1
    assert header.timeout == 5000
    assert header.body_length == 100
    assert rest == "hello"
  end

  test "header packs response" do
    header = %Header{
      type: :response,
      cmd_code: 11,
      request_id: 42,
      status_code: 0,
      body_length: 64
    }

    data = IO.iodata_to_binary(Header.pack(header))
    assert byte_size(data) == 10
    # type=2, cmd=11, req_id=42, status=0, body_len=64(0x000040)
    assert <<0b00000010, 11, 0, 0, 0, 42, 0, 0, 0, 64>> = data
  end

  test "header packs push" do
    header = %Header{
      type: :push,
      cmd_code: 101,
      body_length: 256
    }

    data = IO.iodata_to_binary(Header.pack(header))
    assert byte_size(data) == 5
    assert <<0b00000011, 101, 0, 1, 0>> = data
  end

  test "header round-trip request" do
    header = %Header{
      type: :request,
      cmd_code: 11,
      request_id: 999,
      timeout: 30_000,
      body_length: 512
    }

    packed = IO.iodata_to_binary(Header.pack(header))
    assert {:ok, unpacked, <<>>} = Header.unpack(packed)
    assert unpacked.type == :request
    assert unpacked.cmd_code == 11
    assert unpacked.request_id == 999
    assert unpacked.timeout == 30_000
    assert unpacked.body_length == 512
  end

  test "header round-trip response" do
    header = %Header{
      type: :response,
      cmd_code: 2,
      request_id: 1,
      status_code: 0,
      body_length: 0
    }

    packed = IO.iodata_to_binary(Header.pack(header))
    assert {:ok, unpacked, <<>>} = Header.unpack(packed)
    assert unpacked.type == :response
    assert unpacked.status_code == 0
  end

  test "header round-trip push" do
    header = %Header{
      type: :push,
      cmd_code: 101,
      body_length: 1024
    }

    packed = IO.iodata_to_binary(Header.pack(header))
    assert {:ok, unpacked, <<>>} = Header.unpack(packed)
    assert unpacked.type == :push
    assert unpacked.cmd_code == 101
  end

  test "protobuf control messages are generated" do
    assert is_struct(%Ctrl.AuthRequest{})
    assert is_struct(%Ctrl.AuthResponse{})
    assert is_struct(%Ctrl.Heartbeat{})

    auth = %Ctrl.AuthRequest{token: "test-token", metadata: %{}}
    assert auth.token == "test-token"
  end

  test "protobuf quote messages are generated" do
    assert is_struct(%QuoteV1.SecurityQuote{})
    assert is_struct(%QuoteV1.SecurityCandlestickRequest{})
    assert is_struct(%QuoteV1.PushQuote{})

    quote = %QuoteV1.SecurityQuote{symbol: "AAPL.US", last_done: "150.50"}
    assert quote.symbol == "AAPL.US"
    assert quote.last_done == "150.50"
  end

  test "protobuf control round-trip" do
    original = %Ctrl.AuthRequest{token: "token123", metadata: %{}}
    {:ok, encoded, _size} = Protox.encode(original)
    decoded = Protox.decode!(IO.iodata_to_binary(encoded), Ctrl.AuthRequest)
    assert decoded.token == "token123"
  end

  test "protobuf quote round-trip" do
    original = %QuoteV1.SecurityQuote{
      symbol: "700.HK",
      last_done: "528.50",
      volume: 5_400_000
    }

    {:ok, encoded, _size} = Protox.encode(original)
    decoded = Protox.decode!(IO.iodata_to_binary(encoded), QuoteV1.SecurityQuote)
    assert decoded.symbol == "700.HK"
    assert decoded.last_done == "528.50"
    assert decoded.volume == 5_400_000
  end
end
