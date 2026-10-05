class CreateTicketingEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_events, id: :uuid do |t|
      t.timestamps

      # Scoping diretto (denormalizzato): l'org del ticket è immutabile (project_id non cambia).
      t.references :organization, type: :uuid, null: false,
                   foreign_key: { to_table: :organizations }
      t.references :ticket, type: :uuid, null: false,
                   foreign_key: { to_table: :ticketing_tickets }

      # Attore percepito (impersonato se attivo) e attore reale (il god dietro). Nullable:
      # eventi senza attore o con account poi cancellato non devono rompere il log.
      t.references :actor, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts }
      t.references :true_actor, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts }

      # Snapshot del nome attore al momento del fatto (resiste a cancellazione account).
      t.string :actor_name, null: true

      t.string :action, null: false           # allow-list nel model (Ticketing::Event::ACTIONS)
      t.jsonb  :data, null: false, default: {} # diff prima→dopo, con label UMANE snapshottate
    end

    add_index :ticketing_events, [ :ticket_id, :created_at ]
    add_index :ticketing_events, [ :organization_id, :created_at ]
  end
end
