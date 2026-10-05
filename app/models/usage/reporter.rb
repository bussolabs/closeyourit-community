# frozen_string_literal: true

module Usage
  # CYSK-29 — «questo progetto sta mandando usage di questo kind da T»: il dispositivo
  # anti-falso-positivo. Lo scanner rifiuta di giudicare un kind il cui reporter è vivo da meno
  # della finestra minima, o che ha troncato l'ultima finestra (`truncated_last_window`): un flag
  # che nessuno legge produce esattamente il danno che doveva prevenire.
  class Reporter < ApplicationRecord
    self.table_name = "usage_reporters"

    belongs_to :project, class_name: "Projects::Project"

    validates :kind, inclusion: { in: ::Usage::Symbol::KINDS }
    validates :sdk_name, presence: true
    validates :environment, presence: true
  end
end
