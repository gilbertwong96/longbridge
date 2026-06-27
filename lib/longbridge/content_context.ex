defmodule Longbridge.ContentContext do
  @moduledoc """
  Content context.

  Provides access to community topics, replies, and per-symbol news.
  The per-symbol endpoints (`news/3`, `topics/3`) take a stock symbol;
  the topic-management endpoints (`my_topics/2`, `create_topic/2`,
  `topic_detail/2`, `list_topic_replies/3`, `create_topic_reply/3`)
  operate on the current authenticated user.

  All functions accept a `Longbridge.Config` struct and return
  `{:ok, data} | {:error, reason}` tuples.

  ## Usage

      config = Longbridge.Config.new(...)

      {:ok, news} = Longbridge.ContentContext.news(config, "AAPL.US")
      {:ok, mine} = Longbridge.ContentContext.my_topics(config, page: 1)
      {:ok, id}   = Longbridge.ContentContext.create_topic(config, title: "...", body: "...")
      {:ok, replies} = Longbridge.ContentContext.list_topic_replies(config, "topic-id", page: 1)
  """

  alias Longbridge.{Config, HTTPClient}

  @my_topics_path "/v1/content/topics/mine"
  @topics_path "/v1/content/topics"
  @topic_path_prefix "/v1/content/topics/"
  @topic_comments_suffix "/comments"

  @doc """
  Lists news articles for a symbol.

  `symbol` is required (e.g. `"AAPL.US"`, `"700.HK"`).

  ## Options

  - `:lang` — language (`"zh-CN"`, `"zh-HK"`, `"en"`)
  """
  @spec news(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def news(%Config{} = config, symbol, opts \\ []) when is_binary(symbol) do
    params = HTTPClient.build_query(opts)
    HTTPClient.request_json(:get, "/v1/content/#{symbol}/news", "", config, params: params)
  end

  @doc """
  Lists community topics for a symbol.

  `symbol` is required.

  ## Options

  - `:page` — page cursor
  - `:page_size` — results per page
  """
  @spec topics(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def topics(%Config{} = config, symbol, opts \\ []) when is_binary(symbol) do
    params = HTTPClient.build_query(opts)
    HTTPClient.request_json(:get, "/v1/content/#{symbol}/topics", "", config, params: params)
  end

  @doc """
  Lists topics created by the current authenticated user.

  Endpoint: `GET /v1/content/topics/mine`

  ## Options

    * `:page` — integer page number, default 1.
    * `:size` — integer records per page, range 1..500, default 50.
    * `:topic_type` — `"article" | "post"`, optional filter.
  """
  @spec my_topics(Config.t(), keyword()) :: {:ok, list()} | {:error, term()}
  def my_topics(%Config{} = config, opts \\ []) do
    params = HTTPClient.build_query(opts)

    case HTTPClient.request_json(:get, @my_topics_path, "", config, params: params) do
      {:ok, items} when is_list(items) -> {:ok, items}
      {:ok, %{"items" => items}} when is_list(items) -> {:ok, items}
      {:ok, _} -> {:ok, []}
      error -> error
    end
  end

  @doc """
  Creates a new community topic.

  Endpoint: `POST /v1/content/topics`

  Returns `{:ok, topic_id}` on success.

  ## Required options

    * `:title` — topic title string.
    * `:body` — topic body in Markdown.

  ## Optional

    * `:topic_type` — `"article"` (long-form) or `"post"` (default short).
    * `:tickers` — list of related symbols, max 10.
    * `:hashtags` — list of hashtag names, max 5.
  """
  @spec create_topic(Config.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def create_topic(%Config{} = config, opts) do
    body = Jason.encode!(Map.new(opts))

    case HTTPClient.request_json(:post, @topics_path, body, config) do
      {:ok, %{"id" => id}} when is_binary(id) -> {:ok, id}
      {:ok, %{"item" => %{"id" => id}}} when is_binary(id) -> {:ok, id}
      {:ok, %{"id" => id}} -> {:ok, to_string(id)}
      {:ok, %{"item" => %{"id" => id}}} -> {:ok, to_string(id)}
      error -> error
    end
  end

  @doc """
  Returns details for a single topic by ID.

  Endpoint: `GET /v1/content/topics/{id}`
  """
  @spec topic_detail(Config.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def topic_detail(%Config{} = config, id) when is_binary(id) do
    HTTPClient.request_json(:get, @topic_path_prefix <> id, "", config)
  end

  @doc """
  Lists replies on a topic.

  Endpoint: `GET /v1/content/topics/{topic_id}/comments`

  ## Options

    * `:page` — integer page number, default 1.
    * `:size` — integer records per page, range 1..50, default 20.
  """
  @spec list_topic_replies(Config.t(), String.t(), keyword()) ::
          {:ok, list()} | {:error, term()}
  def list_topic_replies(%Config{} = config, topic_id, opts \\ []) when is_binary(topic_id) do
    params = HTTPClient.build_query(opts)
    path = @topic_path_prefix <> topic_id <> @topic_comments_suffix

    case HTTPClient.request_json(:get, path, "", config, params: params) do
      {:ok, items} when is_list(items) -> {:ok, items}
      {:ok, %{"items" => items}} when is_list(items) -> {:ok, items}
      {:ok, _} -> {:ok, []}
      error -> error
    end
  end

  @doc """
  Posts a reply to a topic.

  Endpoint: `POST /v1/content/topics/{topic_id}/comments`

  ## Required options

    * `:body` — reply text (plain text only, Markdown not rendered).

  ## Optional

    * `:reply_to_id` — ID of a reply to respond to (omit for top-level reply).
  """
  @spec create_topic_reply(Config.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def create_topic_reply(%Config{} = config, topic_id, opts) when is_binary(topic_id) do
    body = Jason.encode!(Map.new(opts))
    path = @topic_path_prefix <> topic_id <> @topic_comments_suffix
    HTTPClient.request_json(:post, path, body, config)
  end

  @doc """
  Lists company announcements for a symbol.

  The upstream OpenAPI does not currently expose announcements as a REST
  endpoint; the topic listing (`topics/2`) is the closest equivalent.

  Returns `{:error, :not_implemented}` to make the absence explicit.
  """
  @spec announcements(Config.t(), String.t()) :: {:error, :not_implemented}
  def announcements(%Config{}, _symbol), do: {:error, :not_implemented}
end
