class CreateSecretsHealthAnomalies < ActiveRecord::Migration[8.1]
  def change
    # Memoria persistita delle anomalie del Vault trovate da Secrets::HealthCheck (CYRA-409): serve a
    # due cose che il calcolo al volo non può dare — da QUANDO un'anomalia esiste (first_seen_at) e la
    # decisione umana «questa assenza è voluta» (acknowledged). La verità di "cosa è anomalo ADESSO"
    # resta il calcolo di HealthCheck; questa tabella è solo la sua memoria. Stesso pattern di
    # vulnerabilities_findings (open/resolved + first/last_seen). MAI il valore di un secret qui dentro.
    create_table :secrets_health_anomalies, id: :uuid do |t|
      t.timestamps

      # Tenancy denormalizzata (scoping/query per org, come secrets_variables). Cascade: l'anomalia è
      # ricostruibile, non deve mai impedire la cancellazione di org/progetto/ambiente.
      t.references :organization, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :project, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :environment, type: :uuid, null: false,
                   foreign_key: { to_table: :types_environments, on_delete: :cascade }

      # Categoria: 0 drift_hole (variabile presente altrove e assente qui), 1 empty_environment
      # (ambiente dichiarato+attivo senza alcun secret), 2 broken_delegation (delega shared orfana).
      t.integer :kind, null: false
      # Nome della variabile/delega coinvolta. "" per empty_environment (manca TUTTO l'ambiente, non un
      # nome specifico): stringa vuota — non NULL — così l'unique index resta deterministico.
      t.string :secret_name, null: false, default: ""

      # 0 open, 1 resolved (l'anomalia è sparita), 2 acknowledged (una persona l'ha marcata voluta).
      t.integer :status, null: false, default: 0

      # Da quando l'anomalia è osservata / a quando risale l'ultima osservazione (pattern first-seen).
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.datetime :resolved_at

      # Decisione «assenza voluta»: vale per il progetto (l'org), non per la persona. Resta scritto CHI
      # l'ha presa (nullify: sopravvive alla cancellazione dell'account) e QUANDO, con la motivazione.
      t.datetime :acknowledged_at
      t.references :acknowledged_by, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.text :acknowledgement_reason

      # Un'anomalia per [progetto, ambiente, categoria, nome]: l'identità stabile su cui si ritrova il
      # record fra una scansione e l'altra (mantiene first_seen_at e l'acknowledge).
      t.index %i[project_id environment_id kind secret_name], unique: true,
              name: "index_secrets_health_anomalies_on_identity"
      t.index %i[organization_id status]
    end
  end
end
