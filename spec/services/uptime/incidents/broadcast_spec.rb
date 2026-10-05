# frozen_string_literal: true

require "rails_helper"

RSpec.describe Uptime::Incidents::Broadcast do
  let(:monitor) { create(:uptime_monitor) }

  describe ".incidents" do
    it "fa il replace Turbo del target incidents del monitor" do
      expect(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
      described_class.incidents(monitor)
    end

    it "un fallimento del broadcast NON propaga: una mutazione già committata (es. ungroup) non deve 500" do
      allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
        .and_raise(ActiveRecord::StatementInvalid, "SQLite3::BusyException: database is locked")

      expect { described_class.incidents(monitor) }.not_to raise_error
    end

    it "logga a error e ritorna nil quando il broadcast fallisce" do
      allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to).and_raise(StandardError, "cable down")
      expect(Rails.logger).to receive(:error).with(/Broadcast\.incidents failed monitor=#{monitor.id}/)

      expect(described_class.incidents(monitor)).to be_nil
    end
  end
end
