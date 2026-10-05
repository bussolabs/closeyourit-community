# frozen_string_literal: true

# L'agent marca i container che un gestore di idle-sleep può fermare di proposito (label
# sablier.enable / closeyourit.idle_managed). Il flag va persistito sul campione perché quando il
# container è fermo non compare più nella lista Docker: senza memoria non sapremmo mai, al momento
# della sparizione, che quello stop era voluto.
class AddIdleManagedToServersContainerSamples < ActiveRecord::Migration[8.1]
  def change
    add_column :servers_container_samples, :idle_managed, :boolean, default: false, null: false
  end
end
