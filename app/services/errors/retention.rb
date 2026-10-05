# frozen_string_literal: true

module Errors
  # Giorni di conservazione degli eventi errore di un progetto. La regola (nearest-wins progetto →
  # org → god globale → default di sistema) vive tutta in Monitoring::Retention: qui resta solo il
  # nome del dominio, per chiamanti e viste.
  module Retention
    module_function

    def for(project, global_days: :unset)
      Monitoring::Retention.for(project, key: :errors, global_days: global_days)
    end

    # Intero positivo o nil (un valore assente/zero/blank → eredita).
    def resolve(value) = Monitoring::Retention.resolve(value)
  end
end
