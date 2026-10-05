class RestructureTicketBodyIntoScenariosAndConditions < ActiveRecord::Migration[8.1]
  # Corpo del ticket da 4 colonne BDD piatte (un solo Given/When/Then/Expected, solo bug) a:
  #  - ticketing_scenarios: N scenari ordinati per ticket (Given/When/Then/Expected + titolo), tutti i kind
  #  - ticketing_conditions: N righe DoD (Definition of Done) opzionali per ticket
  #  - ticketing_tickets.technical_analysis: registro tecnico separato dal corpo human-simple
  # Backfill: ogni ticket con almeno una step_* valorizzata → 1 scenario (position 0) coi 4 valori.
  def up
    create_table :ticketing_scenarios, id: :uuid do |t|
      t.timestamps

      t.references :ticket, type: :uuid, null: false,
                            foreign_key: { to_table: :ticketing_tickets, on_delete: :cascade }
      t.integer :position, null: false, default: 0
      t.string  :title
      t.text    :step_given
      t.text    :step_when
      t.text    :step_then
      t.text    :step_expected

      t.index %i[ticket_id position]
    end

    create_table :ticketing_conditions, id: :uuid do |t|
      t.timestamps

      t.references :ticket, type: :uuid, null: false,
                            foreign_key: { to_table: :ticketing_tickets, on_delete: :cascade }
      t.integer :position, null: false, default: 0
      t.text    :text, null: false

      t.index %i[ticket_id position]
    end

    add_column :ticketing_tickets, :technical_analysis, :text

    # Backfill in SQL (niente model: la logica del model può cambiare). Un solo scenario per ticket
    # che aveva un corpo BDD, position 0, titolo lasciato nullo.
    execute(<<~SQL.squish)
      INSERT INTO ticketing_scenarios
        (id, ticket_id, position, step_given, step_when, step_then, step_expected, created_at, updated_at)
      SELECT gen_random_uuid(), id, 0, step_given, step_when, step_then, step_expected, now(), now()
      FROM ticketing_tickets
      WHERE COALESCE(step_given, '')    <> ''
         OR COALESCE(step_when, '')     <> ''
         OR COALESCE(step_then, '')     <> ''
         OR COALESCE(step_expected, '') <> ''
    SQL

    remove_column :ticketing_tickets, :step_given, :text
    remove_column :ticketing_tickets, :step_when, :text
    remove_column :ticketing_tickets, :step_then, :text
    remove_column :ticketing_tickets, :step_expected, :text
  end

  def down
    add_column :ticketing_tickets, :step_given, :text
    add_column :ticketing_tickets, :step_when, :text
    add_column :ticketing_tickets, :step_then, :text
    add_column :ticketing_tickets, :step_expected, :text

    # Ripristina il corpo piatto dallo scenario a position 0 (il primo), best-effort.
    execute(<<~SQL.squish)
      UPDATE ticketing_tickets t SET
        step_given    = s.step_given,
        step_when     = s.step_when,
        step_then     = s.step_then,
        step_expected = s.step_expected
      FROM ticketing_scenarios s
      WHERE s.ticket_id = t.id AND s.position = 0
    SQL

    remove_column :ticketing_tickets, :technical_analysis, :text
    drop_table :ticketing_conditions
    drop_table :ticketing_scenarios
  end
end
