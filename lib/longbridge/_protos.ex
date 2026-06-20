defmodule Longbridge.Protos do
  @moduledoc false

  use Protox,
    files: [
      "protos/control.proto",
      "protos/error.proto",
      "protos/api.proto",
      "protos/subscribe.proto"
    ],
    paths: ["protos"]
end
