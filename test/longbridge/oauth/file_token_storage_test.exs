defmodule Longbridge.OAuth.FileTokenStorageTest do
  use ExUnit.Case, async: false

  alias Longbridge.OAuth.FileTokenStorage

  # Use unique client_ids per test so we can clean up without
  # touching real ~/.longbridge tokens.
  defp unique_client_id(prefix \\ "ftst") do
    "#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp cleanup(client_id) do
    File.rm(FileTokenStorage.token_path(client_id))
  end

  describe "save/2 + load/1 round-trip" do
    test "writes and reads a token" do
      client_id = unique_client_id()

      token = %{
        access_token: "secret-token",
        refresh_token: "refresh-token",
        expires_at: 1_700_000_000,
        token_type: "Bearer",
        scope: "trade:read",
        user_id: "user-1",
        sub_accounts: ["acc-1", "acc-2"],
        http_url: "https://api.longbridge.com"
      }

      :ok = FileTokenStorage.save(client_id, token)
      on_exit(fn -> cleanup(client_id) end)

      assert {:ok, loaded} = FileTokenStorage.load(client_id)
      assert loaded.access_token == "secret-token"
      assert loaded.refresh_token == "refresh-token"
      assert loaded.expires_at == 1_700_000_000
      assert loaded.token_type == "Bearer"
      assert loaded.scope == "trade:read"
      assert loaded.user_id == "user-1"
      assert loaded.sub_accounts == ["acc-1", "acc-2"]
      assert loaded.http_url == "https://api.longbridge.com"
    end

    test "writes JSON to the expected path" do
      client_id = unique_client_id()
      :ok = FileTokenStorage.save(client_id, %{access_token: "t", expires_at: 1})
      on_exit(fn -> cleanup(client_id) end)

      path = FileTokenStorage.token_path(client_id)
      assert File.exists?(path)

      json = File.read!(path)
      assert {:ok, %{"access_token" => "t"}} = Jason.decode(json)
    end

    test "creates the parent directory if missing" do
      client_id = unique_client_id()
      path = FileTokenStorage.token_path(client_id)
      File.rm_rf!(path)

      :ok = FileTokenStorage.save(client_id, %{access_token: "t"})
      on_exit(fn -> cleanup(client_id) end)

      assert File.exists?(path)
      assert File.dir?(Path.dirname(path))
    end

    test "overwrites an existing token" do
      client_id = unique_client_id()
      :ok = FileTokenStorage.save(client_id, %{access_token: "v1"})
      :ok = FileTokenStorage.save(client_id, %{access_token: "v2"})
      on_exit(fn -> cleanup(client_id) end)

      assert {:ok, %{access_token: "v2"}} = FileTokenStorage.load(client_id)
    end

    test "writes token_type: Bearer by default when not provided" do
      client_id = unique_client_id()
      :ok = FileTokenStorage.save(client_id, %{access_token: "t"})
      on_exit(fn -> cleanup(client_id) end)

      assert {:ok, %{token_type: "Bearer"}} = FileTokenStorage.load(client_id)
    end
  end

  describe "load/1 error cases" do
    test "returns :not_found when the token file is missing" do
      client_id = unique_client_id("never")
      File.rm(FileTokenStorage.token_path(client_id))
      assert {:error, :not_found} = FileTokenStorage.load(client_id)
    end

    test "returns the Jason.DecodeError for malformed JSON" do
      client_id = unique_client_id("bad-json")
      path = FileTokenStorage.token_path(client_id)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "not json")
      on_exit(fn -> cleanup(client_id) end)

      assert {:error, %Jason.DecodeError{}} = FileTokenStorage.load(client_id)
    end

    test "returns :invalid_token_data when access_token is missing" do
      client_id = unique_client_id("no-at")
      path = FileTokenStorage.token_path(client_id)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, ~s({"refresh_token": "x"}))
      on_exit(fn -> cleanup(client_id) end)

      assert {:error, :invalid_token_data} = FileTokenStorage.load(client_id)
    end

    test "loads a token with empty access_token as-is (downstream check)" do
      client_id = unique_client_id("empty-at")
      path = FileTokenStorage.token_path(client_id)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, ~s({"access_token": ""}))
      on_exit(fn -> cleanup(client_id) end)

      # The storage doesn't validate the access_token contents;
      # an empty string is treated as a valid (but useless) token.
      # Validation is the caller's responsibility.
      assert {:ok, %{access_token: ""}} = FileTokenStorage.load(client_id)
    end

    test "returns {:error, reason} for IO read errors" do
      # Simulate IO error by pointing the token path at a path
      # we can't read. We replace the target file with a directory,
      # which makes File.read return {:error, :eisdir} on POSIX.
      client_id = unique_client_id("fs-err")
      path = FileTokenStorage.token_path(client_id)
      File.rm_rf!(path)
      File.mkdir_p!(path)
      on_exit(fn -> File.rm_rf!(path) end)

      assert {:error, _reason} = FileTokenStorage.load(client_id)
    end
  end

  describe "token_path/1" do
    test "is ~/.longbridge/openapi/tokens/<client_id>" do
      assert FileTokenStorage.token_path("abc") ==
               Path.join([System.user_home!(), ".longbridge", "openapi", "tokens", "abc"])
    end

    test "preserves the full client_id in the path" do
      client_id = "with-dashes_and_underscores.123"
      assert String.contains?(FileTokenStorage.token_path(client_id), client_id)
    end
  end
end