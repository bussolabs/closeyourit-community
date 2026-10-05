module Ideas
  # Case di un'idea: un esempio/scenario concreto (titolo + descrizione) che arricchisce la
  # proposta. Entità figlia ripetibile, aggiunta una alla volta sulla pagina idea (come
  # Ideas::Comment). È contenuto dell'idea → nessun autore proprio; il congelamento
  # (converted/archived) è garantito dai service. cases_count denormalizzato sull'idea.
  class Case < ApplicationRecord
    # touch: un caso d'uso aggiunto è movimento dell'idea, e l'ultimo movimento ordina la bacheca
    # (CYRA-360). Il voto invece non tocca niente: dice interesse, non priorità.
    belongs_to :idea,
               class_name: "Ideas::Idea",
               inverse_of: :cases,
               counter_cache: :cases_count,
               touch: true

    normalizes :title, with: ->(value) { value.to_s.strip }
    normalizes :description, with: ->(value) { value.to_s.strip }

    validates :title, presence: true
  end
end
