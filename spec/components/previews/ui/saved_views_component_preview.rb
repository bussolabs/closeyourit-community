# frozen_string_literal: true

module Ui
  class SavedViewsComponentPreview < ViewComponent::Preview
    # Double leggero: il componente accede solo a id/name/filters (duck-typed, nessun case/when
    # sulla classe) — niente record persistiti, pattern Ui::EntityMarkComponentPreview::Sample.
    SampleView = Struct.new(:id, :name, :filters) do
      def to_param = id.to_s
    end

    # Dropdown popolato + filtri correnti attivi (riepilogo mostrato nel modale "aggiungi vista").
    def with_views
      render(Ui::SavedViewsComponent.new(
               resource_type: "tickets",
               views: [
                 SampleView.new("1", "I miei bug aperti", { "status_id" => "open", "kind" => "bug" }),
                 SampleView.new("2", "Assegnati a me", { "assignee_id" => "me" })
               ],
               index_helper: :list_member_tickets_path,
               current_filters: { "status_id" => "open", "q" => "crash" }
             ))
    end

    # Nessuna vista salvata ancora + nessun filtro attivo (branch vuoto lista + riepilogo).
    def empty
      render(Ui::SavedViewsComponent.new(
               resource_type: "tickets",
               views: [],
               index_helper: :list_member_tickets_path
             ))
    end
  end
end
