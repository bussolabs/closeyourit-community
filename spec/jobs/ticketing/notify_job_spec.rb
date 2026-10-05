# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::NotifyJob, type: :job do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:actor) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
  end
  # Status esplicito: il ticket adotta quello che trova nell'organizzazione, e con un solo status
  # la prova sullo spostamento avrebbe partenza e arrivo uguali, cioè nessuna mutazione da notificare.
  let(:ticket) do
    create(:ticket, organization: organization, project: project, reporter: actor,
                    status: create(:ticket_status, organization: organization))
  end

  describe "#perform" do
    it "delega a DispatchEvent (crea le notifiche per i watcher)" do
      watcher = create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
      Ticketing::Subscription.ensure_for(ticket: ticket, account: watcher, source: :manual)
      event = create(:ticket_event, ticket: ticket, actor: actor, action: "status_changed")

      expect { described_class.perform_now(event_id: event.id) }
        .to change(Alerting::Notification.where(account: watcher), :count).by_at_least(1)
    end

    it "evento inesistente → no-op" do
      expect { described_class.perform_now(event_id: SecureRandom.uuid) }
        .not_to change(Alerting::Notification, :count)
    end
  end

  describe "enqueue dai mutation service" do
    it "ChangeStatus (mutazione reale) accoda il job" do
      new_status = create(:ticket_status, organization: organization)
      expect do
        Ticketing::ChangeStatus.call(channel: :web, organization: organization, ticket: ticket, status_id: new_status.id, actor: actor)
      end.to have_enqueued_job(Ticketing::NotifyJob)
    end

    it "AssignTicket (mutazione reale) accoda il job" do
      assignee = create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
      expect do
        Ticketing::AssignTicket.call(organization: organization, ticket: ticket, assignee_id: assignee.id, actor: actor)
      end.to have_enqueued_job(Ticketing::NotifyJob)
    end

    it "un no-op (stesso status) NON accoda il job" do
      expect do
        Ticketing::ChangeStatus.call(channel: :web, organization: organization, ticket: ticket,
                                     status_id: ticket.status_id, actor: actor)
      end.not_to have_enqueued_job(Ticketing::NotifyJob)
    end
  end
end
