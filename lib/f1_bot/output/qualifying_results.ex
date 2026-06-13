defmodule F1Bot.Output.QualifyingResults do
  @moduledoc """
  Builds a qualifying-segment leaderboard embed from each driver's best lap in
  the current session, posted at the end of a segment (Q1/Q2/Q3).
  """
  alias F1Bot.DataTransform.Format

  @color 0xE10600

  @doc "Embed for the given segment (1, 2, 3), or nil if there are no lap times yet."
  def embed(segment) do
    case leaderboard() do
      [] -> nil
      board -> %{type: "rich", color: @color, title: title(segment), description: format_board(board, segment)}
    end
  end

  defp title(1), do: "🏁 Q1 Results (top 15 advance)"
  defp title(2), do: "🏁 Q2 Results (top 10 advance)"
  defp title(3), do: "🏁 Starting Grid"
  defp title(n), do: "🏁 Segment #{n} Results"

  # Position after which drivers are eliminated; nil = no cut (final grid).
  defp cutoff(1), do: 15
  defp cutoff(2), do: 10
  defp cutoff(_), do: nil

  defp leaderboard do
    F1Bot.driver_list()
    |> Enum.map(fn driver ->
      case F1Bot.driver_summary(driver.driver_number) do
        {:ok, summary} -> {driver, summary.stats.lap_time.fastest.value}
        _ -> {driver, nil}
      end
    end)
    |> Enum.reject(fn {_driver, value} -> is_nil(value) end)
    |> Enum.sort_by(fn {_driver, value} -> Timex.Duration.to_milliseconds(value) end)
  end

  defp format_board(board, segment) do
    cut = cutoff(segment)

    board
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {{driver, value}, pos} ->
      row =
        "`P#{String.pad_leading(to_string(pos), 2)}` **#{driver.driver_abbr}** #{Format.format_lap_time(value)}"

      if cut && pos == cut, do: row <> "\n⬇️ **Eliminated**", else: row
    end)
  end
end
