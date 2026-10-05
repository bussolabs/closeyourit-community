# frozen_string_literal: true

module Member
  module Monitoring
    # Presentation only: never resolve artifacts or modify received evidence during a page read.
    class SymbolicationPresenter
      attr_reader :event, :result

      def initialize(event:, result:, native_report: nil)
        @event = event
        @result = result || { "status" => "pending", "frames" => [] }
        @native_report = native_report
      end

      def applicable?
        return true if native?
        platform = event.payload["platform"]
        return %w[javascript node java].include?(platform) if platform.present?
        result["kind"] == "proguard" || Array(result["frames"]).any? { |row| row["status"] == "mapped" }
      end

      def native? = event.payload["platform"] == "native" || result["kind"] == "native"
      def native = @native ||= NativeSymbolicationPresenter.new(result: result, report: @native_report)
      def java? = !native? && (event.payload["platform"] == "java" || result["kind"] == "proguard")
      def status = native? ? native.status : result.fetch("status", "pending")
      def reason = result["reason"].presence || (status == "unresolved" ? rows.first&.dig(:status) : nil)
      def command = "cyi artifacts #{native? ? 'native-symbols' : (java? ? 'proguard-maps' : 'source-maps')} upload --help"

      def rows
        @rows ||= java? ? java_rows : javascript_rows
      end

      def received_java
        return [] unless java?
        @received_java ||= Errors::Symbolication::Java::Stack.call(values: event.payload.dig("exception", "values"))
      rescue ::Artifacts::Rejected, TypeError
        []
      end

      def exceptions
        values = event.payload.dig("exception", "values")
        values.is_a?(Array) ? values.map { |value| value.is_a?(Hash) ? value : {} } : []
      rescue TypeError
        []
      end

      def self.frames(stack)
        stack.is_a?(Hash) && stack["frames"].is_a?(Array) ? stack["frames"].select { |frame| frame.is_a?(Hash) } : []
      end

      def exception_frames(exception) = self.class.frames(exception["stacktrace"])

      private

      def java_rows
        Array(result["groups"]).map do |group|
          { status: group["status"], kind: group["kind"], alternatives: group.fetch("alternatives", []),
            received_line: received_java[group["index"].to_i]&.fetch("line", nil) }
        end
      end

      def javascript_rows
        Array(result["frames"]).group_by { |entry| entry["exception_index"] }.flat_map do |exception_index, entries|
          exception = exception_index.nil? ? nil : exceptions[exception_index]
          source = exception ? exception["stacktrace"] : event.stacktrace
          frames = source.is_a?(Hash) && source["frames"].is_a?(Array) ? source["frames"] : []
          entries.reverse.map do |entry|
            { status: entry["status"], original: entry["original"], mapped_name: entry["mapped_name"],
              received: frames[entry["index"].to_i].is_a?(Hash) ? frames[entry["index"].to_i] : {}, exception: exception&.dig("type") }
          end
        end
      end
    end
  end
end
