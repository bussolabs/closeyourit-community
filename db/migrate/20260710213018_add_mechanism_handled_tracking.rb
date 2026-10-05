# frozen_string_literal: true

# CYRA-49: mechanism.handled (exception.values[].mechanism.handled) è emesso dai 3 SDK ma perso alla
# normalizzazione — crash veri (handled:false) e catture volontarie (handled:true) risultano
# indistinguibili. Persistiamo:
# - errors_events.handled: booleano NULLABILE (3 stati: true gestito / false crash / nil sconosciuto —
#   un capture_message senza exception, o un SDK che non emette mechanism → nil). Niente default: nil è
#   informazione onesta, non "gestito per default".
# - errors_groups.has_unhandled: flag monotòno "il gruppo ha visto almeno un crash non gestito", aggiornato
#   in OR dai contatori atomici di Errors::Ingest::Record. Abilita il filtro/badge della lista.
# - alerting_rules.unhandled_only: la regola scatta SOLO sugli errori non-gestiti (alert sui crash veri).
#
# Backfill dello storico: i gruppi/eventi pre-esistenti restano a NULL/false qui. Il dato è recuperabile
# dal payload conservato (mechanism non è PII) → dopo il deploy lanciare una volta:
#   bin/rails runner 'Errors::BackfillHandledJob.perform_later'
class AddMechanismHandledTracking < ActiveRecord::Migration[8.1]
  def change
    add_column :errors_events, :handled, :boolean
    add_column :errors_groups, :has_unhandled, :boolean, default: false, null: false
    add_column :alerting_rules, :unhandled_only, :boolean, default: false, null: false
  end
end
