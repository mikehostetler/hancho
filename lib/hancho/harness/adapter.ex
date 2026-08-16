defmodule Hancho.Harness.Adapter do
  @moduledoc false

  alias Hancho.Harness.{Request, Result}

  @callback doctor(map()) :: {:ok, map()} | {:error, term()}
  @callback version(map()) :: {:ok, map()} | {:error, term()}
  @callback run(Request.t(), map()) :: {:ok, Result.t()} | {:error, term()}
end
