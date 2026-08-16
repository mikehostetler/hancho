defmodule Hancho.Delivery.Adapter do
  @moduledoc false

  alias Hancho.Delivery.{Request, Result}

  @callback dry_run(Request.t(), map()) :: {:ok, Result.t()} | {:error, term()}
  @callback execute(Request.t(), map()) :: {:ok, Result.t()} | {:error, term()}
end
