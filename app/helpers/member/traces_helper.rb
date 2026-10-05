# frozen_string_literal: true

module Member
  module TracesHelper
    def trace_duration(value)
      return t("member.traces.unknown") if value.nil?
      decimal = (BigDecimal(value.to_s) / 1_000_000).to_s("F").sub(/\.?0+\z/, "")
      "#{decimal.empty? ? '0' : decimal} ms"
    end

    def trace_status(value)
      render Ui::BadgeComponent.new(label: t("member.traces.statuses.#{value}"), color: value == "error" ? :red : :gray, dot: true)
    end

    def trace_span_link(span)
      member_monitoring_trace_path(@trace, request.query_parameters.merge(span_id: span.span_id).except("logs_page", "errors_page"))
    end

    def trace_evidence(span)
      value = { resource: span.resource, instrumentation_scope: span.instrumentation_scope, payload: span.payload }
      text = JSON.pretty_generate(value)
      text.bytesize <= 64.kilobytes ? text : nil
    end

    def trace_identity(span, key)
      span.resource_identity[key].presence || t("member.traces.unknown")
    end
  end
end
