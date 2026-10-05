# frozen_string_literal: true

# Dominio SEO (CYRA-528/529): i siti pubblici dei progetti, visitati a intervalli, con lo stato di
# ogni pagina e i rilievi che ne nascono.
#
# Quattro tabelle, tutte PER PROGETTO (nessun dato globale come gli advisory OSV delle vulnerabilità:
# qui non esiste niente di condivisibile fra organizzazioni — l'HTML di un sito appartiene al
# progetto che lo dichiara):
# - seo_sites      la configurazione: cosa visitare, quanto spesso, fin dove
# - seo_audits     lo storico dei giri: quanti rilievi erano aperti quel giorno
# - seo_pages      l'ULTIMO stato di ogni URL, non la sua storia (vedi commento sotto)
# - seo_issues     il rilievo con la sua prova, deduplicato e triagiabile
class CreateSeoTables < ActiveRecord::Migration[8.1]
  def change
    # Un sito da tenere d'occhio. Uno per [progetto, ambiente] come Uptime::Monitor: staging e
    # produzione dello stesso progetto sono due siti diversi e vanno guardati separatamente.
    create_table :seo_sites, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :project, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      # restrict come per i monitor uptime: non si cancella un ambiente che qualcuno sta osservando.
      t.references :environment, type: :uuid, null: false,
                                 foreign_key: { to_table: :types_environments, on_delete: :restrict }
      t.references :created_by, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.string :base_url, null: false
      t.boolean :enabled, default: true, null: false
      t.integer :frequency, default: 0, null: false, comment: "0 = ogni giorno, 1 = ogni settimana"
      t.integer :max_pages, default: 100, null: false,
                comment: "Tetto di pagine per giro: un crawler senza tetto è un attacco al sito di qualcun altro"
      t.boolean :follow_sitemap, default: true, null: false
      t.datetime :last_audited_at
      t.datetime :next_audit_at
      t.string :last_error,
               comment: "Motivo dell'ultimo giro fallito: il sito resta in elenco invece di tacere"
      t.timestamps

      t.index %i[project_id environment_id], unique: true
      # La domanda del dispatcher, una volta all'ora: chi è scaduto?
      t.index %i[enabled next_audit_at]
    end

    # Un giro di visita. Serve al trend ("i rilievi aperti stanno scendendo?") e a dire cosa è
    # successo l'ultima volta: senza questa tabella un giro fallito sarebbe indistinguibile da un
    # giro mai partito.
    create_table :seo_audits, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :site, type: :uuid, null: false,
                          foreign_key: { to_table: :seo_sites, on_delete: :cascade }
      t.integer :status, default: 0, null: false, comment: "0 running, 1 completed, 2 failed"
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.integer :pages_count, default: 0, null: false
      t.integer :issues_open_count, default: 0, null: false
      t.string :error
      t.timestamps

      t.index %i[site_id started_at]
    end

    # L'ultimo stato di ogni URL, aggiornato a ogni giro. NON storicizzato per pagina: cento pagine
    # per un giro al giorno fanno milioni di righe che nessuno guarderà mai. La storia che serve
    # davvero è quella dei rilievi (first_seen_at/last_seen_at) e quella dei giri (seo_audits).
    #
    # `url` è una stringa indicizzata: le URL oltre i 2000 caratteri le scarta il crawler, perché a
    # quel punto non sono pagine ma parametri impazziti, e sopra i ~2700 byte l'indice btree non le
    # reggerebbe comunque.
    create_table :seo_pages, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :site, type: :uuid, null: false,
                          foreign_key: { to_table: :seo_sites, on_delete: :cascade }
      t.string :url, null: false
      t.string :path
      t.integer :status_code
      t.jsonb :redirect_chain, default: [], null: false,
              comment: "Le tappe intermedie: una catena di due salti è un rilievo, non un dettaglio"
      t.string :title
      t.text :meta_description
      t.string :canonical_url
      t.string :robots_directives
      t.jsonb :hreflangs, default: {}, null: false, comment: "locale => url dichiarata"
      t.string :lang
      t.jsonb :h1s, default: [], null: false
      t.integer :h2_count, default: 0, null: false
      t.integer :word_count, default: 0, null: false
      t.jsonb :jsonld_types, default: [], null: false
      t.integer :images_total, default: 0, null: false
      t.integer :images_without_alt, default: 0, null: false
      t.integer :internal_links_count, default: 0, null: false
      t.integer :external_links_count, default: 0, null: false
      t.integer :html_bytes, default: 0, null: false
      t.integer :response_time_ms
      t.boolean :in_sitemap, default: false, null: false
      t.string :discovered_from,
               comment: "URL che l'ha linkata, oppure 'sitemap': è ciò che spiega una pagina orfana"
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.timestamps

      t.index %i[site_id url], unique: true
      t.index %i[site_id last_seen_at]
    end

    # Il rilievo: questo controllo, su questa pagina (o su questo sito), è fallito. Vocabolario di
    # stato identico a Vulnerabilities::Finding — `resolved` la mette la scansione quando il
    # problema sparisce, `ignored` la mette una persona che ha deciso di conviverci, e da lì non
    # torna aperto da solo.
    create_table :seo_issues, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :site, type: :uuid, null: false,
                          foreign_key: { to_table: :seo_sites, on_delete: :cascade }
      # I rilievi d'insieme (titoli duplicati, hreflang non reciproci, sitemap irraggiungibile) non
      # hanno una pagina sola. nullify e non cascade: se la pagina viene potata il rilievo resta,
      # con la sua prova dentro `evidence`.
      t.references :page, type: :uuid,
                          foreign_key: { to_table: :seo_pages, on_delete: :nullify }
      t.references :ticket, type: :uuid,
                            foreign_key: { to_table: :ticketing_tickets, on_delete: :nullify }
      t.string :check_key, null: false
      t.integer :severity, default: 0, null: false, comment: "0 low, 1 medium, 2 high, 3 critical"
      t.integer :status, default: 0, null: false, comment: "0 open, 1 resolved, 2 ignored"
      t.jsonb :evidence, default: {}, null: false,
              comment: "La prova: URL coinvolta, valore trovato, valore atteso. Senza, è un'opinione"
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.datetime :resolved_at
      t.text :triage_note
      t.timestamps

      # Il dedup. `nulls_not_distinct` perché in PostgreSQL due NULL non collidono di default: senza
      # di esso i rilievi d'insieme (page_id NULL) si duplicherebbero a ogni giro.
      t.index %i[site_id check_key page_id], unique: true, nulls_not_distinct: true
      t.index %i[site_id status severity]
    end
  end
end
