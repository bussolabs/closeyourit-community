# frozen_string_literal: true

# CYRA-345: provenienza del trace_id dei log. false = campo strutturato inviato dal client;
# true = identificativo dedotto dal testo del messaggio (prefisso TaggedLogging / Job ID di
# ActiveJob), che la UI segnala come collegamento euristico. Default false: i log storici restano
# "strutturati" finché Logs::BackfillTraceIdsJob non popola e marca il trace mancante.
class AddTraceIdExtractedToLogsEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :logs_entries, :trace_id_extracted, :boolean, default: false, null: false
  end
end
