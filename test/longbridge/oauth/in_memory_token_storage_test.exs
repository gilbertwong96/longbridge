defmodule Longbridge.OAuth.InMemoryTokenStorageTest do
  use ExUnit.Case, async: false

  alias Longbridge.OAuth.InMemoryTokenStorage

  setup do
    # Ensure a clean table per test.
    :ok = InMemoryTokenStorage.reset()
    on_exit(fn -> :ok = InMemoryTokenStorage.reset() end)
    :ok
  end

  describe "save/2 + load/1 round-trip" do
    test "persists and retrieves a token" do
      token = %{
        access_token: "access-1",
        refresh_token: "refresh-1",
        expires_at: 1_730_000_000,
        token_type: "Bearer",
        scope: "trade:read",
        user_id: "user-1"
      }

      assert :ok = InMemoryTokenStorage.save("client-A", token)
      assert {:ok, ^token} = InMemoryTokenStorage.load("client-A")
    end

    test "overwrites an earlier token for the same client_id" do
      first = %{access_token: "old"}
      second = %{access_token: "new"}
      :ok = InMemoryTokenStorage.save("client", first)
      :ok = InMemoryTokenStorage.save("client", second)
      assert {:ok, ^second} = InMemoryTokenStorage.load("client")
    end

    test "returns :not_found when the client_id has no token" do
      assert {:error, :not_found} = InMemoryTokenStorage.load("unknown-client")
    end

    test "supports multiple client_ids in the same table" do
      a = %{access_token: "a-token"}
      b = %{access_token: "b-token"}
      :ok = InMemoryTokenStorage.save("client-a", a)
      :ok = InMemoryTokenStorage.save("client-b", b)
      assert {:ok, ^a} = InMemoryTokenStorage.load("client-a")
      assert {:ok, ^b} = InMemoryTokenStorage.load("client-b")
    end

    test "load/1 returns :not_found before any save" do
      assert {:error, :not_found} = InMemoryTokenStorage.load("never-touched")
    end
  end

  describe "list_client_ids/0" do
    test "returns the stored client_ids" do
      :ok = InMemoryTokenStorage.save("client-a", %{access_token: "a"})
      :ok = InMemoryTokenStorage.save("client-b", %{access_token: "b"})
      ids = InMemoryTokenStorage.list_client_ids()
      assert "client-a" in ids
      assert "client-b" in ids
    end

    test "returns [] before any save" do
      assert [] == InMemoryTokenStorage.list_client_ids()
    end
  end

  describe "delete/1" do
    test "removes a stored token" do
      :ok = InMemoryTokenStorage.save("client", %{access_token: "x"})
      assert {:ok, _} = InMemoryTokenStorage.load("client")
      :ok = InMemoryTokenStorage.delete("client")
      assert {:error, :not_found} = InMemoryTokenStorage.load("client")
    end

    test "is idempotent on missing client_id" do
      assert :ok = InMemoryTokenStorage.delete("never-existed")
    end

    test "is idempotent before any save" do
      assert :ok = InMemoryTokenStorage.delete("any-id")
    end
  end

  describe "reset/0" do
    test "clears all stored tokens" do
      :ok = InMemoryTokenStorage.save("a", %{access_token: "1"})
      :ok = InMemoryTokenStorage.save("b", %{access_token: "2"})
      :ok = InMemoryTokenStorage.reset()
      assert {:error, :not_found} = InMemoryTokenStorage.load("a")
      assert {:error, :not_found} = InMemoryTokenStorage.load("b")
    end

    test "is idempotent when called twice" do
      :ok = InMemoryTokenStorage.reset()
      assert :ok = InMemoryTokenStorage.reset()
    end
  end

  describe "integration with OAuth module" do
    test "loads a token that was saved through the OAuth flow" do
      token = %{
        access_token: "fresh-token",
        refresh_token: "fresh-refresh",
        expires_at: System.system_time(:second) + 3600
      }

      :ok = InMemoryTokenStorage.save("integ-client", token)

      assert {:ok, config} =
               Longbridge.OAuth.load_token("integ-client",
                 storage: InMemoryTokenStorage
               )

      assert config.token == "fresh-token"
    end
  end
end
