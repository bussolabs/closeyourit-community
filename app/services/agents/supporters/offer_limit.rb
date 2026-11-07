# frozen_string_literal: true

module Agents
  module Supporters
    # CYRA-1197 — a plan or a stop the machine cannot judge (its session fails, its answer is unreadable) posts
    # no verdict, so the server would offer it again every round while everything behind it waited. After a
    # few offers without a verdict the item rests for a while and the next one is served; it comes back later.
    module OfferLimit
      MAX_OFFERS = 3
      WINDOW = 1.hour

      module_function

      def resting?(host, digest) = Rails.cache.read(key(host, digest)).to_i >= MAX_OFFERS

      def offered!(host, digest)
        Rails.cache.increment(key(host, digest), 1, expires_in: WINDOW)
      end

      def key(host, digest) = "agents:supporter:offers:#{host.id}:#{digest}"
    end
  end
end
