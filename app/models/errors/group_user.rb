# frozen_string_literal: true

module Errors
  # CYRA-1241 — una persona (user_hash) già vista da un gruppo d'errore. È ciò su cui si decide se
  # `users_count` sale: l'indice unico (group_id, user_hash) lascia entrare la stessa persona una
  # volta sola, anche con due eventi simultanei. Non dipende dalle occorrenze: la potatura degli
  # eventi non la tocca e chi torna dopo resta riconosciuto. Sparisce solo con il gruppo.
  class GroupUser < ApplicationRecord
    self.table_name = "errors_group_users"

    belongs_to :group, class_name: "Errors::Group", inverse_of: :group_users

    validates :user_hash, presence: true

    # Prova a mettere la persona nell'elenco del gruppo. true SOLO a chi l'ha davvero aggiunta: in
    # concorrenza il secondo INSERT aspetta il commit del primo e poi non scrive niente.
    def self.claim(group_id:, user_hash:)
      insert_all([ { group_id: group_id, user_hash: user_hash, created_at: Time.current } ],
                 unique_by: %i[group_id user_hash], returning: %i[user_hash]).rows.any?
    end

    # Le persone delle occorrenze CONSERVATE di `events` entrano nell'elenco di `group_id`. Chi
    # c'è già resta com'è. Ritorna quante righe sono state aggiunte.
    def self.collect_from_events(group_id:, events:)
      hashes = events.where.not(user_hash: nil).reorder(nil).distinct.pluck(:user_hash)
      return 0 if hashes.empty?

      now = Time.current
      rows = hashes.map { |user_hash| { group_id: group_id, user_hash: user_hash, created_at: now } }
      insert_all(rows, unique_by: %i[group_id user_hash]).length
    end

    # Le persone già note ai gruppi `from_ids` entrano nell'elenco di `to_id` (fusione).
    def self.absorb(to_id:, from_ids:)
      connection.exec_update(sanitize_sql_array([ <<~SQL.squish, to_id, Array(from_ids) ]))
        INSERT INTO errors_group_users (id, group_id, user_hash, created_at)
        SELECT gen_random_uuid(), ?, user_hash, MIN(created_at)
        FROM errors_group_users
        WHERE group_id IN (?)
        GROUP BY user_hash
        ON CONFLICT (group_id, user_hash) DO NOTHING
      SQL
    end
  end
end
