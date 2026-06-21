defmodule Longbridge.Protocol.HeaderTest do
  use ExUnit.Case, async: true

  alias Longbridge.Protocol.Header

  describe "pack/1 + unpack/1 round-trips" do
    test "request with verify=false, gzip=false" do
      h = %Header{
        type: :request,
        verify: false,
        gzip: false,
        body_length: 0,
        cmd_code: 11,
        request_id: 1,
        timeout: 5000
      }

      assert {:ok, ^h, <<>>} = Header.unpack(IO.iodata_to_binary(Header.pack(h)))
    end

    test "response with status_code" do
      h = %Header{
        type: :response,
        verify: false,
        gzip: false,
        body_length: 0,
        cmd_code: 2,
        request_id: 7,
        status_code: 0
      }

      assert {:ok, ^h, <<>>} = Header.unpack(IO.iodata_to_binary(Header.pack(h)))
    end

    test "push" do
      h = %Header{
        type: :push,
        verify: false,
        gzip: false,
        body_length: 0,
        cmd_code: 101
      }

      assert {:ok, ^h, <<>>} = Header.unpack(IO.iodata_to_binary(Header.pack(h)))
    end

    test "verify=true and gzip=true are both encoded into the type byte" do
      h = %Header{
        type: :request,
        verify: true,
        gzip: true,
        body_length: 0,
        cmd_code: 1,
        request_id: 1,
        timeout: 1000
      }

      data = IO.iodata_to_binary(Header.pack(h))
      assert {:ok, %{verify: true, gzip: true}, <<>>} = Header.unpack(data)
    end

    test "24-bit body length boundary" do
      for len <- [0, 1, 255, 16_777_215] do
        h = %Header{
          type: :request,
          verify: false,
          gzip: false,
          body_length: len,
          cmd_code: 0,
          request_id: 0,
          timeout: 0
        }

        assert {:ok, %Header{body_length: ^len}, <<>>} =
                 Header.unpack(IO.iodata_to_binary(Header.pack(h)))
      end
    end
  end

  describe "pack/1 validation" do
    test "body_length above 16 MB raises" do
      h = %Header{
        type: :request,
        verify: false,
        gzip: false,
        body_length: 16_777_216,
        cmd_code: 0,
        request_id: 0,
        timeout: 0
      }

      assert_raise RuntimeError, ~r/body length exceeds max/, fn -> Header.pack(h) end
    end
  end

  describe "unpack/1 error paths" do
    test "empty data raises FunctionClauseError (guard fails)" do
      assert_raise FunctionClauseError, fn -> Header.unpack(<<>>) end
    end

    test "unknown packet type returns {:error, {:unknown_packet_type, n}}" do
      # type nibble = 7, not in {1, 2, 3}
      assert Header.unpack(<<0b00000111>>) == {:error, {:unknown_packet_type, 7}}
    end

    test "request with only the type byte returns :incomplete_header" do
      assert Header.unpack(<<0b00000001>>) == {:error, :incomplete_header}
    end

    test "response with only the type byte returns :incomplete_header" do
      assert Header.unpack(<<0b00000010>>) == {:error, :incomplete_header}
    end

    test "push with only the type byte returns :incomplete_header" do
      assert Header.unpack(<<0b00000011>>) == {:error, :incomplete_header}
    end

    test "request with 9 bytes (need 11) returns :incomplete_header" do
      # 1 type byte + 8 bytes (cmd + req_id, missing timeout + body_len)
      assert Header.unpack(<<0b00000001, 0, 0, 0, 0, 1, 0, 0, 0>>) == {:error, :incomplete_header}
    end

    test "response with 8 bytes (need 10) returns :incomplete_header" do
      assert Header.unpack(<<0b00000010, 0, 0, 0, 0, 1, 0, 0>>) == {:error, :incomplete_header}
    end

    test "push with 3 bytes (need 5) returns :incomplete_header" do
      assert Header.unpack(<<0b00000011, 0, 0>>) == {:error, :incomplete_header}
    end
  end

  describe "unpack_auth_tail/1" do
    test "extracts nonce, signature, and remaining data" do
      nonce = 0x0123_4567_89AB_CDEF

      signature =
        <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
          0x99, 0x00>>

      data = <<nonce::64-big, signature::binary, "rest">>

      assert {^nonce, ^signature, "rest"} = Header.unpack_auth_tail(data)
    end
  end

  describe "length accessors" do
    test "max_body_length/0 is 16 MiB" do
      assert Header.max_body_length() == 16_777_215
    end

    test "nonce_length/0 is 8" do
      assert Header.nonce_length() == 8
    end

    test "signature_length/0 is 16" do
      assert Header.signature_length() == 16
    end
  end
end
