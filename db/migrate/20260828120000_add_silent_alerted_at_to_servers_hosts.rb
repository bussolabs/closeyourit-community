# frozen_string_literal: true

# CYRA-676 — memoria della transizione per l'avviso "dati fermi": l'allarme parte una volta sola
# quando il silenzio supera la soglia, e questa colonna è ciò che impedisce di ripeterlo a ogni giro
# del job. L'ingest la azzera al primo dato fresco, riarmando l'avviso per il silenzio successivo.
# Lo stato "silent" in sé resta derivato e mai persistito (Servers::Host#silent?): qui si persiste
# solo il fatto di aver già avvisato.
class AddSilentAlertedAtToServersHosts < ActiveRecord::Migration[8.1]
  def change
    add_column :servers_hosts, :silent_alerted_at, :datetime
  end
end
