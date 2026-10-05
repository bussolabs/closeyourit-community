# frozen_string_literal: true

module Search
  # Quick cross-area search of the member area. Every source starts from the viewer's visible scope
  # (Search::Sources): the service can only narrow what the account already sees. Plain text on
  # purpose: it runs while typing and must not wait for embeddings or rerankers.
  class Global < ApplicationService
    MIN_QUERY_LENGTH = 2
    LIMIT_PER_GROUP = 5
    LIMIT_FILTERED = 20
    KEYS = %i[
      nav projects tickets error_groups pages books ideas monitors cron_monitors
      servers groups teams people conversations secrets
    ].freeze

    Group = Data.define(:key, :records, :total, :exact)
    # `kinds` are the filters on offer: every kind with results, whatever the chosen type.
    Found = Data.define(:groups, :kinds)
    # One entry of the side menu, already filtered by the menu's own rules (CYRA-900).
    NavEntry = Data.define(:label, :path, :icon)

    def initialize(query:, visible:, viewer:, organization:, nav_items: [], type: nil)
      @query = query.to_s.strip.first(100)
      @type = KEYS.find { |key| key.to_s == type.to_s }
      @sources = Sources.new(query: @query, visible: visible, viewer: viewer,
                             organization: organization, nav_items: nav_items)
    end

    def call
      return Found.new(groups: [], kinds: []) if @query.length < MIN_QUERY_LENGTH

      groups = exact_first(KEYS.filter_map { |key| group(key, LIMIT_PER_GROUP) })
      kinds = groups.map(&:key)
      return Found.new(groups: groups, kinds: kinds) unless kinds.include?(@type)

      Found.new(groups: [ group(@type, LIMIT_FILTERED) ], kinds: kinds)
    end

    private

    def group(key, limit)
      exact = @sources.exact(key)
      found = @sources.public_send(key)
      records = records_for(found, exact, limit)
      return if records.empty?

      Group.new(key: key, records: records, total: total(found, records, limit), exact: exact.present?)
    end

    def records_for(found, exact, limit)
      return found.first(limit) unless found.is_a?(ActiveRecord::Relation)
      return found.limit(limit).to_a unless exact

      [ exact, *found.where.not(id: exact.id).limit(limit - 1) ]
    end

    def total(found, records, limit)
      return records.size if records.size < limit
      return found.size unless found.is_a?(ActiveRecord::Relation)

      found.unscope(:limit, :order).count
    end

    # A ticket code or project key typed in full opens with Enter: its group goes first.
    def exact_first(groups)
      groups.partition(&:exact).flatten
    end
  end
end
