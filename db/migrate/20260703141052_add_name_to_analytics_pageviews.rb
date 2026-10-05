class AddNameToAnalyticsPageviews < ActiveRecord::Migration[8.1]
  def change
    # Nome dell'evento: "pageview" per le visite pagina (default → i record esistenti restano pageview),
    # il nome dell'evento per i custom event (goals/conversioni). Le metriche di traffico filtrano
    # name = "pageview"; le conversioni contano gli eventi che matchano un goal.
    add_column :analytics_pageviews, :name, :string, null: false, default: "pageview"
    add_index :analytics_pageviews, %i[project_id name occurred_at],
              order: { occurred_at: :desc }, name: "idx_analytics_pageviews_goal"
  end
end
