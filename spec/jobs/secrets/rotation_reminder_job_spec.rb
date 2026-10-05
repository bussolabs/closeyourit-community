# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::RotationReminderJob, type: :job do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:environment) { create(:environment, organization: organization).tap { |e| project.environments << e } }
  let(:owner) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :owner) }
  end

  def variable_overdue(days_ago_rotated: 2)
    create(:secret_variable, project: project, environment: environment,
                             rotation_interval_days: 1, rotated_at: Time.current - days_ago_rotated.days)
  end

  def variable_due_soon
    create(:secret_variable, project: project, environment: environment,
                             rotation_interval_days: 14, rotated_at: Time.current)
  end

  def variable_ok
    create(:secret_variable, project: project, environment: environment,
                             rotation_interval_days: 90, rotated_at: Time.current)
  end

  it "gira sulla coda :notifications" do
    expect(described_class.new.queue_name).to eq("notifications")
  end

  describe "#perform" do
    it "notifica i secret :due_soon e :overdue" do
      owner
      due_soon = variable_due_soon
      overdue = variable_overdue

      described_class.perform_now

      expect(Alerting::Notification.where(account: owner, subject: due_soon, event_type: :secret_rotation_due)).to exist
      expect(Alerting::Notification.where(account: owner, subject: overdue, event_type: :secret_rotation_due)).to exist
    end

    it "ignora i secret :ok e :none" do
      owner
      ok = variable_ok
      none = create(:secret_variable, project: project, environment: environment, rotation_interval_days: nil)

      described_class.perform_now

      expect(Alerting::Notification.where(subject: ok)).not_to exist
      expect(Alerting::Notification.where(subject: none)).not_to exist
    end

    it "due esecuzioni consecutive non duplicano (idempotenza end-to-end)" do
      owner
      variable_overdue

      described_class.perform_now
      expect { described_class.perform_now }.not_to change(Alerting::Notification, :count)
    end

    it "org-wide: copre secret di progetti/organizzazioni diverse in una sola esecuzione, precaricando le associazioni" do
      owner
      variable_overdue

      other_org = create(:organization)
      other_project = create(:project, organization: other_org)
      other_environment = create(:environment, organization: other_org).tap { |e| other_project.environments << e }
      other_owner = create(:account).tap { |a| create(:membership, account: a, organization: other_org, role: :owner) }
      other_variable = create(:secret_variable, project: other_project, environment: other_environment,
                                                rotation_interval_days: 1, rotated_at: Time.current - 2.days)

      described_class.perform_now

      expect(Alerting::Notification.where(account: other_owner, subject: other_variable)).to exist
    end
  end
end
