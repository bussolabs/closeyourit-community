# frozen_string_literal: true

require "rails_helper"

# O2, G3 — with no job the page says there is no job, in plain words: no "heartbeat" and no API
# path in the message. The address to call lives on the setup page the button opens.
RSpec.describe "Crons empty page wording" do
  %i[en it].each do |locale|
    it "#{locale}: names no API path and no heartbeat" do
      texts = %w[empty empty_body].map { |key| I18n.t("member.crons.#{key}", locale: locale) }

      expect(texts.join(" ")).not_to match(%r{heartbeat|/api/|POST}i)
    end
  end
end
