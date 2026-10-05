# frozen_string_literal: true

module Servers
  # Giorni di conservazione dei raw sample di un'ORGANIZZAZIONE: i dati server sono org-scoped nel
  # data model (niente project_id — CYRA-159), quindi la catena parte dall'org. Governa solo i raw
  # sample; container (7g) e journal (48h) restano buffer diagnostici a costante fissa. La regola
  # (nearest-wins org → god globale → default di sistema) vive tutta in Monitoring::Retention.
  module Retention
    module_function

    def for(organization, global_days: :unset)
      Monitoring::Retention.for(organization, key: :servers, global_days: global_days)
    end

    # Intero positivo o nil (un valore assente/zero/blank → eredita).
    def resolve(value) = Monitoring::Retention.resolve(value)
  end
end
