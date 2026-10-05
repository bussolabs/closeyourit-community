# Una sessione di session replay: aggrega i chunk rrweb di una sessione-browser.
# I byte del replay vivono su ActiveStorage (has_many_attached :chunks, gzip); qui
# stanno solo i metadati per lista/scoping/retention. project_id denormalizzato
# (come errors_events) per query e prune scoped al progetto. Join agli errori via
# [project_id, replay_session_id], senza FK: chunk ed errori arrivano indipendenti.
class CreateReplaysSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :replays_sessions, id: :uuid do |t|
      t.timestamps

      t.references :project, type: :uuid, null: false, foreign_key: { to_table: :projects }

      t.string   :replay_session_id, null: false
      t.string   :environment
      t.datetime :started_at, null: false
      t.datetime :ended_at
      t.integer  :duration_ms
      t.integer  :events_count, null: false, default: 0

      t.index %i[project_id replay_session_id], unique: true
      t.index %i[project_id created_at]
    end
  end
end
