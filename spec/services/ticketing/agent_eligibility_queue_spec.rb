# frozen_string_literal: true

require "rails_helper"

# CYRA-548 — la porta unica da cui si accoda il vaglio. Dal CYRA-765 non c'è più nessun servizio da
# collegare (l'AI la offre il sistema): qui resta la sola forma dell'accodamento, e il freno vive
# dentro il service, non davanti alla coda.
RSpec.describe Ticketing::AgentEligibilityQueue do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:) }

  describe ".enqueue" do
    it "accoda il vaglio col debounce e dice di averlo fatto" do
      expect do
        expect(described_class.enqueue(ticket:)).to be(true)
      end.to have_enqueued_job(Ticketing::EvaluateAgentEligibilityJob).with(ticket_id: ticket.id)
    end

    it "con wait: nil accoda subito, senza attesa" do
      expect do
        described_class.enqueue(ticket:, wait: nil)
      end.to have_enqueued_job(Ticketing::EvaluateAgentEligibilityJob).at(:no_wait)
    end

    # Prima del CYRA-765 un ticket con immagini pretendeva un servizio in più: ora il motore è uno e
    # gli allegati non cambiano niente sull'accodamento.
    it "accoda anche un ticket con uno screenshot" do
      ticket.files.attach(io: Rails.root.join("spec/fixtures/files/screenshot.png").open,
                          filename: "console.png", content_type: "image/png")

      expect do
        expect(described_class.enqueue(ticket: ticket.reload)).to be(true)
      end.to have_enqueued_job(Ticketing::EvaluateAgentEligibilityJob).with(ticket_id: ticket.id)
    end
  end
end
