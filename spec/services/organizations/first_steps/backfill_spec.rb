# frozen_string_literal: true

require "rails_helper"

# CYRA-1159 — the steps of the organizations already there come from their data, oldest date found,
# so a mature organization does not see the list appear.
RSpec.describe Organizations::FirstSteps::Backfill do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :owner) } }
  let(:project) { create(:project, organization: organization) }

  def reached(step) = organization.first_steps.find_by(step: step)&.reached_at

  it "rebuilds all five steps with the oldest date found" do
    create(:error_group, project:, first_seen_at: Time.zone.local(2026, 3, 1))
    create(:error_group, project:, first_seen_at: Time.zone.local(2026, 2, 1))
    create(:alerting_rule, organization:, name: "Mine", created_at: Time.zone.local(2026, 4, 1))
    create(:invitation, organization:, invited_by: owner, created_at: Time.zone.local(2026, 5, 1))
    owner.update_columns(telegram_chat_id: "42", telegram_linked_at: Time.zone.local(2026, 6, 1))
    done = create(:ticket_status, :done, organization:)
    create(:ticket, organization:, project:, status: done).update_columns(closed_at: Time.zone.local(2026, 7, 1))
    # The data above predates the release: nothing was recorded live yet when the rebuild runs.
    Organizations::FirstStep.delete_all

    described_class.call

    expect(reached("first_error")).to eq(Time.zone.local(2026, 2, 1))
    expect(reached("alert_rule")).to eq(Time.zone.local(2026, 4, 1))
    expect(reached("invitation")).to eq(Time.zone.local(2026, 5, 1))
    expect(reached("telegram")).to be >= Time.zone.local(2026, 6, 1)
    expect(reached("ticket_closed")).to eq(Time.zone.local(2026, 7, 1))
    expect(Organizations::FirstSteps::Checklist.for(organization.reload)).to be_nil
  end

  it "leaves out the default alert rules and the steps never taken" do
    Alerting::Rules::InstallDefaults.call(organization:, created_by: owner)

    described_class.call

    expect(organization.first_steps).to be_empty
  end

  it "counts a linked Telegram group" do
    Alerting::TelegramGroup.create!(organization:, account: owner, chat_id: "-100")

    described_class.call

    expect(reached("telegram")).to be_present
  end

  it "never touches a step already written and changes nothing when run again" do
    Organizations::FirstStep.record!(:invitation, organization_ids: organization.id, at: Time.zone.local(2026, 9, 1))
    create(:invitation, organization:, invited_by: owner, created_at: Time.zone.local(2026, 1, 1))
    create(:error_group, project:, first_seen_at: Time.zone.local(2026, 2, 1))

    2.times { described_class.call }

    expect(organization.first_steps.group(:step).count).to eq("invitation" => 1, "first_error" => 1)
    expect(reached("invitation")).to eq(Time.zone.local(2026, 9, 1))
    expect(reached("first_error")).to eq(Time.zone.local(2026, 2, 1))
  end
end
