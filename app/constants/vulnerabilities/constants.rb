# frozen_string_literal: true

module Vulnerabilities
  # Costanti del dominio vulnerabilità delle dipendenze (rules/constants.md).
  module Constants
    # CYRA-506. Il confronto con OSV.dev gira una volta al giorno per progetto: un lockfile non cambia
    # più spesso, ma gli advisory NUOVI escono su versioni ferme da mesi, quindi la query si rifà
    # sempre — è il parse che si salta quando il digest è invariato.
    OSV_BATCH_SIZE = 500              # pacchetti per richiesta querybatch
    MAX_MANIFEST_BYTES = 8.megabytes  # oltre, il lockfile non si parsa (difesa memoria)
    MAX_MANIFESTS_PER_PROJECT = 50    # tetto ai lockfile per repo (monorepo patologici)
    # Un advisory viene rivisto dopo la pubblicazione (la severity può cambiare): oltre questa età lo
    # si rilegge invece di fidarsi della copia in cache.
    ADVISORY_REFRESH_AFTER = 7.days
    # Preavviso di fine supporto di un runtime: entro N giorni dalla data di EOL lo stato passa da
    # `supported` a `ending_soon`. Un trimestre è il minimo per pianificare un aggiornamento maggiore.
    RUNTIME_EOL_WARNING_DAYS = 90
  end
end
