# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::LinkPreviews::RefreshJob, type: :job do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  it "runs on the lane that visits other sites" do
    expect(described_class.new.queue_name).to eq("seo")
  end

  describe ".enqueue_for" do
    it "queues a job for a description with links" do
      ticket = create(:ticket, project:, organization:, description: "See https://docs.test/a")

      expect { described_class.enqueue_for(ticket) }.to have_enqueued_job(described_class).with(ticket_id: ticket.id)
    end

    it "queues nothing for a description without links" do
      ticket = create(:ticket, project:, organization:, description: "No links here")

      expect { described_class.enqueue_for(ticket) }.not_to have_enqueued_job(described_class)
    end

    it "queues nothing when every link already has a fresh preview" do
      ticket = create(:ticket, project:, organization:, description: "See https://docs.test/a")
      create(:link_preview, organization:, url: "https://docs.test/a")

      expect { described_class.enqueue_for(ticket) }.not_to have_enqueued_job(described_class)
    end

    it "queues a job when a preview has expired" do
      ticket = create(:ticket, project:, organization:, description: "See https://docs.test/a")
      create(:link_preview, organization:, url: "https://docs.test/a", expires_at: 1.minute.ago)

      expect { described_class.enqueue_for(ticket) }.to have_enqueued_job(described_class).with(ticket_id: ticket.id)
    end

    it "does not count the fresh preview of another organization" do
      ticket = create(:ticket, project:, organization:, description: "See https://docs.test/a")
      create(:link_preview, organization: create(:organization), url: "https://docs.test/a")

      expect { described_class.enqueue_for(ticket) }.to have_enqueued_job(described_class).with(ticket_id: ticket.id)
    end
  end

  describe "live update of the open ticket page" do
    let(:ticket) { create(:ticket, project:, organization:, description: "See https://docs.test/a") }
    let(:stream) { Realtime::Streams.ticket(ticket) }

    before { ActionCable.server.pubsub.clear }

    def payload = ActionCable.server.pubsub.broadcasts(stream).map { |message| JSON.parse(message) }.join

    it "replaces the cards of the page once a preview has been read" do
      allow(Ticketing::LinkPreviews::Refresh).to receive(:call) do |organization:, url:|
        Ticketing::LinkPreview.create!(organization:, url:, status: :ready, title: "Docs page", site_name: "Docs",
                                       expires_at: 1.day.from_now)
      end

      described_class.perform_now(ticket_id: ticket.id)

      expect(payload).to include(%(action="replace"))
      expect(payload).to include(%(target="#{ActionView::RecordIdentifier.dom_id(ticket, :link_previews)}"))
      expect(payload).to include("Docs page")
      expect(payload).to include(%(href="https://docs.test/a"))
    end

    it "sends nothing when no preview was read again" do
      fresh = create(:link_preview, organization:, url: "https://docs.test/a")
      allow(Ticketing::LinkPreviews::Refresh).to receive(:call).and_return(Ticketing::LinkPreview.find(fresh.id))

      described_class.perform_now(ticket_id: ticket.id)

      expect(ActionCable.server.pubsub.broadcasts(stream)).to be_empty
    end
  end

  it "reads the description as it is when the job runs, not when it was queued" do
    ticket = create(:ticket, project:, organization:, description: "Old https://old.test/page")
    ticket.update_columns(description: "New https://new.test/page")
    allow(Ticketing::LinkPreviews::Refresh).to receive(:call)

    described_class.perform_now(ticket_id: ticket.id)

    expect(Ticketing::LinkPreviews::Refresh).to have_received(:call).with(organization:, url: "https://new.test/page")
    expect(Ticketing::LinkPreviews::Refresh).not_to have_received(:call).with(organization:, url: "https://old.test/page")
  end

  it "does nothing for a ticket that no longer exists" do
    allow(Ticketing::LinkPreviews::Refresh).to receive(:call)

    described_class.perform_now(ticket_id: SecureRandom.uuid)

    expect(Ticketing::LinkPreviews::Refresh).not_to have_received(:call)
  end
end
