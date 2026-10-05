# frozen_string_literal: true

# `updates_available` conta TUTTI gli aggiornamenti in attesa, ma l'azione apply_security_updates ne
# installa solo il sottoinsieme di sicurezza: su un host con soli aggiornamenti ordinari il numero
# non scende mai e l'azione sembra rotta. Serve il secondo conteggio per dire quale azione serve.
# Nullable di proposito: un agent < 0.8.0 non lo manda e "sconosciuto" non è "zero".
class AddSecurityUpdatesAvailableToServersHosts < ActiveRecord::Migration[8.1]
  def change
    add_column :servers_hosts, :security_updates_available, :integer
  end
end
