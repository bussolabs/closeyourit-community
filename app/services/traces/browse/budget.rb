# frozen_string_literal: true

module Traces
  module Browse
    module Budget
      def self.within
        [ Trace, Span ].each { |model| model.columns_hash }
        Trace.connection_pool.with_connection do |connection|
          Trace.transaction(requires_new: true) do
            previous = connection.select_value("SHOW statement_timeout")
            connection.execute("SET LOCAL statement_timeout = '1s'")
            value = yield
            connection.execute("SET LOCAL statement_timeout = #{connection.quote(previous)}")
            value
          end
        end
      rescue ActiveRecord::QueryCanceled
        raise Unavailable, "Trace query exceeded its time budget"
      end
    end
  end
end
