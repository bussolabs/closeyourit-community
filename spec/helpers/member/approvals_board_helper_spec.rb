# frozen_string_literal: true

require "rails_helper"

RSpec.describe Member::ApprovalsBoardHelper, type: :helper do
  # CYRA-899 — the wait reads like a traffic light: grey under 8 hours, amber up to 2 days, red after.
  describe "#approval_wait_tone" do
    let(:now) { Time.zone.local(2026, 9, 30, 12) }

    it "is grey under eight hours" do
      expect(helper.approval_wait_tone(now - 7.hours, now:)).to eq(:fresh)
    end

    it "is amber from eight hours up to two days" do
      expect(helper.approval_wait_tone(now - 8.hours, now:)).to eq(:aging)
      expect(helper.approval_wait_tone(now - 47.hours, now:)).to eq(:aging)
    end

    it "is red from two days on" do
      expect(helper.approval_wait_tone(now - 2.days, now:)).to eq(:stale)
    end

    it "is grey when the wait is unknown" do
      expect(helper.approval_wait_tone(nil, now:)).to eq(:fresh)
    end
  end
end
