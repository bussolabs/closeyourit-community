# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::CommentNotifyJob, type: :job do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:author) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
  end
  let(:watcher) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
  end
  let(:ticket) { create(:ticket, organization: organization, project: project, reporter: author) }
  let(:comment) { create(:ticket_comment, ticket: ticket, author: author, body: "ping") }

  describe "#perform" do
    it "delega a DispatchComment (crea le notifiche per i watcher)" do
      Ticketing::Subscription.ensure_for(ticket: ticket, account: watcher, source: :manual)
      comment

      expect { described_class.perform_now(comment_id: comment.id) }
        .to change(Alerting::Notification.where(account: watcher), :count).by_at_least(1)
    end

    it "commento inesistente (sparito) → no-op" do
      expect { described_class.perform_now(comment_id: SecureRandom.uuid) }
        .not_to change(Alerting::Notification, :count)
    end
  end
end
