# frozen_string_literal: true

module Projects
  class Source
    # Una versione di un tool davvero vista sul progetto, con la sua finestra di attività: da quando è
    # comparsa (first_seen_at = optin) a quando è stata vista l'ultima volta (last_seen_at = optout,
    # tipicamente l'istante prima del passaggio a una versione nuova). Popolata in automatico dall'ingest
    # via Projects::Source.track! (upsert atomico per [fonte, versione]). È la "cronologia / pregresso"
    # della card Monitoring tools. Nome annidato (leaf una parola) invece del composto SourceVersion.
    class Version < ApplicationRecord
      self.table_name = "projects_source_versions"

      belongs_to :source, class_name: "Projects::Source", inverse_of: :versions

      normalizes :version, with: ->(value) { value.to_s.strip }

      validates :version, presence: true, uniqueness: { scope: :source_id }

      # Cronologico: dalla prima comparsa in poi (tie-break su id per un ordine stabile a parità di istante).
      scope :chronological, -> { order(:first_seen_at, :id) }
    end
  end
end
