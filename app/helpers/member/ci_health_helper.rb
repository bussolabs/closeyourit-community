# frozen_string_literal: true

module Member
  # Formatting of the CI health figures (CYRA-1164): shares as whole percentages, times as minutes and seconds.
  module CiHealthHelper
    def ci_health_percent(rate)
      rate.nil? ? "–" : number_to_percentage(rate * 100, precision: 0)
    end

    def ci_health_duration(seconds)
      return "–" if seconds.nil?

      minutes, rest = seconds.round.divmod(60)
      minutes.zero? ? "#{rest} s" : "#{minutes} min #{rest} s"
    end
  end
end
