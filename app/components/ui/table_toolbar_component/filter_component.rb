# frozen_string_literal: true

module Ui
  class TableToolbarComponent < BaseComponent
    # Chip di un filtro della toolbar: wrappa il contenuto del caller (tipicamente un
    # Ui::SelectComponent) con la X di rimozione. Visibile solo se il param `key` ha valori
    # nei params correnti (URL diretto o vista salvata) o se aggiunto a runtime dal menu
    # "Filtri" (Stimulus ui--filter-bar). La visibilità è SOLO la classe `hidden`: il select
    # nativo resta nel DOM col suo name — senza valori selezionati non inquina la query.
    class FilterComponent < BaseComponent
      attr_reader :key, :label

      # CYRA-883 — `active:` overrides the params check, for a filter whose param is always in the
      # address (the remembered range) but that only counts as set away from its default.
      def initialize(key:, label:, chip_test_id: nil, active: nil)
        @key = key.to_s
        @label = label
        @chip_test_id = chip_test_id
        @active = active
      end

      # Attivo se il param (scalare o array) ha valori non blank — stesso contratto di
      # Listable#filter_ids, così chip e controller Rails leggono lo stesso dato.
      def active?
        return @active unless @active.nil?

        Array(helpers.params[@key]).reject(&:blank?).any?
      end

      private

      def chip_test_id = @chip_test_id || "filter-chip-#{@key}"
    end
  end
end
