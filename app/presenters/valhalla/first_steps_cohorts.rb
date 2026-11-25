# frozen_string_literal: true

module Valhalla
  # How many organizations reached each first step, by signup week (CYRA-1159): the last WEEKS weeks,
  # newest first, then one row for the organizations born before the steps were recorded. Their
  # dates are rebuilt, so they stay out of the weeks instead of skewing them. One query.
  class FirstStepsCohorts
    WEEKS = 12

    Row = Data.define(:week, :signed_up, :steps) do
      def preexisting? = week.nil?
      def reached(step) = steps.fetch(step, 0)
    end

    # Weeks start on Monday in UTC, like PostgreSQL's date_trunc('week', …).
    def initialize(now: Time.current)
      @first_week = now.utc.to_date.beginning_of_week - (WEEKS - 1).weeks
    end

    def rows
      counts = query.to_h { |week, signed_up, *reached| [ week, row(week, signed_up, reached) ] }
      weeks = Array.new(WEEKS) { |index| @first_week + (WEEKS - 1 - index).weeks }
      weeks.map { |week| counts.fetch(week) { row(week, 0, []) } } + [ counts.fetch(nil) { row(nil, 0, []) } ]
    end

    private

    def row(week, signed_up, reached)
      Row.new(week: week, signed_up: signed_up,
              steps: Organizations::FirstStep::STEPS.zip(reached).to_h { |step, count| [ step, count.to_i ] })
    end

    def query
      organizations = Organizations::Organization
      week = "CASE WHEN organizations.first_steps_preexisting THEN NULL " \
             "ELSE CAST(date_trunc('week', organizations.created_at) AS date) END"
      per_step = Organizations::FirstStep::STEPS.map do |step|
        Arel.sql(organizations.sanitize_sql_array(
          [ "COUNT(DISTINCT organizations.id) FILTER (WHERE organization_first_steps.step = ?)", step ]
        ))
      end
      organizations.where(first_steps_preexisting: true)
                   .or(organizations.where(created_at: @first_week.in_time_zone("UTC")..))
                   .left_joins(:first_steps)
                   .group(Arel.sql(week))
                   .pluck(Arel.sql(week), Arel.sql("COUNT(DISTINCT organizations.id)"), *per_step)
    end
  end
end
