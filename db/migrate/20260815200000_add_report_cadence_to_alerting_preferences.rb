# frozen_string_literal: true

# Il riepilogo periodico dei DATI via email (CYRA-160): traffico, errori e disponibilità dei siti.
# Il digest che esisteva riassumeva le NOTIFICHE trattenute — cose già accadute e già annunciate —
# mentre nessuna email portava i numeri.
#
# La scelta vive qui e non in una tabella nuova perché la coppia (account, organizzazione) di cui
# ha bisogno è esattamente quella già unica su questa tabella, insieme all'interruttore email che
# la governa: una tabella gemella avrebbe duplicato chiave, unicità e pagina di configurazione.
#
# `report_cadence` parte da OFF: è un'email in più: la si riceve perché la si è chiesta, mai perché
# è stato aggiunto un campo. `report_last_sent_at` è l'unica difesa contro il doppio invio — il giro
# ricorrente gira ogni giorno e senza questa data non saprebbe di aver già scritto.
class AddReportCadenceToAlertingPreferences < ActiveRecord::Migration[8.1]
  def change
    add_column :alerting_preferences, :report_cadence, :integer, null: false, default: 0,
               comment: "Riepilogo periodico dei dati: 0 off · 1 giornaliero · 2 settimanale · 3 mensile"
    add_column :alerting_preferences, :report_last_sent_at, :datetime,
               comment: "Ultimo riepilogo dati spedito: guardia anti-doppione del giro ricorrente"
  end
end
