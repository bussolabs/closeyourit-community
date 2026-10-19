# frozen_string_literal: true

module Analytics
  # The headline numbers of every site at once, for the analytics index: a few grouped queries over
  # all projects instead of one dashboard query set per project. Counts follow Analytics::Query
  # (pageviews only, health checks left out, one environment); `online` and `connected` copy the
  # dashboard's own realtime count and "ever received" check. CYRA-1077
  class Overview
    Row = Data.define(:project, :pageviews, :visitors, :previous_pageviews, :previous_visitors,
                      :online, :trend, :last_at, :connected)

    def initialize(projects:, range: Pageview::DEFAULT_RANGE, environment: "production", now: Time.current)
      @projects = projects.to_a
      @range = Pageview::BUCKETS.key?(range) ? range : Pageview::DEFAULT_RANGE
      @environment = environment
      @now = now
    end

    def rows
      return [] if @projects.empty?

      window = Pageview.window_seconds(@range)
      current = counts(@now - window, @now)
      previous = counts(@now - (2 * window), @now - window)
      online = online_counts
      trends = trends(@now - window)
      last_at = latest(real_traffic: true)
      connected = latest(real_traffic: false)

      @projects.map do |project|
        pageviews, visitors = current.fetch(project.id, [ 0, 0 ])
        previous_pageviews, previous_visitors = previous.fetch(project.id, [ 0, 0 ])
        Row.new(project:, pageviews:, visitors:, previous_pageviews:, previous_visitors:,
                online: online.fetch(project.id, 0), trend: trends.fetch(project.id, empty_trend),
                last_at: last_at[project.id], connected: connected[project.id].present?)
      end
    end

    private

    def ids = @projects.map(&:id)

    def traffic(since, till)
      Pageview.where(project_id: ids, name: Pageview::PAGEVIEW_NAME, environment: @environment,
                     occurred_at: since...till, created_at: ::Ingest::EpochTime.insert_floor(since)..)
              .where.not(path: Query::AUTOMATED_PATHS)
    end

    # Analytics::Query#realtime_count: no upper bound (a client clock ahead still counts) and no
    # health-check filter.
    def online_counts
      since = @now - Constants::REALTIME_WINDOW
      Pageview.where(project_id: ids, name: Pageview::PAGEVIEW_NAME, environment: @environment,
                     occurred_at: since.., created_at: ::Ingest::EpochTime.insert_floor(since)..)
              .group(:project_id).distinct.count(:visitor_hash)
    end

    # Newest event per site, one index lookup each (LIMIT 1 on project_id + occurred_at) instead of
    # a MAX over every partition. real_traffic: the row's rules; otherwise any event, as the
    # dashboard's "ever received".
    def latest(real_traffic:)
      conn = Pageview.connection
      filter = if real_traffic
        "AND p.name = #{conn.quote(Pageview::PAGEVIEW_NAME)} AND p.environment = #{conn.quote(@environment)} " \
          "AND p.path NOT IN (#{Query::AUTOMATED_PATHS.map { |path| conn.quote(path) }.join(', ')})"
      end
      sql = "SELECT ids.id, last.occurred_at FROM unnest(ARRAY[#{ids.map { |id| conn.quote(id) }.join(', ')}]::uuid[]) AS ids(id) " \
            "CROSS JOIN LATERAL (SELECT p.occurred_at FROM #{Pageview.quoted_table_name} p " \
            "WHERE p.project_id = ids.id #{filter} ORDER BY p.occurred_at DESC LIMIT 1) last"
      conn.select_rows(sql).to_h { |id, at| [ id, at && Pageview.type_for_attribute(:occurred_at).deserialize(at) ] }
    end

    def counts(since, till)
      traffic(since, till).group(:project_id)
                          .pluck(:project_id, Arel.sql("COUNT(*)"), Arel.sql("COUNT(DISTINCT visitor_hash)"))
                          .to_h { |id, pageviews, visitors| [ id, [ pageviews, visitors ] ] }
    end

    # Pageviews per bucket of the period, oldest first, the same buckets as the dashboard chart.
    def trends(since)
      cfg = Pageview.bucket_config(@range)
      bin = "date_bin(#{Pageview.connection.quote(cfg[:interval])}::interval, occurred_at, " \
            "#{Pageview.connection.quote(since)}::timestamptz)"
      traffic(since, @now).group(:project_id, Arel.sql(bin)).count.each_with_object({}) do |((id, at), count), out|
        # round, not floor: `since` has nanoseconds and the bin comes back at microseconds, a hair early.
        idx = ((at.to_time - since) / cfg[:seconds]).round
        (out[id] ||= empty_trend)[idx] = count if idx.between?(0, cfg[:count] - 1)
      end
    end

    def empty_trend = Array.new(Pageview.bucket_config(@range)[:count], 0)
  end
end
