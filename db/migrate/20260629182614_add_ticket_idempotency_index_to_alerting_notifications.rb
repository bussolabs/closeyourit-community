# frozen_string_literal: true

# Idempotenza delle notifiche ticket (rule_id IS NULL): l'unique [rule_id, dedup_key] esistente NON
# deduplica le righe ticket perché in Postgres i NULL sono distinti. La validation AR a livello app
# già blocca i duplicati, ma ApplicationJob ritenta 3× → indice parziale per la race a livello DB.
class AddTicketIdempotencyIndexToAlertingNotifications < ActiveRecord::Migration[8.1]
  def change
    add_index :alerting_notifications, %i[account_id dedup_key],
              unique: true, where: "rule_id IS NULL",
              name: "idx_alerting_notifications_ticket_idem"
  end
end
