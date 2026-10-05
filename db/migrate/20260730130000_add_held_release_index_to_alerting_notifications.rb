# frozen_string_literal: true

# Indice parziale per il rilascio delle email trattenute dalle quiet hours (CYRA-208): il giro
# Notifications::ReleaseHeldJob parte ogni 15' e filtra WHERE status = :held (5) AND via = :email.
# Senza indice sarebbe un seq-scan sull'intero ledger alerting_notifications 96 volte al giorno.
# Gemello di idx_alerting_notifications_digest_queue (WHERE status = 4), che serve il job digest.
# L'indice è minuscolo: matcha solo le poche righe :held ancora non consegnate (una notte alla volta).
#
# CONCURRENTLY (+ disable_ddl_transaction!) per non bloccare le scritture di notifiche durante la
# creazione dell'indice sul ledger già popolato in produzione (stesso motivo di CYRA-59 sui log).
class AddHeldReleaseIndexToAlertingNotifications < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "idx_alerting_notifications_held_release"

  def up
    # Un CREATE INDEX CONCURRENTLY interrotto lascia un indice INVALID con questo nome: rimuovere un
    # eventuale residuo (concurrently, no-op se assente) rende la migration ri-eseguibile.
    remove_index :alerting_notifications, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
    add_index :alerting_notifications, :via, where: "status = 5", name: INDEX_NAME, algorithm: :concurrently
  end

  def down
    remove_index :alerting_notifications, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
  end
end
