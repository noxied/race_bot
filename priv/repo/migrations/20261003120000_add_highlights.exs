defmodule F1Bot.Repo.Migrations.AddHighlights do
  use Ecto.Migration

  def change do
    create table("highlights") do
      add :series, :string, null: false, default: "F1"
      add :year, :integer
      add :gp_name, :string
      add :session_type, :string
      add :video_id, :string, null: false
      add :url, :string, null: false
      add :title, :string
      add :published_at, :utc_datetime

      timestamps()
    end

    create index("highlights", [:video_id], unique: true)
    create index("highlights", [:series, :gp_name, :year, :session_type])
  end
end
