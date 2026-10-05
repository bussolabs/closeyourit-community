class AddUpdatesToServersHosts < ActiveRecord::Migration[8.1]
  def change
    # Stato aggiornamenti riportato dall'agent (Debian/Ubuntu). reboot_required: kernel/libc
    # aggiornati in attesa di reboot. updates_available: pacchetti apt installabili; -1 = sconosciuto
    # (distro non-apt o apt-check assente) → la UI lo mostra come "n/d", non come "0".
    add_column :servers_hosts, :reboot_required, :boolean, null: false, default: false
    add_column :servers_hosts, :updates_available, :integer
  end
end
