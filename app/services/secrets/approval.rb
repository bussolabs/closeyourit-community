# frozen_string_literal: true

module Secrets
  # Guard di sola LETTURA (CYRA-138, Fase 4 pezzo C1a — FONDAMENTA): risponde a "questa modifica ai
  # secret di [progetto, ambiente] è protetta dall'approvazione a due?". Nessuna intercettazione reale
  # qui — quella (e l'applicazione/coda) arriva nei pezzi successivi (C1b/C2); questo PORO è solo la
  # domanda, non la risposta operativa.
  #
  # Protetto sse ENTRAMBI: (a) il progetto ha attivato il master opt-in (secret_approval_enabled) E
  # (b) la capability approval_required, RISOLTA per quell'ambiente su quel progetto (default
  # dell'ambiente oppure override tri-state sulla riga join), è true. Un ambiente non dichiarato dal
  # progetto (nessuna riga Connections::ProjectEnvironment) non ha una capability da risolvere: mai
  # protetto, coerente con le altre capability (servers/uptime/secrets) che si applicano solo agli
  # ambienti dichiarati.
  #
  # Zero query pesanti: al più UNA query (find_by su [project_id, environment_id], indicizzato); nessun
  # N+1, nessun join extra. project/environment sono presi così come passati dal chiamante (nessun
  # reload forzato).
  class Approval
    def self.required?(project:, environment:)
      return false unless project.secret_approval_enabled?

      project.project_environments.find_by(environment_id: environment.id)&.approval_required? || false
    end
  end
end
