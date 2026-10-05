# frozen_string_literal: true

module Member
  module MeasurementsHelper
    def measurement_exact_filter?(key)
      params[key].is_a?(String) && params[key] != ""
    end

    def measurement_label(key)
      t("member.measurements.#{key}")
    end

    def measurement_number(value)
      return "—" if value.nil?
      decimal = BigDecimal(value.to_s)
      return "—" unless decimal.finite?
      number_with_delimiter(decimal.to_s("F").sub(/\.0+\z/, ""))
    rescue ArgumentError
      "—"
    end

    def measurement_time(nanoseconds)
      Time.at(Rational(nanoseconds.to_s) / 1_000_000_000).in_time_zone
    end

    def measurement_timestamp(nanoseconds)
      value = measurement_time(nanoseconds)
      fraction = value.nsec.zero? ? "" : ".#{format('%09d', value.nsec).sub(/0+\z/, '')}"
      "#{value.strftime('%Y-%m-%d %H:%M:%S')}#{fraction} #{value.strftime('%:z')}"
    end

    def measurement_unit(series, statistic)
      return measurement_label("observations") if statistic == "count"
      statistic == "rate" ? "#{series.unit.presence || '1'}/s" : series.unit
    end

    def measurement_evaluation_unit(evaluation)
      evaluation.result["statistic"] == "count" ? measurement_label("observations") : evaluation.result["unit"]
    end

    def measurement_bounds(estimate)
      value = estimate.with_indifferent_access
      "#{value[:lower_inclusive] ? '[' : '('}#{measurement_number(value[:lower_bound])}, #{measurement_number(value[:upper_bound])}#{value[:upper_inclusive] ? ']' : ')'}"
    end

    def measurement_view_sections(keys)
      [ { heading: measurement_label("sort"), choices: keys.flat_map { |key| [ key, "-#{key}" ].map do |sort|
        { label: "#{measurement_label(key)} #{sort.start_with?('-') ? '↓' : '↑'}", href: "#{request.path}?#{request.query_parameters.except('page').merge('sort' => sort).to_query}", active: params[:sort] == sort }
      end } } ]
    end

    def measurement_bucket_value(bucket, statistic)
      return nil unless bucket[:status] == "known"
      return bucket[:quantiles]&.first&.then { |estimate| estimate[:estimate] if estimate[:status] == "known" } if statistic == "percentile"
      bucket[:value][statistic.to_sym] || bucket[:value][statistic]
    end

    def measurement_latest(point)
      return nil unless point && (point.payload.fetch("flags", 0).to_i & 1).zero?
      point.payload["asInt"] || point.payload["asDouble"] || point.payload["count"]
    end

    def measurement_chart(buckets, series, statistic)
      values = buckets.map { |bucket| measurement_bucket_value(bucket, statistic) }
      numbers = values.compact.map { |value| BigDecimal(value.to_s) }.select(&:finite?)
      floor, ceiling = [ numbers.min || 0, 0 ].min, [ numbers.max || 0, 0 ].max
      span = ceiling - floor
      bars = buckets.zip(values).map do |bucket, value|
        measurement_chart_bar(bucket, value, series, statistic, floor, span)
      end
      zero = span.zero? ? 50 : (-floor * 100 / span).to_f
      gridlines = span.zero? ? [] : [ { value: "#{measurement_number(ceiling)} #{measurement_unit(series, statistic)}", pct: 100 },
        { value: "#{measurement_number(floor)} #{measurement_unit(series, statistic)}", pct: 0 } ]
      gridlines.reject! { |line| line[:pct] == zero }
      gridlines << { value: "0 #{measurement_unit(series, statistic)}", pct: zero, baseline: true }
      { bars: bars, gridlines: gridlines,
        xticks: buckets.empty? ? [] : [ { label: l(measurement_time(buckets.first[:start_time_unix_nano]), format: :short), pct: 0 },
          { label: l(measurement_time(buckets.last[:time_unix_nano]), format: :short), pct: 100 } ],
        summary: measurement_label("chart_note"), empty_label: measurement_label("unknown"), buckets_test_id: "measurement-chart" }
    end
    def measurement_chart_bar(bucket, value, series, statistic, floor, span)
      number = value && BigDecimal(value.to_s)
      known = number&.finite?
      label = "#{measurement_number(value)} #{measurement_unit(series, statistic)}".strip
      { height: known ? (span.zero? ? 0 : (number.abs * 100 / span).to_f) : 0,
        bottom: known ? (span.zero? ? 50 : (([ number, 0 ].min - floor) * 100 / span).to_f) : 0,
        color_class: "bg-indigo-500", unsampled: !known,
        time_label: measurement_timestamp(bucket[:time_unix_nano]),
        value_line: known ? label : measurement_label("unknown"), aria_label: label }
    end
  end
end
