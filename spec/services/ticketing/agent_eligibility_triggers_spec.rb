# frozen_string_literal: true

require "rails_helper"

# Punti di innesco della rivalutazione del gate agenti (CYRA-184). Vivono in quattro service diversi
# ma rispondono a una sola domanda: "è cambiato qualcosa che il modello dovrebbe rileggere?".
RSpec.describe "Innesco della valutazione di eleggibilità agenti" do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:actor) do
    create(:account).tap { |account| create(:membership, account:, organization:, role: :owner) }
  end

  def upload(name = "screenshot.png", type = "image/png")
    Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/#{name}"), type)
  end

  def evaluations_for(ticket)
    enqueued_jobs.count do |job|
      job["job_class"] == "Ticketing::EvaluateAgentEligibilityJob" &&
        job.dig("arguments", 0, "ticket_id") == ticket.id
    end
  end

  describe "alla creazione" do
    it "accoda sempre la valutazione" do
      result = nil

      expect do
        result = Ticketing::CreateTicket.call(
          organization:, reporter: actor,
          params: { project_id: project.id, title: "Bottone rotto", description: "Non risponde", kind: "bug",
                    status_id: create(:ticket_status, organization:).id,
                    priority_id: create(:ticket_priority, organization:).id }
        )
      end.to change { enqueued_jobs.count { |j| j["job_class"] == "Ticketing::EvaluateAgentEligibilityJob" } }.by(1)

      expect(result).to be_ok
      expect(result.value).to be_agent_eligibility_pending
    end
  end

  describe "alla modifica" do
    let(:ticket) { create(:ticket, organization:, project:, description: "corpo iniziale") }

    # UpdateTicket riassegna l'intero record: i params vanno passati completi, non a delta.
    def update(**overrides)
      Ticketing::UpdateTicket.call(channel: :web,
        organization:, ticket:, actor:,
        params: { title: ticket.title, description: ticket.description,
                  status_id: ticket.status_id, priority_id: ticket.priority_id }.merge(overrides)
      )
    end

    it "accoda quando cambia il corpo" do
      expect { update(description: "corpo diverso") }.to change { evaluations_for(ticket) }.by(1)
    end

    it "accoda quando cambia una condizione di completamento" do
      expect do
        update(conditions_attributes: [ { text: "Svuota la produzione" } ])
      end.to change { evaluations_for(ticket) }.by(1)
    end

    it "NON accoda quando il contenuto valutato non è cambiato" do
      ticket.update!(agent_eligibility_checksum: Ticketing::AgentEligibilityText.checksum(ticket:))

      expect { update(weight: 5, due_at: 3.days.from_now) }.not_to change { evaluations_for(ticket) }
    end

    it "NON accoda su un ticket con decisione umana" do
      ticket.update!(agent_eligibility: :allowed, agent_eligibility_source: :human)

      expect { update(description: "tutto nuovo") }.not_to change { evaluations_for(ticket) }
    end
  end

  describe "sugli allegati" do
    let(:ticket) { create(:ticket, organization:, project:, description: "corpo") }

    before { ticket.update!(agent_eligibility_checksum: Ticketing::AgentEligibilityText.checksum(ticket:)) }

    # Il caso che rende necessario il canale multimodale: testo invariato, rischio solo nell'immagine.
    it "accoda quando si allega un file" do
      expect do
        Ticketing::AttachToTicket.call(ticket:, files: [ upload ], actor:)
      end.to change { evaluations_for(ticket) }.by(1)
    end

    it "accoda quando si rimuove un allegato" do
      Ticketing::AttachToTicket.call(ticket:, files: [ upload ], actor:)
      ticket.reload.update!(agent_eligibility_checksum: Ticketing::AgentEligibilityText.checksum(ticket:))

      expect do
        Ticketing::RemoveAttachment.call(ticket:, attachment_id: ticket.files.first.id, actor:)
      end.to change { evaluations_for(ticket) }.by(1)
    end

    it "NON accoda sugli allegati di un ticket con decisione umana" do
      ticket.update!(agent_eligibility: :blocked, agent_eligibility_source: :human)

      expect do
        Ticketing::AttachToTicket.call(ticket:, files: [ upload ], actor:)
      end.not_to change { evaluations_for(ticket) }
    end
  end

  # I commenti sono esclusi di proposito: non fanno parte del corpo valutato (come per l'embedding) e
  # includerli produrrebbe una raffica di valutazioni su ogni thread vivace.
  describe "sui commenti" do
    let(:ticket) { create(:ticket, organization:, project:, description: "corpo") }

    it "NON accoda quando si aggiunge un commento" do
      expect do
        Ticketing::AddComment.call(ticket:, author: actor, params: { body: "un commento" })
      end.not_to change { evaluations_for(ticket) }
    end
  end
end
