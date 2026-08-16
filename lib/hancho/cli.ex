defmodule Hancho.CLI do
  @moduledoc "The escript entry point for Hancho."

  alias Hancho.CLI.Output
  alias Hancho.CLI.{Options, Router}
  alias Hancho.Error

  @spec main([String.t()]) :: no_return()
  def main(args) do
    status =
      try do
        run(args)
      rescue
        error in Error ->
          Output.error(error, json: json_requested?(args))
          error.exit_status

        error ->
          if debug_requested?(args) do
            reraise error, __STACKTRACE__
          else
            Output.error("Internal failure. Run again with --debug for details.",
              json: json_requested?(args)
            )

            70
          end
      end

    System.halt(status)
  end

  @spec run([String.t()]) :: non_neg_integer()
  def run(args) do
    {clean_args, options} = Options.parse!(args)
    result = Router.execute(clean_args, options)
    Output.print(result, options)
    result.status
  end

  defp json_requested?(args), do: "--json" in args
  defp debug_requested?(args), do: "--debug" in args
end
