class CreateActivityEvents < ActiveRecord::Migration[8.1]
  def change
    # Activity-log GENERALIZZATO (polimorfico): cronologia per qualsiasi entità non-ticket
    # (project/group/… via `subject`). I ticket restano sul loro Ticketing::Event (più ricco).
    create_table :activity_events, id: :uuid do |t|
      t.timestamps

      # Scoping diretto denormalizzato: l'org del subject è immutabile → audit scoped per tenant.
      t.references :organization, type: :uuid, null: false,
                   foreign_key: { to_table: :organizations }

      # Soggetto dell'evento (Projects::Project, Projects::Group, …).
      t.references :subject, type: :uuid, null: false, polymorphic: true

      # Attore percepito (impersonato se attivo) e attore reale (il god dietro). Nullable:
      # eventi senza attore o con account poi cancellato non rompono il log → nullify.
      t.references :actor, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts }
      t.references :true_actor, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts }

      # Snapshot del nome attore al momento del fatto (resiste a cancellazione account).
      t.string :actor_name, null: true

      t.string :action, null: false           # allow-list nel model (Activity::Event::ACTIONS)
      t.jsonb  :data, null: false, default: {} # contesto evento, con label UMANE snapshottate
    end

    add_index :activity_events, [ :subject_type, :subject_id, :created_at ]
    add_index :activity_events, [ :organization_id, :created_at ]
  end
end
