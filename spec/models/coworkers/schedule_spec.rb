require "rails_helper"

RSpec.describe Coworkers::Schedule do
  let(:organization) { create(:organization) }
  let(:account) { create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :owner) } }
  let(:puck) { Coworkers::Puck.create!(organization: organization, account: account, name: "Triage", instructions: "Help") }

  def build_schedule(**attributes)
    puck.schedules.build({ created_by: account, input: "Recap", hour: 9, minute: 30, time_zone: "Europe/Rome" }.merge(attributes))
  end

  describe "#cron" do
    it "writes one cron line per frequency" do
      expect(build_schedule(frequency: "hourly").cron).to eq("30 * * * *")
      expect(build_schedule(frequency: "daily").cron).to eq("30 9 * * *")
      expect(build_schedule(frequency: "weekdays").cron).to eq("30 9 * * 1-5")
      expect(build_schedule(frequency: "weekly", weekday: 3).cron).to eq("30 9 * * 3")
    end

    it "has no cron line for an unknown frequency" do
      expect(build_schedule(frequency: "yearly").cron).to be_nil
    end
  end

  describe "#next_after" do
    it "plans a weekly slot on its weekday in the schedule's time zone" do
      schedule = build_schedule(frequency: "weekly", weekday: 3)
      # 2026-10-07 is a Wednesday; 09:30 in Rome is 07:30 UTC.
      expect(schedule.next_after(Time.utc(2026, 10, 7, 8, 0))).to eq(Time.utc(2026, 10, 14, 7, 30))
    end

    it "skips the second copy of a daily slot in the repeated autumn hour" do
      schedule = build_schedule(frequency: "daily", hour: 2, minute: 30)
      expect(schedule.next_after(Time.utc(2026, 10, 25, 0, 30))).to eq(Time.utc(2026, 10, 26, 1, 30))
    end

    it "has no next slot when the fields cannot make a cron" do
      expect(build_schedule(frequency: "yearly").next_after(Time.current)).to be_nil
    end
  end

  it "refuses a schedule whose next slot cannot be planned" do
    allow(Fugit::Cron).to receive(:parse).and_return(nil)
    schedule = build_schedule(frequency: "daily")
    expect(schedule).not_to be_valid
    expect(schedule.errors.details[:frequency]).to include(error: :invalid)
    expect(schedule.next_run_at).to be_nil
  end
end
