# frozen_string_literal: true

module Servers
  # CYRA-775 — memoria dei rifiuti che il backend ha opposto agli agent (429 del freno di velocità).
  # Serve a una cosa sola: dire a Servers::CheckStaleJob che il silenzio di una macchina può essere
  # NOSTRO. Senza questo canale un push rifiutato è indistinguibile da un push mai partito, e ogni
  # momento di carico del backend si traveste da guasto — il 3 settembre la stessa macchina è
  # risultata caduta e ripristinata sette volte in venticinque minuti, al passo esatto della finestra
  # di staleness, e ventidue host hanno mandato insieme quarantanove avvisi «Dati fermi».
  #
  # Si registra la CREDENZIALE rifiutata (il digest troncato con cui il freno conta, mai il segreto),
  # non un semplice «è successo»: un interruttore globale sarebbe stato armabile da chiunque, perché
  # il freno scatta anche su un Bearer inventato — bastava saturarlo da fuori per spegnere la
  # rilevazione dei guasti di TUTTE le organizzazioni. Le credenziali si risolvono qui, nel giro che
  # gira ogni minuto e non nel middleware: una chiave che non appartiene a nessuna macchina non
  # sospende niente, e quelle vere sospendono solo la propria organizzazione.
  #
  # Vive nella cache e non su una riga di database di proposito: lo scrive il processo web da dentro
  # il middleware, su una richiesta già rifiutata, e un INSERT per ogni rifiuto trasformerebbe un
  # burst in un secondo carico sul database che sta già soffrendo. Negli ambienti deployati la cache
  # è PostgreSQL condiviso (CYRA-289), quindi il worker che valuta la staleness legge quel che il web
  # ha scritto; in sviluppo è per processo e il canale resta muto — accettabile, lì nessuno avvisa.
  module IngestRejections
    module_function

    CACHE_KEY = "servers:ingest:rejections"
    # Tetto delle credenziali ricordate insieme. Una flotta ne ha una per macchina; il tetto esiste
    # perché una raffica di Bearer inventati non faccia crescere la mappa (e la query che la risolve)
    # senza limite. Riempiendola si torna al comportamento di prima — il silenzio ridiventa un guasto
    # — non a una sospensione perpetua: fail-open verso il rumore, mai verso il silenzio.
    MAX_TRACKED_KEYS = 200

    # Registra che ADESSO abbiamo detto no a questa credenziale. Senza chiave non c'è niente da
    # attribuire (nessun Bearer presentato): la richiesta non era di una macchina che conosciamo.
    def record!(token_key, at: Time.current)
      key = token_key.to_s
      return nil if key.empty?

      fresh = tracked(now: at).merge(key => at.to_f)
      # I più recenti vincono: se la mappa è piena, a cadere è il rifiuto più vecchio.
      fresh = fresh.sort_by { |_, epoch| -epoch }.first(MAX_TRACKED_KEYS).to_h
      Rails.cache.write(CACHE_KEY, fresh,
                        expires_in: Servers::Constants::INGEST_REJECTION_WINDOW_SECONDS.seconds)
      at
    end

    # Le credenziali rifiutate dentro la finestra. Il confronto lo fa Ruby e non la scadenza della
    # cache: uno store che tiene la riga più del dovuto non deve poter sospendere il giudizio in
    # eterno.
    def recent_keys(now: Time.current)
      tracked(now:).keys
    end

    # Le organizzazioni a cui appartengono le credenziali rifiutate. Vuoto se non c'è nessun rifiuto
    # o se nessuna chiave corrisponde a una credenziale viva: chi ha bussato con un Bearer inventato
    # non compra il silenzio di nessuno.
    def organization_ids(now: Time.current)
      keys = recent_keys(now:)
      return [] if keys.empty?

      (host_token_organization_ids(keys) + enrollment_token_organization_ids(keys)).uniq
    end

    # --- interni ---

    def tracked(now: Time.current)
      stored = Rails.cache.read(CACHE_KEY)
      return {} unless stored.is_a?(Hash)

      floor = (now - Servers::Constants::INGEST_REJECTION_WINDOW_SECONDS.seconds).to_f
      stored.select { |key, epoch| key.is_a?(String) && epoch.to_f > floor }
    end

    def host_token_organization_ids(keys)
      Servers::HostToken.active.joins(:host)
                        .where(digest_prefix_condition(keys, table: "servers_host_tokens"))
                        .distinct.pluck("servers_hosts.organization_id")
    end

    def enrollment_token_organization_ids(keys)
      Servers::EnrollmentToken.active
                              .where(digest_prefix_condition(keys, table: "servers_enrollment_tokens"))
                              .distinct.pluck(:organization_id)
    end

    # Il freno conta su un PREFISSO del digest (non sul digest intero: quella è la chiave con cui il
    # database riconosce il token, e finirebbe nei log del throttle scattato). Qui si torna indietro
    # confrontando lo stesso prefisso. Le chiavi si raggruppano per lunghezza — in pratica un gruppo
    # solo — perché la lunghezza entra nell'SQL e non può arrivare da fuori: è un intero, castato.
    def digest_prefix_condition(keys, table:)
      conditions = keys.group_by(&:length).map do |length, group|
        Servers::HostToken.sanitize_sql_array(
          [ "LEFT(#{table}.token_digest, #{Integer(length)}) IN (?)", group ]
        )
      end
      conditions.join(" OR ")
    end
  end
end
