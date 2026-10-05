# frozen_string_literal: true

module Realtime
  # Store di presenza per organizzazione: chi è "online ora". Backend = Rails.cache
  # (Solid Cache in produzione), nessuna tabella dedicata. Tenant-safe: ogni chiave è
  # prefissata con l'org id e `online` ri-filtra sugli account realmente membri dell'org.
  #
  # Modello di liveness (semplice ma corretto):
  #  - per ogni account si tiene un "roster entry" { tabs, expires_at } nella hash dell'org;
  #  - `tabs` = numero di tab/connessioni aperte dall'account (più tab → resta online finché ne
  #    resta almeno una): `add` su ogni subscribe, `remove` su ogni unsubscribe;
  #  - `expires_at` = scadenza TTL rinfrescata dall'heartbeat del client (`touch`). È il vero
  #    gate di liveness: una chiusura "sporca" (browser killato, niente unsubscribe) NON
  #    decrementa `tabs`, ma l'entry scade comunque dopo TTL → ghost rimosso da `online`.
  #  - `tabs` serve solo a togliere subito l'avatar quando l'ULTIMA tab si chiude in modo pulito
  #    (UX migliore dell'attesa del TTL). La precisione esatta del contatore non è critica:
  #    `expires_at` resta l'autorità, quindi le rare race read-modify-write si auto-sanano.
  #
  # `fingerprint` = firma dell'insieme di id online all'ultimo broadcast: permette a
  # Presence::Broadcast di ri-emettere SOLO quando l'insieme visibile cambia (incluso il caso
  # "un'entry è scaduta") evitando broadcast-storm sugli heartbeat.
  module Presence
    module_function

    # Finestra di vita di un'entry senza heartbeat. Il client batte ben dentro questa finestra
    # (vedi presence_controller.js, default 20s) → margine per ~2 battiti persi prima del drop.
    TTL = 45.seconds

    # Backstop sulla chiave di cache: un'org del tutto inattiva evapora da sola. Le mutazioni
    # riscrivono la chiave con TTL fresco, quindi le org attive non la perdono mai.
    ROSTER_CACHE_TTL = 1.hour

    # Registra l'apertura di una tab dell'account (subscribe). Idempotente per-tab via contatore.
    def add(organization, account)
      mutate(organization) do |roster|
        entry = (roster[account.id] ||= { "tabs" => 0 })
        entry["tabs"] = entry["tabs"].to_i + 1
        entry["expires_at"] = expiry
      end
    end

    # Registra la chiusura pulita di una tab (unsubscribe). L'account esce solo quando le tab → 0.
    def remove(organization, account)
      mutate(organization) do |roster|
        entry = roster[account.id]
        next unless entry

        entry["tabs"] = entry["tabs"].to_i - 1
        roster.delete(account.id) if entry["tabs"] <= 0
      end
    end

    # Heartbeat: rinfresca la scadenza. Fa anche da upsert (ri-aggancia l'account se una `add`
    # si fosse persa in una race), così un client vivo torna online entro un battito.
    def touch(organization, account)
      mutate(organization) do |roster|
        entry = (roster[account.id] ||= { "tabs" => 1 })
        entry["tabs"] = 1 if entry["tabs"].to_i < 1
        entry["expires_at"] = expiry
      end
    end

    # Account online ORA: id non scaduti, ri-scopati sui membri reali dell'org (doppia difesa
    # tenant) e ordinati per nome (output stabile). Relation AR (vuota → none).
    def online(organization)
      ids = live_ids(organization)
      return Accounts::Account.none if ids.empty?

      organization.accounts.where(id: ids).order(:name)
    end

    # Firma dell'insieme visibile a `viewer` all'ultimo broadcast (per il diffing PER-VIEWER in
    # Presence::Broadcast). La presenza è ora filtrata per destinatario → una firma per viewer,
    # non una sola per org: ognuno vede un sottoinsieme diverso, ognuno ha il suo fingerprint.
    def last_fingerprint(organization, viewer)
      Rails.cache.read(fingerprint_key(organization, viewer))
    end

    def store_fingerprint(organization, viewer, fingerprint)
      Rails.cache.write(fingerprint_key(organization, viewer), fingerprint, expires_in: ROSTER_CACHE_TTL)
    end

    # --- interni -----------------------------------------------------------------------------

    def live_ids(organization)
      now = Time.current.to_f
      read_roster(organization).filter_map { |id, entry| id if entry["expires_at"].to_f > now }
    end

    # Read-modify-write della hash roster. Il `prune!` post-yield rimuove le entry scadute ad
    # ogni scrittura → roster sempre limitato e auto-sanante. La cache resta l'unica fonte
    # condivisa fra i processi cable (eventuale-consistenza accettabile per la presenza).
    def mutate(organization)
      roster = read_roster(organization)
      yield roster
      prune!(roster)
      Rails.cache.write(roster_key(organization), roster, expires_in: ROSTER_CACHE_TTL)
    end

    def read_roster(organization)
      Rails.cache.read(roster_key(organization)) || {}
    end

    def prune!(roster)
      now = Time.current.to_f
      roster.delete_if { |_id, entry| entry["expires_at"].to_f <= now }
    end

    def expiry
      (Time.current + TTL).to_f
    end

    def roster_key(organization)
      "realtime:presence:roster:#{org_id(organization)}"
    end

    def fingerprint_key(organization, viewer)
      "realtime:presence:fingerprint:#{org_id(organization)}:#{viewer.id}"
    end

    def org_id(organization)
      organization.respond_to?(:id) ? organization.id : organization
    end

    private_class_method :live_ids, :mutate, :read_roster, :prune!, :expiry,
                         :roster_key, :fingerprint_key, :org_id
  end
end
