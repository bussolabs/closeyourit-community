# frozen_string_literal: true

module Dashboards
  # Turns a feed's last saved report (contract open-dashboard/v1) into what a page shows: formatted
  # values, the change against the previous period and whether that change is good. CYRA-1112
  class ReportView
    include ActiveSupport::NumberHelper

    HEADLINE = 4
    DASH = "—"

    Metric = Data.define(:key, :label, :group, :value_text, :unavailable, :delta_text, :direction, :tone, :period) do
      def unavailable? = unavailable
    end

    def initialize(feed)
      @feed = feed
      @payload = feed.payload
    end

    def state
      return :never if @payload.blank?

      @feed.last_error.present? ? :failed : :ok
    end

    def service
      return nil if @payload.blank?

      identity = @payload.fetch("service", {})
      { name: identity["name"].presence || DASH, version: identity["version"].presence || DASH,
        environment: identity["environment"].presence || DASH }
    end

    def metrics
      @metrics ||= Array(@payload&.dig("metrics")).map { |raw| build(raw) }
    end

    def groups = metrics.group_by(&:group).to_a

    def headline = metrics.first(HEADLINE)

    private

    def build(raw)
      value = raw["value"]
      direction, delta = change(raw["type"], value, raw["previous"])
      Metric.new(key: raw["key"], label: raw["label"], group: raw["group"],
                 value_text: value.nil? ? DASH : format_value(raw["type"], value, raw["currency"]),
                 unavailable: value.nil?, delta_text: delta, direction:,
                 tone: tone(direction, raw["better"]), period: raw["period"])
    end

    def change(type, value, previous)
      return [ nil, nil ] if value.nil? || previous.nil? || (type != "percent" && previous.zero?)

      diff = value - previous
      direction = diff.positive? ? :up : (diff.negative? ? :down : :flat)
      text = if type == "percent"
        "#{sign(diff)}#{decimal(diff.abs, 1)} pt"
      else
        "#{sign(diff)}#{decimal((diff.abs * 100.0 / previous.abs), 1)}%"
      end
      [ direction, direction == :flat ? (type == "percent" ? "0 pt" : "0%") : text ]
    end

    def sign(diff) = diff.positive? ? "+" : (diff.negative? ? "−" : "")

    def tone(direction, better)
      return :neutral if better.nil? || direction.nil? || direction == :flat

      direction.to_s == better ? :good : :bad
    end

    def format_value(type, value, currency)
      case type
      when "money" then "#{decimal(value / 100.0, 2, strip: false)} #{currency}"
      when "percent" then "#{decimal(value, 1)}%"
      when "duration" then duration(value.to_i)
      else number_to_delimited(value, delimiter: delimiter, separator: separator)
      end
    end

    def decimal(number, precision, strip: true)
      number_to_rounded(number, precision:, strip_insignificant_zeros: strip, delimiter:, separator:)
    end

    def duration(seconds)
      hours, rest = seconds.divmod(3600)
      minutes, secs = rest.divmod(60)
      parts = []
      parts << "#{hours} #{I18n.t('member.dashboards.units.hours')}" if hours.positive?
      parts << "#{minutes} #{I18n.t('member.dashboards.units.minutes')}" if minutes.positive?
      parts << "#{secs} #{I18n.t('member.dashboards.units.seconds')}" if secs.positive? || parts.empty?
      parts.join(" ")
    end

    def delimiter = I18n.t("member.dashboards.number.delimiter")
    def separator = I18n.t("member.dashboards.number.separator")
  end
end
