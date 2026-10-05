# frozen_string_literal: true

module Agents
  module Limits
    # Autorità temporale condivisa tra nodi per scadenze, periodi giornalieri e slot paralleli.
    module Clock
      module_function

      def current
        Agents::LimitReservation.connection
                                .select_value("SELECT clock_timestamp()", "Agents limits clock")
                                .in_time_zone
      end
    end
  end
end
