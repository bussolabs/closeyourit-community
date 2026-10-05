# frozen_string_literal: true

module Ui
  class MetricTileComponentPreview < ViewComponent::Preview
    # Tile statica neutra (nessuna soglia superata → zinc-900).
    def neutral = render(Ui::MetricTileComponent.new(label: "New today", value: 0, icon: "plus"))

    # Severity: il valore prende un colore semantico quando conta qualcosa.
    def severity_red = render(Ui::MetricTileComponent.new(label: "Unresolved errors", value: 7, icon: "bug", value_color: :red))
    def severity_amber = render(Ui::MetricTileComponent.new(label: "Open tickets", value: 3, icon: "ticket", value_color: :amber))
    def severity_violet = render(Ui::MetricTileComponent.new(label: "Slow queries", value: 2, icon: "gauge", value_color: :violet))

    # Cliccabile: link verso l'index già filtrata (hover + focus-ring da tastiera).
    def clickable
      render(Ui::MetricTileComponent.new(
               label: "Unresolved errors", value: 7, icon: "bug", value_color: :red,
               href: "/member/monitoring/error", aria_label: "Vedi gli errori non risolti",
               test_id: "kpi-errors", value_test_id: "stat-errors"))
    end

    # Non cliccabile con tooltip nativo (es. "silent projects" nella dashboard).
    def with_tooltip
      render(Ui::MetricTileComponent.new(
               label: "Silent", value: 1, icon: "eye-off", value_color: :amber,
               tooltip: "Sembrano sani solo per assenza di dati"))
    end

    # Caption + delta opzionali sotto il valore (nessun layout shift).
    def with_caption_and_delta
      render(Ui::MetricTileComponent.new(
               label: "Unresolved errors", value: 7, icon: "bug", value_color: :red,
               delta: "+2 vs ieri", delta_color: :rose, caption: "ultime 24h"))
    end

    # Riga di tile in una grid (come la sezione Signals della dashboard).
    def signals_row
      render_with_template(template: "ui/metric_tile_component_preview/signals_row")
    end
  end
end
