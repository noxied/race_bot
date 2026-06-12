defmodule F1Bot.ExternalApi.Discord.Commands.Common do
  @moduledoc "Shared helpers for slash command handlers."
  alias Nostrum.Struct.Interaction

  @doc "Response is ephemeral unless the `public:true` option was supplied."
  def response_flags(interaction) do
    if public_option?(interaction), do: [], else: [:ephemeral]
  end

  defp public_option?(%Interaction{data: %{options: options}}) when is_list(options) do
    Enum.any?(options, fn o -> o.name == "public" and o.value == true end)
  end

  defp public_option?(_), do: false

  @doc "The invoking user's Discord locale string (or nil)."
  def locale(%Interaction{locale: locale}), do: locale
  def locale(_), do: nil

  @doc "Regional-indicator flag emoji from an ISO 3166-1 alpha-2 country code (e.g. \"ES\" -> 🇪🇸)."
  def flag_emoji(code) when is_binary(code) and byte_size(code) == 2 do
    case String.upcase(code) do
      <<a, b>> when a in ?A..?Z and b in ?A..?Z ->
        <<0x1F1E6 + (a - ?A)::utf8, 0x1F1E6 + (b - ?A)::utf8>>

      _ ->
        ""
    end
  end

  def flag_emoji(_), do: ""

  @doc """
  Discord dynamic timestamp for a session: `<t:unix:f>` (short date + time) when a
  time is known, otherwise `<t:unix:D>` (date only). Renders in each viewer's timezone.
  """
  def session_timestamp(date_str, time_str) do
    case to_unix(date_str, time_str) do
      {unix, true} -> "<t:#{unix}:f>"
      {unix, false} -> "<t:#{unix}:D>"
      :error -> date_str || "?"
    end
  end

  @doc "Discord relative timestamp `<t:unix:R>` (e.g. \"in 2 days\"), auto-updating."
  def relative_timestamp(date_str, time_str) do
    case to_unix(date_str, time_str) do
      {unix, _} -> "<t:#{unix}:R>"
      :error -> ""
    end
  end

  @doc "Discord date-only timestamp `<t:unix:D>`."
  def date_timestamp(date_str) do
    case to_unix(date_str, nil) do
      {unix, _} -> "<t:#{unix}:D>"
      :error -> date_str || "?"
    end
  end

  # Returns {unix_seconds, has_time?} or :error.
  defp to_unix(date_str, time_str) do
    case date_str && Date.from_iso8601(date_str) do
      {:ok, date} ->
        case parse_time(time_str) do
          nil -> {date |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_unix(), false}
          time -> {date |> DateTime.new!(time, "Etc/UTC") |> DateTime.to_unix(), true}
        end

      _ ->
        :error
    end
  end

  defp parse_time(time_str) when is_binary(time_str) do
    case Time.from_iso8601(time_str) do
      {:ok, time} -> time
      _ -> nil
    end
  end

  defp parse_time(_), do: nil
end
