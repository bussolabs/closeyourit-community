# frozen_string_literal: true

require "rails_helper"

RSpec.describe Logs::Entry, "OTLP storage boundaries" do
  let(:project) { create(:project) }

  def row(**overrides)
    { project_id: project.id, event_id: SecureRandom.uuid, message: "boundary", level: 1,
      occurred_at: Time.current, created_at: Time.current }.merge(overrides)
  end

  it "round-trips maximum unsigned timestamps through both model and bulk writes" do
    maximum = "18446744073709551615"
    ordinary = described_class.create!(row(event_time_unix_nano: maximum, observed_time_unix_nano: maximum))
    described_class::Bulk.insert_all!([ row(event_time_unix_nano: maximum, observed_time_unix_nano: maximum) ])
    expect(ordinary.reload.event_time_unix_nano.to_i.to_s).to eq(maximum)
    expect(project.logs_entries.map { |entry| [ entry.event_time_unix_nano.to_i.to_s, entry.observed_time_unix_nano.to_i.to_s ] }).to eq([ [ maximum, maximum ], [ maximum, maximum ] ])
  end

  it "rejects out-of-range severity and unsigned times at the database boundary" do
    project
    [ %i[event_time_unix_nano observed_time_unix_nano].product([ -1, "18446744073709551616" ]), [ [ :severity_number, -1 ], [ :severity_number, 25 ] ] ].flatten(1).each do |column, value|
      expect do
        ApplicationRecord.transaction(requires_new: true) { described_class::Bulk.insert_all!([ row(column => value) ]) }
      end.to raise_error(ActiveRecord::StatementInvalid, /check constraint/)
    end
  end
end
