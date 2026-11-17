class CreateTicketingAcceptanceItems < ActiveRecord::Migration[8.1]
  # CYRA-1317 — one list of acceptance items per ticket, replacing scenarios and conditions. An item is
  # plain text or a Given/When/Then/Expected case, with a code (AC-N) never reused on its ticket and a
  # revision bumped on every content change. Rows copied from the old tables keep their id in legacy_id,
  # so the cleanup release can import what an old container wrote while this one was rolling out.
  def up
    create_table :ticketing_acceptance_items, id: :uuid do |t|
      t.timestamps

      t.references :ticket, type: :uuid, null: false,
                            foreign_key: { to_table: :ticketing_tickets, on_delete: :cascade }
      t.integer :position, null: false, default: 0
      t.string  :code, null: false
      t.integer :revision, null: false, default: 1
      t.string  :format, null: false
      t.string  :title
      t.text    :text
      t.text    :step_given
      t.text    :step_when
      t.text    :step_then
      t.text    :step_expected
      t.uuid    :legacy_id

      t.index %i[ticket_id position]
      t.index %i[ticket_id code], unique: true
      t.index :legacy_id, unique: true
    end

    add_column :ticketing_tickets, :last_acceptance_item_number, :integer, null: false, default: 0
    backfill
  end

  def down
    remove_column :ticketing_tickets, :last_acceptance_item_number
    drop_table :ticketing_acceptance_items
  end

  # Copies the rows of the old tables not copied yet; the cleanup release calls it again.
  def backfill
    # Plain SQL, no models: scenarios first, then conditions, each in its own order.
    execute(<<~SQL.squish)
      WITH rows AS (
        SELECT ticket_id, id AS legacy_id, 'scenario' AS format, title, NULL::text AS text,
               step_given, step_when, step_then, step_expected, created_at, updated_at,
               0 AS kind_order, position, created_at AS sort_at
        FROM ticketing_scenarios
        WHERE NOT EXISTS (SELECT 1 FROM ticketing_acceptance_items done WHERE done.legacy_id = ticketing_scenarios.id)
        UNION ALL
        SELECT ticket_id, id, 'text', NULL, text, NULL, NULL, NULL, NULL, created_at, updated_at,
               1, position, created_at
        FROM ticketing_conditions
        WHERE NOT EXISTS (SELECT 1 FROM ticketing_acceptance_items done WHERE done.legacy_id = ticketing_conditions.id)
      ), numbered AS (
        SELECT rows.*, ticketing_tickets.last_acceptance_item_number +
               ROW_NUMBER() OVER (PARTITION BY ticket_id ORDER BY kind_order, position, sort_at, legacy_id) AS n
        FROM rows JOIN ticketing_tickets ON ticketing_tickets.id = rows.ticket_id
      )
      INSERT INTO ticketing_acceptance_items
        (id, ticket_id, position, code, revision, format, title, text, step_given, step_when, step_then,
         step_expected, legacy_id, created_at, updated_at)
      SELECT gen_random_uuid(), ticket_id, n - 1, 'AC-' || n, 1, format, title, text, step_given, step_when,
             step_then, step_expected, legacy_id, created_at, updated_at
      FROM numbered
    SQL

    execute(<<~SQL.squish)
      UPDATE ticketing_tickets SET last_acceptance_item_number = numbers.highest
      FROM (
        SELECT ticket_id, MAX(SUBSTRING(code FROM 4)::integer) AS highest
        FROM ticketing_acceptance_items GROUP BY ticket_id
      ) numbers
      WHERE numbers.ticket_id = ticketing_tickets.id AND numbers.highest > ticketing_tickets.last_acceptance_item_number
    SQL
  end
end
