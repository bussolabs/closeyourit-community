# frozen_string_literal: true

module Ui
  # Saved views, the last section of the toolbar's View menu (CYRA-902, CYRA-924): a searchable list of the
  # user's views (click = apply via GET with the saved params, X = delete) and an entry that opens a
  # native <dialog> to save the current filters as a new view.
  #
  # Without JS the apply links are real <a> and the modal form is a plain POST; the list search and the
  # modal are Stimulus (ui--saved-views + ui--dialog).
  class SavedViewsComponent < BaseComponent
    # `presets` (CYRA-395) = viste già pronte, offerte a chi non ne ha ancora nessuna: una funzione
    # che serve a domare mille ticket non può chiedere di immaginarsela da zero. Sono link con dei
    # filtri, non righe salvate: nessuno si ritrova roba in casa che non ha creato.
    def initialize(resource_type:, views:, index_helper:, current_filters: {}, presets: [],
                   test_id: "saved-views")
      @resource_type = resource_type.to_s
      @views = views
      @presets = Array(presets)
      @index_helper = index_helper
      @current_filters = current_filters || {}
      @test_id = test_id
    end

    private

    def allowed_keys = SavedView::FILTER_KEYS.fetch(@resource_type, [])

    # Filtri correnti attivi (solo chiavi ammesse, valori non vuoti) → hidden del form + riepilogo modale.
    def active_filters
      allowed_keys.each_with_object({}) do |key, acc|
        value = raw_value(key)
        acc[key] = value if value.present? || (SavedView.exact_filter?(@resource_type, key) && value.is_a?(String))
      end
    end

    def raw_value(key)
      value = @current_filters[key]
      return value if SavedView.exact_filter?(@resource_type, key) && value.is_a?(String)
      return value.reject(&:blank?) if value.is_a?(Array)

      value.to_s.strip.presence
    end

    def filter_label(key) = t("shared.saved_views.filters.#{key}", default: key.to_s.humanize)

    # q / sort / range → il valore grezzo (la chiave/direzione); view → il nome del raggruppamento;
    # multi-select → conteggio dei valori scelti.
    def filter_display(key, value)
      return t("shared.saved_views.view_values.#{value}", default: value) if key == "view"

      scalar_filter?(key) ? value : "×#{Array(value).size}"
    end

    def scalar_filter?(key) = %w[q sort range].include?(key) || key.to_s.end_with?("_sort")

    # symbolize_keys: i segmenti dinamici (es. :project_id delle risorse nested) si riempiono solo da
    # chiavi simbolo; i filtri salvati hanno chiavi stringa. Già sanificati alla allowlist per-risorsa.
    def applied_path(filters) = helpers.public_send(@index_helper, filters.symbolize_keys)

    def create_path = helpers.member_saved_views_path

    def delete_path(view) = helpers.member_saved_view_path(view)
  end
end
