# frozen_string_literal: true

# Dominio Vulnerabilità (CYRA-506): le dipendenze dichiarate dai repository dei progetti, confrontate
# con il database pubblico OSV.dev, più lo stato di supporto dei runtime (endoflife.date).
#
# Cinque tabelle, due nature diverse:
# - manifests/packages/findings/runtime_statuses sono PER PROGETTO (tenant),
# - advisories è GLOBALE: un advisory OSV è dato pubblico identico per tutte le organizzazioni.
#   Tenerlo per-org significherebbe rifare la stessa GET per ogni tenant e moltiplicare le righe.
#   L'isolamento resta comunque garantito: si arriva a un advisory solo passando da un finding, che
#   è scoped al progetto.
class CreateVulnerabilitiesTables < ActiveRecord::Migration[8.1]
  def change
    # Un lockfile trovato nel repository del progetto. `content_digest` evita di riparsare un file
    # immutato; `blob_sha` è lo sha git del file (serve per scaricarlo via Git Blobs API quando
    # supera il tetto di 1 MB dell'API contents).
    create_table :vulnerabilities_manifests, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :project, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :path, null: false
      t.string :ecosystem, null: false
      t.string :blob_sha
      t.string :content_digest
      t.datetime :scanned_at
      t.string :parse_error,
               comment: "Ultimo motivo di parse fallito: il manifest resta visibile invece di sparire in silenzio"
      t.integer :packages_count, default: 0, null: false
      t.timestamps

      t.index %i[project_id path], unique: true
    end

    # Una dipendenza risolta dentro un manifest. `direct` distingue ciò che il progetto dichiara da
    # ciò che si porta dietro: la stessa CVE pesa diversamente se la dipendenza è transitiva.
    create_table :vulnerabilities_packages, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :manifest, type: :uuid, null: false,
                              foreign_key: { to_table: :vulnerabilities_manifests, on_delete: :cascade }
      t.string :name, null: false
      t.string :version, null: false
      t.string :ecosystem, null: false
      t.boolean :direct, default: false, null: false
      t.timestamps

      t.index %i[manifest_id name version], unique: true
      t.index %i[ecosystem name version]
    end

    # Cache locale di un record OSV. `severity` è la scala GHSA (database_specific.severity), `cvss`
    # il vettore grezzo quando c'è. Nessun riferimento a organizzazione o progetto: è dato pubblico.
    create_table :vulnerabilities_advisories, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :osv_id, null: false
      t.text :aliases, array: true, default: [], null: false,
                       comment: "Identificatori equivalenti (CVE-…, GHSA-…): è il campo con cui un umano cerca"
      t.string :summary
      t.text :details
      t.integer :severity, default: 0, null: false
      t.string :cvss
      t.text :cwe_ids, array: true, default: [], null: false
      t.string :url
      # Le voci `affected` del record OSV, ridotte a ciò che serve: quale pacchetto e in quali
      # intervalli di versione. Da qui si ricava la prima versione che risolve, SENZA richiamare OSV
      # per un advisory già in cache — che è il caso normale quando la stessa CVE tocca più progetti.
      t.jsonb :affected, default: [], null: false
      t.datetime :published_at
      t.datetime :modified_at
      t.datetime :refreshed_at,
                 comment: "Ultima rilettura da OSV: un advisory viene rivisto, la severity può cambiare"
      t.timestamps

      t.index :osv_id, unique: true
      t.index :aliases, using: :gin
      t.index :severity
    end

    # L'occorrenza: questo pacchetto, in questo progetto, è colpito da questo advisory.
    # `project_id` è denormalizzato (si ricaverebbe da package→manifest) perché ogni lettura della
    # sezione filtra per progetto e la catena di join costerebbe su tutte le index.
    create_table :vulnerabilities_findings, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :project, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :package, type: :uuid, null: false,
                             foreign_key: { to_table: :vulnerabilities_packages, on_delete: :cascade }
      t.references :advisory, type: :uuid, null: false,
                              foreign_key: { to_table: :vulnerabilities_advisories, on_delete: :cascade }
      t.string :fixed_version,
               comment: "Prima versione che risolve, se OSV la dichiara: senza, non c'è un aggiornamento da suggerire"
      t.integer :status, default: 0, null: false
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.datetime :resolved_at
      t.text :triage_note
      t.uuid :ticket_id
      t.timestamps

      t.index %i[package_id advisory_id], unique: true
      t.index %i[project_id status]
      t.index :ticket_id, unique: true, where: "ticket_id IS NOT NULL"
    end

    # Un ticket cancellato non deve portarsi via il finding: la vulnerabilità resta, semplicemente
    # torna non promossa (nullify, come fanno gli altri riferimenti opzionali a un ticket).
    add_foreign_key :vulnerabilities_findings, :ticketing_tickets, column: :ticket_id,
                                                                   on_delete: :nullify

    # Stato di supporto di un runtime dichiarato dal progetto (mise.toml, .tool-versions,
    # .ruby-version). Una riga per prodotto per progetto: la versione corrente sostituisce la
    # precedente, non c'è storico da tenere.
    create_table :vulnerabilities_runtime_statuses, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :project, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :version, null: false
      t.string :cycle
      t.date :eol_on
      t.string :latest
      t.integer :state, default: 0, null: false
      t.string :source_path
      t.datetime :checked_at
      t.timestamps

      t.index %i[project_id name], unique: true
      t.index %i[project_id state]
    end
  end
end
