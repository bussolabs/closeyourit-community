# frozen_string_literal: true

# Matrice funzionalità × piattaforme (CYRA-256): per ogni macro-progetto una tabella che incrocia le
# funzionalità del prodotto (righe, raggruppate per categoria) con le piattaforme su cui gira
# (colonne), dicendo per ogni incrocio a che punto è la funzionalità e da quale versione è arrivata
# agli utenti. Finora l'informazione non esisteva da nessuna parte: un prodotto fatto di più repo
# (web + mobile) non aveva un posto dove dire "il 2FA c'è sul web ma non ancora su iOS".
#
# Quattro tabelle: lo STATO della cella è un lookup org-scoped (types_), la struttura della matrice
# (categoria → funzionalità) sta nel namespace product_, la CELLA è una join con payload e sta in
# connections_ come tutte le altre join del progetto.
class CreateProductFeatureMatrix < ActiveRecord::Migration[8.1]
  def change
    # Ciclo di vita di una funzionalità su una piattaforma. Lookup CRUD org-scoped, gemella di
    # types_ticket_statuses: `category` (enum integer) è il discriminatore che guida icona,
    # semantica ("rilasciato" = available/deprecated) e validazioni; label/color restano editabili.
    # created_by_id: la regola migrations.md lo vieta sulle Types::, ma tutte le types_* già in
    # essere (platforms, ticket_statuses, ticket_priorities, environments) ce l'hanno nullable —
    # qui vince la coerenza coi fratelli, il modello è un clone di Types::TicketStatus.
    create_table :types_feature_statuses, id: :uuid do |t|
      t.timestamps

      t.references :created_by, type: :uuid, null: true,
                                foreign_key: { to_table: :accounts, on_delete: :nullify }

      t.references :organization, type: :uuid, null: false,
                                  foreign_key: { to_table: :organizations, on_delete: :cascade }

      t.string :code, null: false
      t.string :label, null: false
      t.string :color, null: false
      # 0 unplanned · 1 planned · 2 in_development · 3 available · 4 deprecated · 5 not_applicable
      t.integer :category, null: false, default: 0
      t.integer :position, null: false, default: 0
      t.boolean :active, null: false, default: true

      t.index %i[organization_id code], unique: true
      t.index %i[organization_id active position]
    end

    # Riga-gruppo della matrice ("Auth"). Scoped al macro-progetto e non all'org: due prodotti
    # diversi hanno la loro "Auth" indipendente, con il proprio ordinamento. Cascade sul gruppo: la
    # matrice è del gruppo e non è riassegnabile altrove (i progetti invece sopravvivono, nullify).
    # organization_id denormalizzato come su knowledge_versions: serve alla validazione di coerenza
    # tenant, non alla query (che parte sempre dal gruppo).
    create_table :product_categories, id: :uuid do |t|
      t.timestamps

      t.references :created_by, type: :uuid, null: true,
                                foreign_key: { to_table: :accounts, on_delete: :nullify }

      t.references :organization, type: :uuid, null: false,
                                  foreign_key: { to_table: :organizations, on_delete: :cascade }
      t.references :group, type: :uuid, null: false,
                           foreign_key: { to_table: :projects_groups, on_delete: :cascade }

      t.string :name, null: false
      t.integer :position, null: false, default: 0

      t.index %i[group_id position]
      # Unicità su lower(name): il modello valida case_sensitive: false, e un indice sul nome
      # grezzo lascerebbe passare "Auth" e "auth" a due richieste concorrenti — l'indice è
      # l'ultima difesa, deve dire la stessa cosa della validazione.
      t.index "group_id, lower(name)", unique: true, name: "index_product_categories_on_group_and_lower_name"
    end

    # Riga della matrice ("2FA"). knowledge_page_id = link opzionale alla base di conoscenza a
    # livello di FUNZIONALITÀ, non di cella: la pagina spiega cosa fa la funzionalità, non la sua
    # disponibilità su una singola piattaforma. Nullify: cancellare la pagina non cancella la riga.
    create_table :product_features, id: :uuid do |t|
      t.timestamps

      t.references :created_by, type: :uuid, null: true,
                                foreign_key: { to_table: :accounts, on_delete: :nullify }

      t.references :organization, type: :uuid, null: false,
                                  foreign_key: { to_table: :organizations, on_delete: :cascade }
      t.references :category, type: :uuid, null: false,
                              foreign_key: { to_table: :product_categories, on_delete: :cascade }
      t.references :knowledge_page, type: :uuid, null: true,
                                    foreign_key: { to_table: :knowledge_pages, on_delete: :nullify }

      t.string :name, null: false
      t.text :description
      t.integer :position, null: false, default: 0

      t.index %i[category_id position]
      # Stesso motivo della categoria: unicità su lower(name), allineata alla validazione.
      t.index "category_id, lower(name)", unique: true, name: "index_product_features_on_category_and_lower_name"
    end

    # CELLA della matrice: una funzionalità su una piattaforma. Join con payload → connections_,
    # come Connections::ProjectEnvironment (che porta 4 colonne di override).
    #
    # created_by: deroga consapevole al "no created_by sulle join". La cella è un giudizio
    # redazionale ("il 2FA su iOS c'è dalla 3.2"), non un collegamento strutturale: sapere chi
    # l'ha scritto è parte del valore. Stesso precedente di connections_ticket_links.
    #
    # organization_id NON è denormalizzato qui: si legge feature.organization_id a un hop, come fa
    # Connections::PageProject con page.organization_id.
    create_table :connections_feature_platforms, id: :uuid do |t|
      t.timestamps

      t.references :created_by, type: :uuid, null: true,
                                foreign_key: { to_table: :accounts, on_delete: :nullify }

      t.references :feature, type: :uuid, null: false,
                             foreign_key: { to_table: :product_features, on_delete: :cascade }
      # Restrict su piattaforma e stato: sono lookup: in uso non si cancellano, si disattivano
      # (active: false). Coerente con Types::Platform, che usa già restrict_with_error sulle sue join.
      t.references :platform, type: :uuid, null: false,
                              foreign_key: { to_table: :types_platforms, on_delete: :restrict }
      t.references :status, type: :uuid, null: false,
                            foreign_key: { to_table: :types_feature_statuses, on_delete: :restrict }
      # Nullify, mai restrict: le release nascono dall'ingest e dalla CI e possono essere potate.
      # La cella deve sopravvivere con lo stato intatto, perdendo solo l'indicazione della versione.
      t.references :release, type: :uuid, null: true,
                             foreign_key: { to_table: :projects_releases, on_delete: :nullify }

      t.index %i[feature_id platform_id], unique: true
    end
  end
end
