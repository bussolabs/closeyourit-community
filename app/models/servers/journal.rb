# frozen_string_literal: true

module Servers
  # Sotto-namespace dei log nativi journald dell'host (distinti dai log applicativi Logs::Entry,
  # che sono project-scoped). Nesting a due livelli per tenere il leaf a UNA parola (Entry) senza
  # collidere con Logs:: — il prefisso tabella più vicino vince su quello di Servers (servers_).
  module Journal
    def self.table_name_prefix
      "servers_journal_"
    end
  end
end
