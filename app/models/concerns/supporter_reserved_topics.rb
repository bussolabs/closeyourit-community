# frozen_string_literal: true

# CYAU-235 — the reserved topics an organization or a project adds for the supporter: one entry per line,
# trimmed, lowercased and without duplicates. Each entry is a word or, when it holds a slash, a code path.
module SupporterReservedTopics
  extend ActiveSupport::Concern

  MAX_ENTRIES = 200
  MAX_LENGTH = 100

  included do
    normalizes :supporter_reserved_topics, with: ->(value) { SupporterReservedTopics.clean(value).join("\n").presence }
    validate :supporter_reserved_topics_fit
  end

  def self.clean(value) = value.to_s.lines.map { |line| line.strip.downcase }.reject(&:empty?).uniq

  def supporter_reserved_topic_list = SupporterReservedTopics.clean(supporter_reserved_topics)

  private

  def supporter_reserved_topics_fit
    list = supporter_reserved_topic_list
    return if list.size <= MAX_ENTRIES && list.all? { |entry| entry.length <= MAX_LENGTH }

    errors.add(:supporter_reserved_topics, :too_long, count: MAX_LENGTH)
  end
end
