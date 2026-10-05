# frozen_string_literal: true

module Agents
  module Leases
    # Clock condiviso dai nodi Rails: PostgreSQL è l'unica autorità sulle scadenze lease.
    module Clock
      module_function

      def current
        Agents::Lease.connection.select_value("SELECT clock_timestamp()", "Agents lease clock").in_time_zone
      end
    end
  end
end
