defmodule Longbridge.OAuth.FileTokenStorage do
  @moduledoc """
  Default file-based OAuth token storage.

  Tokens are written as JSON to
  `~/.longbridge/openapi/tokens/<client_id>` — matching the path
  used by the Rust and Go SDKs.

  This is the storage used by `Longbridge.OAuth` when no custom
  `storage:` option is passed.
  """

  @behaviour Longbridge.OAuth.TokenStorage

  @impl true
  def load(client_id) do
    path = token_path(client_id)

    with {:ok, content} <- File.read(path),
         {:ok, %{"access_token" => token} = data} <- JSON.decode(content) do
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
      {:error, reason} -> {:error, reason}
      {:ok, _} -> {:error, :invalid_token_data}
    end
  end

  @impl true
  def save(client_id, token) do
    path = token_path(client_id)
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    # Restrict the token directory and the token file itself: access/refresh
    # tokens are long-lived credentials. Mirrors the upstream Go SDK, which
    # writes with MkdirAll(dir, 0700) and WriteFile(path, data, 0600).
    :ok = File.chmod!(dir, 0o700)

    json =
      JSON.encode!(%{
        access_token: Map.get(token, :access_token),
        refresh_token: Map.get(token, :refresh_token),
        expires_at: Map.get(token, :expires_at),
        token_type: Map.get(token, :token_type, "Bearer"),
        scope: Map.get(token, :scope),
        user_id: Map.get(token, :user_id),
        sub_accounts: Map.get(token, :sub_accounts),
        http_url: Map.get(token, :http_url)
      })

    :ok = File.write(path, json)
    :ok = File.chmod!(path, 0o600)
    :ok
  end

  @doc """
  Returns the on-disk path that this storage uses for a given
  `client_id`. Mirrors `Longbridge.OAuth.token_path/1`.
  """
  @spec token_path(String.t()) :: String.t()
  def token_path(client_id) do
    Path.join([System.user_home!(), ".longbridge", "openapi", "tokens", client_id])
  end
end
