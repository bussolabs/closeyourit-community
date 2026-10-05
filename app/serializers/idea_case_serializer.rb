# frozen_string_literal: true

# Case di un'idea per la CLI: titolo + descrizione, con backlink `idea_id`. Nessun autore
# (i case sono contenuto dell'idea, non discussione — vedi Ideas::Case).
class IdeaCaseSerializer < ApplicationSerializer
  attributes :id, :idea_id, :title, :description, :created_at, :updated_at
end
