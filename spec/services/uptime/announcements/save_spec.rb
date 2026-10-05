# frozen_string_literal: true

require "rails_helper"

RSpec.describe Uptime::Announcements::Save do
  let(:monitor) { create(:uptime_monitor) }
  let(:actor)   { create(:account) }

  it "crea il banner del monitor (upsert: uno solo)" do
    result = described_class.call(monitor:,
                                  attributes: { level: "maintenance", message: "Manutenzione", active: true }, actor:)

    expect(result).to be_ok
    expect(monitor.reload.announcement).to have_attributes(level: "maintenance", message: "Manutenzione", created_by_id: actor.id)
  end

  it "aggiorna il banner esistente senza crearne un secondo" do
    create(:uptime_announcement, monitor:, message: "Vecchio")
    expect do
      described_class.call(monitor:, attributes: { message: "Nuovo" })
    end.not_to change(Uptime::Announcement, :count)
    expect(monitor.reload.announcement.message).to eq("Nuovo")
  end

  it "messaggio blank → R422-UPTIME-003" do
    result = described_class.call(monitor:, attributes: { message: "  " })
    expect(result).to be_err
    expect(result.error.code).to eq("R422-UPTIME-003")
  end

  it "finestra invalida (ends ≤ starts) → R422-UPTIME-003" do
    result = described_class.call(monitor:, attributes: {
                                    message: "x", starts_at: Time.utc(2026, 6, 26, 12), ends_at: Time.utc(2026, 6, 26, 11)
                                  })
    expect(result).to be_err
    expect(result.error.code).to eq("R422-UPTIME-003")
  end
end
