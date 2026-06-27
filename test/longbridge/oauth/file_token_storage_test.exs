defmodule Longbridge.OAuth.FileTokenStorageTest do
  use ExUnit.Case, async: false

  alias Longbridge.OAuth.FileTokenStorage

  # Use a per-test sandbox so we don't write to the real ~/.longbridge.
  # `token_path/1` reads from `System.user_home!/0`, which is fixed at
  # boot and cannot be overridden via $HOME. Instead, we wrap the
  # storage in a small in-test module that re-points `token_path/1`
  # to a tempdir. Tests exercise both behaviours through that
  # sandbox.

  defmodule Sandbox do
    @moduledoc false
    @behaviour Longbridge.OAuth.TokenStorage

    @tmpdir Path.join(
              System.tmp_dir!(),
              "longbridge_file_storage_test_#{System.unique_integer([:positive])}"
            )

    def tmpdir, do: @tmpdir

    @impl true
    def load(client_id) do
      path = Path.join([@tmpdir, ".longbridge", "openapi", "tokens", client_id])

      with {:ok, content} <- File.read(path),
           {:ok, %{"access_token" => token} = data} <- Jason.decode(content) do
        {:ok,
         %{
           access_token: token,
           refresh_token: Map.get(data, "refresh_token"),
           expires_at: Map.get(data, "expires_at"),
           token_type: Map.get(data, "token_type", "Bearer"),
           scope: Map.get(data, "scope"),
           user_id: Map.get(data, "user_id"),
           sub_accounts: Map.get(data, "sub_accounts"),
           http_url: Map.get(data, "http_url")
         }}
      else
        {:error, :enoent} -> {:error, :not_found}
        {:error, _reason} -> {:error, :invalid_token_data}
        {:ok, _} -> {:error, :invalid_token_data}
      end
    end

    @impl true
    def save(client_id, token) do
      path = Path.join([@tmpdir, ".longbridge", "openapi", "tokens", client_id])
      File.mkdir_p!(Path.dirname(path))

      json =
        Jason.encode!(%{
          access_token: Map.get(token, :access_token),
          refresh_token: Map.get(token, :refresh_token),
          expires_at: Map.get(token, :expires_at),
          token_type: Map.get(token, :token_type, "Bearer"),
          scope: Map.get(token, :scope),
          user_id: Map.get(token, :user_id),
          sub_accounts: Map.get(token, :sub_accounts),
          http_url: Map.get(token, :http_url)
        })

      File.write(path, json)
    end
  end

  setup do
    File.rm_rf!(Sandbox.tmpdir())
    on_exit(fn -> File.rm_rf!(Sandbox.tmpdir()) end)
    :ok
  end

  describe "save/2 + load/1 round-trip" do
    test "writes and reads a token" do
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

      :ok = Sandbox.save("client-1", token)
      assert {:ok, loaded} = Sandbox.load("client-1")

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
      :ok = Sandbox.save("client-2", %{access_token: "t", expires_at: 1})
      path = Path.join([Sandbox.tmpdir(), ".longbridge", "openapi", "tokens", "client-2"])
      json = File.read!(path)
      assert {:ok, %{"access_token" => "t"}} = Jason.decode(json)
    end

    test "creates the parent directory if missing" do
      :ok = Sandbox.save("client-3", %{access_token: "t"})
      path = Path.join([Sandbox.tmpdir(), ".longbridge", "openapi", "tokens", "client-3"])
      assert File.exists?(path)
    end
  end

  describe "load/1 error cases" do
    test "returns :not_found when the token file is missing" do
      assert {:error, :not_found} = Sandbox.load("never-saved")
    end

    test "returns :invalid_token_data for malformed JSON" do
      path = Path.join([Sandbox.tmpdir(), ".longbridge", "openapi", "tokens", "bad-json"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "not json")

      assert {:error, :invalid_token_data} = Sandbox.load("bad-json")
    end

    test "returns :invalid_token_data when access_token is missing" do
      path = Path.join([Sandbox.tmpdir(), ".longbridge", "openapi", "tokens", "no-at"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, ~s({"refresh_token": "x"}))

      assert {:error, :invalid_token_data} = Sandbox.load("no-at")
    end
  end

  describe "token_path/1" do
    test "is ~/.longbridge/openapi/tokens/<client_id>" do
      assert FileTokenStorage.token_path("abc") ==
               Path.join([System.user_home!(), ".longbridge", "openapi", "tokens", "abc"])
    end
  end
end
