defmodule F1Bot.ExternalApi.Discord.Commands.Standings do
  @moduledoc "Shared rendering for championship standings embeds (/teams, /drivers)."

  @doc """
  Build a standings embed. `name_fun` extracts the display name from each entry
  (e.g. `& &1.constructor` or `& &1.driver`).
  """
  def embed(title, standings, name_fun, color) do
    lines =
      Enum.map_join(standings, "\n", fn s ->
        pos = String.pad_leading(to_string(s.position), 2)
        "`#{pos}` **#{name_fun.(s)}** — #{format_points(s.points)}"
      end)

    %{type: "rich", color: color, title: title, description: lines}
  end

  defp format_points(p) when is_float(p) do
    if p == Float.round(p), do: p |> trunc() |> to_string(), else: to_string(p)
  end

  defp format_points(p), do: to_string(p)
end
