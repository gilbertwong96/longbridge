defmodule Longbridge.ContentContextTest do
  use ExUnit.Case, async: false

  alias Longbridge.{Config, ContentContext}

  defp start_fake_http_server(handler) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    parent = self()

    pid =
      spawn(fn ->
        send(parent, {:ready, :ok})

        loop = fn loop ->
          case :gen_tcp.accept(listen, 5_000) do
            {:ok, socket} ->
              case :gen_tcp.recv(socket, 0, 5_000) do
                {:ok, data} ->
                  handler.(data, socket)
                  :gen_tcp.close(socket)

                _ ->
                  :gen_tcp.close(socket)
              end

              loop.(loop)

            {:error, :timeout} ->
              :ok

            {:error, _} ->
              :ok
          end
        end

        loop.(loop)
      end)

    receive do
      {:ready, :ok} -> :ok
    after
      2_000 -> raise "fake server failed to start"
    end

    %{port: port, pid: pid, socket: listen}
  end

  defp stop_fake_http_server(%{socket: socket, pid: pid}) do
    Process.exit(pid, :kill)
    :gen_tcp.close(socket)
  end

  defp http_ok(body) do
    "HTTP/1.1 200 OK\r\n" <>
      "Content-Type: application/json\r\n" <>
      "Content-Length: #{byte_size(body)}\r\n" <>
      "Connection: close\r\n\r\n" <> body
  end

  defp config_with(port) do
    Config.new(
      token: "test-token",
      app_key: "test-key",
      app_secret: "test-secret",
      http_url: "http://127.0.0.1:#{port}"
    )
  end

  defp parse_request(request) do
    [head, body] = String.split(request, "\r\n\r\n", parts: 2)
    [line | _] = String.split(head, "\r\n")
    [method, path, _version] = String.split(line, " ", parts: 3)
    {method, path, body || ""}
  end

  describe "my_topics/2" do
    test "queries with the options as query parameters" do
      response = %{
        "items" => [
          %{"id" => "1", "title" => "My first post"},
          %{"id" => "2", "title" => "My second post"}
        ]
      }

      server =
        start_fake_http_server(fn request, socket ->
          {method, _path, _body} = parse_request(request)
          assert method == "GET"
          assert request =~ "/v1/content/topics/mine"
          assert request =~ "page=2"
          assert request =~ "size=25"
          assert request =~ "topic_type=article"

          payload = JSON.encode!(%{"code" => 0, "data" => response})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok,
              [
                %{"id" => "1", "title" => "My first post"},
                %{"id" => "2", "title" => "My second post"}
              ]} =
               ContentContext.my_topics(config_with(server.port),
                 page: 2,
                 size: 25,
                 topic_type: "article"
               )

      stop_fake_http_server(server)
    end

    test "accepts a flat list response" do
      server =
        start_fake_http_server(fn _request, socket ->
          payload =
            JSON.encode!(%{"code" => 0, "data" => [%{"id" => "1", "title" => "post"}]})

          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, [%{"id" => "1"}]} = ContentContext.my_topics(config_with(server.port))

      stop_fake_http_server(server)
    end

    test "returns empty list when data is missing or malformed" do
      server =
        start_fake_http_server(fn _request, socket ->
          payload = JSON.encode!(%{"code" => 0, "data" => %{"unexpected" => "shape"}})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, []} = ContentContext.my_topics(config_with(server.port))

      stop_fake_http_server(server)
    end
  end

  describe "create_topic/2" do
    test "POSTs the topic body and returns the new topic id" do
      server =
        start_fake_http_server(fn request, socket ->
          {method, _path, body} = parse_request(request)
          assert method == "POST"
          assert request =~ "/v1/content/topics"

          decoded = JSON.decode!(body)
          assert decoded["title"] == "Hello world"
          assert decoded["body"] == "First post body"
          assert decoded["topic_type"] == "post"
          assert decoded["tickers"] == ["AAPL.US"]
          assert decoded["hashtags"] == ["elixir"]

          payload = JSON.encode!(%{"code" => 0, "data" => %{"id" => "topic-123"}})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, "topic-123"} =
               ContentContext.create_topic(config_with(server.port),
                 title: "Hello world",
                 body: "First post body",
                 topic_type: "post",
                 tickers: ["AAPL.US"],
                 hashtags: ["elixir"]
               )

      stop_fake_http_server(server)
    end

    test "accepts a flat id in the response" do
      server =
        start_fake_http_server(fn _request, socket ->
          payload = JSON.encode!(%{"code" => 0, "data" => %{"id" => "abc-def"}})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, "abc-def"} =
               ContentContext.create_topic(config_with(server.port),
                 title: "t",
                 body: "b"
               )

      stop_fake_http_server(server)
    end

    test "coerces a non-binary id to a string" do
      server =
        start_fake_http_server(fn _request, socket ->
          payload = JSON.encode!(%{"code" => 0, "data" => %{"id" => 42}})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, "42"} =
               ContentContext.create_topic(config_with(server.port),
                 title: "t",
                 body: "b"
               )

      stop_fake_http_server(server)
    end

    test "accepts a nested item.id in the response" do
      server =
        start_fake_http_server(fn _request, socket ->
          payload = JSON.encode!(%{"code" => 0, "data" => %{"item" => %{"id" => "nested-id"}}})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, "nested-id"} =
               ContentContext.create_topic(config_with(server.port),
                 title: "t",
                 body: "b"
               )

      stop_fake_http_server(server)
    end

    test "coerces a nested non-binary id to a string" do
      server =
        start_fake_http_server(fn _request, socket ->
          payload = JSON.encode!(%{"code" => 0, "data" => %{"item" => %{"id" => 7}}})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, "7"} =
               ContentContext.create_topic(config_with(server.port),
                 title: "t",
                 body: "b"
               )

      stop_fake_http_server(server)
    end
  end

  describe "topic_detail/2" do
    test "queries the topic detail endpoint by ID" do
      server =
        start_fake_http_server(fn request, socket ->
          {method, path, _body} = parse_request(request)
          assert method == "GET"
          assert path == "/v1/content/topics/topic-123"

          payload =
            JSON.encode!(%{
              "code" => 0,
              "data" => %{"id" => "topic-123", "title" => "Hello", "body" => "First post body"}
            })

          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok,
              %{
                "id" => "topic-123",
                "title" => "Hello",
                "body" => "First post body"
              }} = ContentContext.topic_detail(config_with(server.port), "topic-123")

      stop_fake_http_server(server)
    end
  end

  describe "list_topic_replies/3" do
    test "queries the comments endpoint with pagination" do
      server =
        start_fake_http_server(fn request, socket ->
          {method, _path, _body} = parse_request(request)
          assert method == "GET"
          assert request =~ "/v1/content/topics/topic-123/comments"
          assert request =~ "page=2"
          assert request =~ "size=10"

          payload =
            JSON.encode!(%{
              "code" => 0,
              "data" => %{
                "items" => [
                  %{"id" => "r1", "body" => "first reply"},
                  %{"id" => "r2", "body" => "second reply"}
                ]
              }
            })

          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok,
              [
                %{"id" => "r1"},
                %{"id" => "r2"}
              ]} =
               ContentContext.list_topic_replies(config_with(server.port), "topic-123",
                 page: 2,
                 size: 10
               )

      stop_fake_http_server(server)
    end

    test "accepts a flat list response" do
      server =
        start_fake_http_server(fn _request, socket ->
          payload = JSON.encode!(%{"code" => 0, "data" => [%{"id" => "r1"}]})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, [%{"id" => "r1"}]} =
               ContentContext.list_topic_replies(config_with(server.port), "topic-123")

      stop_fake_http_server(server)
    end
  end

  describe "create_topic_reply/3" do
    test "POSTs the reply body" do
      server =
        start_fake_http_server(fn request, socket ->
          {method, path, body} = parse_request(request)
          assert method == "POST"
          assert path == "/v1/content/topics/topic-123/comments"

          decoded = JSON.decode!(body)
          assert decoded["body"] == "Nice post!"
          assert decoded["reply_to_id"] == "r1"

          payload =
            JSON.encode!(%{"code" => 0, "data" => %{"id" => "r-new", "body" => "Nice post!"}})

          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, %{"id" => "r-new", "body" => "Nice post!"}} =
               ContentContext.create_topic_reply(config_with(server.port), "topic-123",
                 body: "Nice post!",
                 reply_to_id: "r1"
               )

      stop_fake_http_server(server)
    end
  end

  describe "news/3" do
    test "GETs the news endpoint with the symbol in the path" do
      response = %{
        "list" => [
          %{"id" => "n1", "title" => "Apple hits ATH", "summary" => "...", "source" => "Reuters"}
        ]
      }

      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "GET /v1/content/AAPL.US/news"

          :gen_tcp.send(socket, http_ok(JSON.encode!(%{"code" => 0, "data" => response})))
        end)

      assert {:ok, ^response} = ContentContext.news(config_with(server.port), "AAPL.US")
      stop_fake_http_server(server)
    end

    test "forwards opts as query params" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "/v1/content/AAPL.US/news"
          assert request =~ "page_size=20"

          :gen_tcp.send(socket, http_ok(JSON.encode!(%{"code" => 0, "data" => %{}})))
        end)

      assert {:ok, _} = ContentContext.news(config_with(server.port), "AAPL.US", page_size: 20)
      stop_fake_http_server(server)
    end
  end

  describe "topics/3" do
    test "GETs the topics endpoint with the symbol in the path" do
      response = %{"list" => [%{"topic_id" => "t1", "title" => "Bull case"}]}

      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "GET /v1/content/AAPL.US/topics"

          :gen_tcp.send(socket, http_ok(JSON.encode!(%{"code" => 0, "data" => response})))
        end)

      assert {:ok, ^response} = ContentContext.topics(config_with(server.port), "AAPL.US")
      stop_fake_http_server(server)
    end

    test "forwards opts as query params" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "/v1/content/AAPL.US/topics"
          assert request =~ "page=2"

          :gen_tcp.send(socket, http_ok(JSON.encode!(%{"code" => 0, "data" => %{}})))
        end)

      assert {:ok, _} = ContentContext.topics(config_with(server.port), "AAPL.US", page: 2)
      stop_fake_http_server(server)
    end
  end

  describe "announcements/2" do
    test "returns :not_implemented" do
      assert {:error, :not_implemented} = ContentContext.announcements(%Config{}, "AAPL.US")
    end
  end

  describe "http_url per-call override" do
    test "topic_detail/3 hits the URL passed in opts" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "GET /v1/content/topics/topic-123"
          :gen_tcp.send(socket, http_ok(JSON.encode!(%{"code" => 0, "data" => %{}})))
        end)

      config =
        Config.new(
          token: "tok",
          app_key: "k",
          app_secret: "s",
          http_url: "http://127.0.0.1:1"
        )

      assert {:ok, _} =
               ContentContext.topic_detail(config, "topic-123",
                 http_url: "http://127.0.0.1:#{server.port}"
               )

      stop_fake_http_server(server)
    end

    test "my_topics/3 preserves :params while forwarding :http_url override" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "GET /v1/content/topics/mine"
          assert request =~ "page=2"
          :gen_tcp.send(socket, http_ok(JSON.encode!(%{"code" => 0, "data" => []})))
        end)

      config =
        Config.new(
          token: "tok",
          app_key: "k",
          app_secret: "s",
          http_url: "http://127.0.0.1:1"
        )

      assert {:ok, _} =
               ContentContext.my_topics(config, [page: 2],
                 http_url: "http://127.0.0.1:#{server.port}"
               )

      stop_fake_http_server(server)
    end
  end
end
