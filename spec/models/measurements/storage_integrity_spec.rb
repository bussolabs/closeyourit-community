# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Measurement storage integrity", type: :model do
  let(:project) { create(:project) }

  def ingest(start: "1", finish: "2", value: "9223372036854775807")
    point = { "startTimeUnixNano" => start, "timeUnixNano" => finish, "asInt" => value }
    payload = { "resourceMetrics" => [ { "scopeMetrics" => [ { "metrics" => [ {
      "name" => "requests", "sum" => { "aggregationTemporality" => 1, "isMonotonic" => true, "dataPoints" => [ point ] }
    } ] } ] } ] }
    expect(Measurements::Ingest::Record.call(project:, payload:).rejected).to eq(0)
    project.measurement_points.sole
  end

  it "enforces the project and series relationship when model validation is bypassed" do
    point = ingest
    other = create(:project)
    attributes = point.attributes.except("id").merge("project_id" => other.id, "time_unix_nano" => 3)
    expect do
      Measurements::Point.transaction(requires_new: true) { Measurements::Point.insert_all!([ attributes ]) }
    end.to raise_error(ActiveRecord::InvalidForeignKey, /measurements_points_tenant_identity/)
    expect(other.measurement_points.count).to eq(0)
  end

  it "keeps point identity unique across server arrival months" do
    point = ingest
    attributes = point.attributes.except("id").merge("first_received_at" => 2.months.from_now)
    expect do
      Measurements::Point.transaction(requires_new: true) { Measurements::Point.insert_all!([ attributes ]) }
    end.to raise_error(ActiveRecord::RecordNotUnique, /measurements_points_identity/)
    expect(project.measurement_points.count).to eq(1)
  end

  it "stores uint64 timestamps and int64 values without floating point conversion" do
    point = ingest(start: "18446744073709551614", finish: "18446744073709551615")
    expect(point.start_time_unix_nano.to_i).to eq((2**64) - 2)
    expect(point.time_unix_nano.to_i).to eq((2**64) - 1)
    expect(point.time_unix_nano - point.start_time_unix_nano).to eq(1)
    expect(point.payload.fetch("asInt")).to eq("9223372036854775807")
  end

  it "rejects reversed intervals at the database boundary" do
    point = ingest
    expect do
      Measurements::Point.transaction(requires_new: true) { point.update_column(:start_time_unix_nano, 3) }
    end.to raise_error(ActiveRecord::StatementInvalid, /measurements_points_valid_time/)
    expect(point.reload.start_time_unix_nano.to_i).to eq(1)
  end

  it "enforces global retention bounds at the database boundary" do
    settings = Settings::Global.instance
    expect do
      Settings::Global.transaction(requires_new: true) { settings.update_column(:measurements_retention_days, 0) }
    end.to raise_error(ActiveRecord::StatementInvalid, /settings_valid_measurement_retention/)
    expect(settings.reload.measurements_retention_days).to eq(14)
  end

  it "cascades project deletion to series and points" do
    point = ingest
    series_id = point.series_id
    project.delete
    expect(Measurements::Point.exists?(point.id)).to be(false)
    expect(Measurements::Series.exists?(series_id)).to be(false)
  end
end
