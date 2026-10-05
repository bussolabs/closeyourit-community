# frozen_string_literal: true

# CYRA-245 — sostituire la credenziale di una macchina già collegata diventa un gesto esplicito di una
# persona, non un effetto collaterale di un push. `reenrollment_requested_at` apre la finestra dalla
# scheda della macchina; `enrollment_conflict_at` registra l'ultimo tentativo di prendere il posto di
# una macchina che sta ancora riportando (fuori dalla finestra), perché altrimenti non se ne
# accorgerebbe nessuno: il push viene comunque accettato e non si vede niente.
class AddReenrollmentToServersHosts < ActiveRecord::Migration[8.1]
  def change
    add_column :servers_hosts, :reenrollment_requested_at, :datetime
    add_column :servers_hosts, :enrollment_conflict_at, :datetime
  end
end
