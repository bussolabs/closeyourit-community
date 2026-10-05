# frozen_string_literal: true

require "rails_helper"

# O1 — "review" is a ticket state and an approval step. Whether an agent may work a ticket is a
# different question: it is assessed, in both languages, so the two counts never read as one.
RSpec.describe "Agent assessment wording" do
  keys = %w[stats.pending_agent_eligibility member.tickets.agent_eligibility.pending]

  keys.each do |key|
    it "#{key} does not say review" do
      expect(I18n.t(key, locale: :en, raise: true)).not_to match(/review/i)
      expect(I18n.t(key, locale: :it, raise: true)).not_to match(/revision/i)
    end
  end
end
