# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::Tokens::ExpiryReminderJob, type: :job do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:environment) { create(:environment, organization: organization).tap { |e| project.environments << e } }
  let(:owner) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :owner) }
  end

  def token(**attrs)
    create(:project_token, project: project, environment: environment, **attrs)
  end

  it "gira sulla coda :notifications" do
    expect(described_class.new.queue_name).to eq("notifications")
  end

  describe "#perform" do
    it "avvisa per i token in preavviso e per quelli già scaduti" do
      owner
      in_preavviso = token(expires_at: 3.days.from_now)
      scaduto = create(:project_token, :expired, project: project, environment: environment)

      described_class.perform_now

      expect(Alerting::Notification.where(account: owner, subject: in_preavviso,
                                          event_type: :project_token_expiring)).to exist
      expect(Alerting::Notification.where(account: owner, subject: scaduto,
                                          event_type: :project_token_expiring)).to exist
    end

    it "ignora i token senza scadenza, quelli lontani e quelli revocati" do
      owner
      senza = token
      lontano = token(expires_at: 60.days.from_now)
      revocato = token(expires_at: 3.days.from_now, revoked_at: Time.current)

      described_class.perform_now

      expect(Alerting::Notification.where(subject: senza)).not_to exist
      expect(Alerting::Notification.where(subject: lontano)).not_to exist
      expect(Alerting::Notification.where(subject: revocato)).not_to exist
    end

    it "due esecuzioni consecutive non duplicano (idempotenza end-to-end)" do
      owner
      token(expires_at: 3.days.from_now)

      described_class.perform_now
      expect { described_class.perform_now }.not_to change(Alerting::Notification, :count)
    end

    it "org-wide: copre i token di organizzazioni diverse in una sola esecuzione" do
      owner
      token(expires_at: 3.days.from_now)

      other_org = create(:organization)
      other_project = create(:project, organization: other_org)
      other_environment = create(:environment, organization: other_org).tap { |e| other_project.environments << e }
      other_owner = create(:account).tap { |a| create(:membership, account: a, organization: other_org, role: :owner) }
      other_token = create(:project_token, project: other_project, environment: other_environment,
                                           expires_at: 2.days.from_now)

      described_class.perform_now

      expect(Alerting::Notification.where(account: other_owner, subject: other_token)).to exist
    end
  end
end
