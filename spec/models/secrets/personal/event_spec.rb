# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Personal::Event do
  it "accetta le azioni ammesse" do
    described_class::ACTIONS.each do |action|
      event = build(:personal_secret_event, action:)
      expect(event).to be_valid, "attesa azione valida: #{action}"
    end
  end

  it "rifiuta l'azione synced (il personale non si sincronizza)" do
    event = build(:personal_secret_event, action: "synced")
    expect(event).not_to be_valid
  end

  it "espone .recent in ordine decrescente di creazione" do
    old = create(:personal_secret_event, created_at: 2.hours.ago)
    fresh = create(:personal_secret_event, created_at: 1.minute.ago)
    expect(described_class.recent.to_a).to eq([ fresh, old ])
  end
end
