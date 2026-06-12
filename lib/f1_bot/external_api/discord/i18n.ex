defmodule F1Bot.ExternalApi.Discord.I18n do
  @moduledoc """
  Minimal i18n for slash command responses and Discord description localizations.

  Internal language atoms: :en, :pt, :fr, :it, :de, :es (English is the fallback).
  Discord locale codes (e.g. "pt-BR", "en-US") are normalised to these atoms.
  """

  @fallback :en

  # Discord locale code -> internal language atom (used for description localizations).
  @discord_locales [
    {"en-US", :en},
    {"en-GB", :en},
    {"pt-BR", :pt},
    {"fr", :fr},
    {"it", :it},
    {"de", :de},
    {"es-ES", :es}
  ]

  @strings %{
    # ---- generic ----
    data_not_ready: %{
      en: "F1 data is still loading, please try again in a moment.",
      pt: "Os dados de F1 ainda estão a carregar, tenta outra vez daqui a um instante.",
      fr: "Les données F1 se chargent encore, réessaie dans un instant.",
      it: "I dati F1 si stanno ancora caricando, riprova tra un istante.",
      de: "Die F1-Daten werden noch geladen, bitte versuche es gleich erneut.",
      es: "Los datos de F1 aún se están cargando, inténtalo de nuevo en un momento."
    },
    none_found: %{
      en: "Nothing to show right now.",
      pt: "Nada para mostrar de momento.",
      fr: "Rien à afficher pour le moment.",
      it: "Niente da mostrare al momento.",
      de: "Momentan nichts anzuzeigen.",
      es: "Nada que mostrar por ahora."
    },
    # ---- option labels ----
    opt_public_desc: %{
      en: "Respond publicly in the channel (default: only you can see it)",
      pt: "Responder publicamente no canal (por defeito: só tu vês)",
      fr: "Répondre publiquement dans le salon (par défaut : visible par toi seul)",
      it: "Rispondi pubblicamente nel canale (predefinito: visibile solo a te)",
      de: "Öffentlich im Kanal antworten (Standard: nur für dich sichtbar)",
      es: "Responder públicamente en el canal (por defecto: solo tú lo ves)"
    },
    # ---- /nextrace ----
    nextrace_cmd_desc: %{
      en: "Show the next Formula 1 race weekend",
      pt: "Mostra o próximo fim de semana de Fórmula 1",
      fr: "Affiche le prochain week-end de Formule 1",
      it: "Mostra il prossimo weekend di Formula 1",
      de: "Zeigt das nächste Formel-1-Rennwochenende",
      es: "Muestra el próximo fin de semana de Fórmula 1"
    },
    nextrace_title: %{
      en: "Next Race",
      pt: "Próxima Corrida",
      fr: "Prochaine Course",
      it: "Prossima Gara",
      de: "Nächstes Rennen",
      es: "Próxima Carrera"
    },
    nextrace_none: %{
      en: "No upcoming race found in the calendar.",
      pt: "Não há nenhuma corrida futura no calendário.",
      fr: "Aucune course à venir dans le calendrier.",
      it: "Nessuna gara in programma nel calendario.",
      de: "Kein bevorstehendes Rennen im Kalender gefunden.",
      es: "No hay ninguna carrera próxima en el calendario."
    },
    field_round: %{en: "Round", pt: "Ronda", fr: "Manche", it: "Round", de: "Lauf", es: "Ronda"},
    field_circuit: %{
      en: "Circuit",
      pt: "Circuito",
      fr: "Circuit",
      it: "Circuito",
      de: "Strecke",
      es: "Circuito"
    },
    field_sessions: %{
      en: "Sessions (UTC)",
      pt: "Sessões (UTC)",
      fr: "Séances (UTC)",
      it: "Sessioni (UTC)",
      de: "Sessions (UTC)",
      es: "Sesiones (UTC)"
    },
    field_countdown: %{
      en: "Starts in",
      pt: "Começa em",
      fr: "Débute dans",
      it: "Inizia tra",
      de: "Beginnt in",
      es: "Empieza en"
    },
    countdown_value: %{
      en: "%{days}d %{hours}h %{minutes}m",
      pt: "%{days}d %{hours}h %{minutes}m",
      fr: "%{days}j %{hours}h %{minutes}m",
      it: "%{days}g %{hours}h %{minutes}m",
      de: "%{days}T %{hours}h %{minutes}m",
      es: "%{days}d %{hours}h %{minutes}m"
    },
    # ---- /calendar ----
    calendar_cmd_desc: %{
      en: "Show the full Formula 1 season calendar",
      pt: "Mostra o calendário completo da época de Fórmula 1",
      fr: "Affiche le calendrier complet de la saison de Formule 1",
      it: "Mostra il calendario completo della stagione di Formula 1",
      de: "Zeigt den kompletten Formel-1-Saisonkalender",
      es: "Muestra el calendario completo de la temporada de Fórmula 1"
    },
    calendar_title: %{
      en: "%{year} F1 Calendar",
      pt: "Calendário F1 %{year}",
      fr: "Calendrier F1 %{year}",
      it: "Calendario F1 %{year}",
      de: "F1-Kalender %{year}",
      es: "Calendario F1 %{year}"
    },
    # ---- /help ----
    help_cmd_desc: %{
      en: "List the available commands and how to use them",
      pt: "Lista os comandos disponíveis e como usá-los",
      fr: "Liste les commandes disponibles et comment les utiliser",
      it: "Elenca i comandi disponibili e come usarli",
      de: "Listet die verfügbaren Befehle und ihre Verwendung auf",
      es: "Lista los comandos disponibles y cómo usarlos"
    },
    help_title: %{
      en: "F1 Bot — Commands",
      pt: "F1 Bot — Comandos",
      fr: "F1 Bot — Commandes",
      it: "F1 Bot — Comandi",
      de: "F1 Bot — Befehle",
      es: "F1 Bot — Comandos"
    },
    ping_cmd_desc: %{
      en: "Check the bot's latency",
      pt: "Verifica a latência do bot",
      fr: "Vérifie la latence du bot",
      it: "Controlla la latenza del bot",
      de: "Zeigt die Latenz des Bots an",
      es: "Comprueba la latencia del bot"
    },
    ping_pong: %{
      en: "🏓 Pong! Latency: %{ms} ms",
      pt: "🏓 Pong! Latência: %{ms} ms",
      fr: "🏓 Pong ! Latence : %{ms} ms",
      it: "🏓 Pong! Latenza: %{ms} ms",
      de: "🏓 Pong! Latenz: %{ms} ms",
      es: "🏓 Pong! Latencia: %{ms} ms"
    },
    help_public_note: %{
      en: "Tip: add `public:True` to any command to post the answer in the channel for everyone.",
      pt: "Dica: adiciona `public:True` a qualquer comando para publicar a resposta no canal para todos.",
      fr: "Astuce : ajoute `public:True` à une commande pour publier la réponse dans le salon.",
      it: "Suggerimento: aggiungi `public:True` a un comando per pubblicare la risposta nel canale.",
      de: "Tipp: Füge `public:True` zu einem Befehl hinzu, um die Antwort im Kanal zu posten.",
      es: "Consejo: añade `public:True` a cualquier comando para publicar la respuesta en el canal."
    }
  }

  # Session key -> localized label.
  @sessions %{
    free_practice_1: %{en: "FP1", pt: "TL1", fr: "EL1", it: "PL1", de: "FP1", es: "PL1"},
    free_practice_2: %{en: "FP2", pt: "TL2", fr: "EL2", it: "PL2", de: "FP2", es: "PL2"},
    free_practice_3: %{en: "FP3", pt: "TL3", fr: "EL3", it: "PL3", de: "FP3", es: "PL3"},
    sprint_qualifying: %{
      en: "Sprint Quali",
      pt: "Quali Sprint",
      fr: "Quali Sprint",
      it: "Quali Sprint",
      de: "Sprint-Quali",
      es: "Clasif. Sprint"
    },
    sprint: %{en: "Sprint", pt: "Sprint", fr: "Sprint", it: "Sprint", de: "Sprint", es: "Sprint"},
    qualifying: %{
      en: "Qualifying",
      pt: "Qualificação",
      fr: "Qualifications",
      it: "Qualifiche",
      de: "Qualifying",
      es: "Clasificación"
    },
    race: %{en: "Race", pt: "Corrida", fr: "Course", it: "Gara", de: "Rennen", es: "Carrera"}
  }

  @doc "Translate `key` for a Discord locale string or internal lang atom, with `%{}` bindings."
  def t(key, locale, bindings \\ %{}) do
    lang = normalize(locale)

    @strings
    |> Map.get(key, %{})
    |> Map.get(lang)
    |> case do
      nil -> Map.get(Map.get(@strings, key, %{}), @fallback, to_string(key))
      str -> str
    end
    |> interpolate(bindings)
  end

  @doc "Localized label for a session key."
  def session_label(session_key, locale) do
    lang = normalize(locale)
    s = Map.get(@sessions, session_key, %{})
    Map.get(s, lang) || Map.get(s, @fallback) || to_string(session_key)
  end

  @doc """
  Build a Discord `*_localizations` map (Discord locale code -> string) for a key,
  used for command/description localization.
  """
  def localizations(key) do
    for {discord_locale, lang} <- @discord_locales, into: %{} do
      {discord_locale, t(key, lang)}
    end
  end

  @doc "Normalise a Discord locale code (or atom) to an internal language atom."
  def normalize(locale) when is_atom(locale) and locale in [:en, :pt, :fr, :it, :de, :es],
    do: locale

  def normalize(locale) when is_binary(locale) do
    cond do
      String.starts_with?(locale, "pt") -> :pt
      String.starts_with?(locale, "fr") -> :fr
      String.starts_with?(locale, "it") -> :it
      String.starts_with?(locale, "de") -> :de
      String.starts_with?(locale, "es") -> :es
      String.starts_with?(locale, "en") -> :en
      true -> @fallback
    end
  end

  def normalize(_), do: @fallback

  defp interpolate(str, bindings) when map_size(bindings) == 0, do: str

  defp interpolate(str, bindings) do
    Enum.reduce(bindings, str, fn {k, v}, acc ->
      String.replace(acc, "%{#{k}}", to_string(v))
    end)
  end
end
