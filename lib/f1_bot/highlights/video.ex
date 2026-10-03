defmodule F1Bot.Highlights.Video do
  @moduledoc "A catalogued highlights video (one row per YouTube video)."
  use Ecto.Schema
  import Ecto.Changeset

  schema("highlights") do
    field(:series, :string, default: "F1")
    field(:year, :integer)
    field(:gp_name, :string)
    field(:session_type, :string)
    field(:video_id, :string)
    field(:url, :string)
    field(:title, :string)
    field(:published_at, :utc_datetime)

    timestamps()
  end

  @fields [:series, :year, :gp_name, :session_type, :video_id, :url, :title, :published_at]

  def changeset(video \\ %__MODULE__{}, params) do
    video
    |> cast(params, @fields)
    |> validate_required([:series, :video_id, :url])
  end
end
