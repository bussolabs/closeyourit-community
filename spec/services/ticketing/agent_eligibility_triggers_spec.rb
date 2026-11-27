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

  describe "atomic withdrawal of automatic approvals" do
    let(:ticket) { create(:ticket, organization:, project:, title: "Sort the list", description: "Original order") }

    def approve
      ticket.reload.update!(agent_eligibility: :allowed, agent_eligibility_source: :automatic,
                            agent_eligibility_advice: :allowed,
                            agent_eligibility_checksum: Ticketing::AgentEligibilityText.checksum(ticket:))
    end

    def edit_body
      Ticketing::UpdateTicket.call(organization:, ticket:, actor:, channel: :web,
                                   params: { title: ticket.title, description: "Reverse order",
                                             status_id: ticket.status_id, priority_id: ticket.priority_id })
    end

    it "withdraws before a changed body can be claimed, even with the switch off" do
      approve

      expect(edit_body).to be_ok

      expect(ticket.reload).to be_agent_eligibility_pending
      expect(ticket).not_to be_agent_workable
      expect(ticket.events.where(action: "agent_eligibility_overridden").last.data).to include("go_ahead" => "withdrawn")
    end

    it "withdraws when adding an attachment" do
      approve

      Ticketing::AttachToTicket.call(ticket:, files: [ upload ], actor:)

      expect(ticket.reload).to be_agent_eligibility_pending
    end

    it "withdraws when removing an attachment" do
      Ticketing::AttachToTicket.call(ticket:, files: [ upload ], actor:)
      approve

      Ticketing::RemoveAttachment.call(ticket:, attachment_id: ticket.files.first.id, actor:)

      expect(ticket.reload).to be_agent_eligibility_pending
      expect(ticket.files).not_to be_attached
    end

    it "rolls back both detachment and withdrawal when the history cannot be saved" do
      Ticketing::AttachToTicket.call(ticket:, files: [ upload ], actor:)
      approve
      attachment_id = ticket.files.first.id
      allow(Ticketing::RecordActivity).to receive(:call).and_call_original
      allow(Ticketing::RecordActivity).to receive(:call).with(hash_including(action: "attachment_removed"))
        .and_raise("history failed")

      expect { Ticketing::RemoveAttachment.call(ticket:, attachment_id:, actor:) }.to raise_error("history failed")

      expect(ticket.reload).to be_agent_eligibility_allowed
      expect(ticket.files.find(attachment_id)).to be_present
      expect(ticket.events.where(action: "agent_eligibility_overridden")).to be_empty
    end

    it "withdraws and enqueues when a person comments" do
      approve

      expect do
        Ticketing::AddComment.call(ticket:, author: actor, params: { body: "Also reverse the date order" })
      end.to change { evaluations_for(ticket) }.by(1)

      expect(ticket.reload).to be_agent_eligibility_pending
    end

    it "withdraws and enqueues when a person's comment is deleted" do
      comment = Ticketing::AddComment.call(ticket:, author: actor, params: { body: "Only the local list" }).value
      approve

      expect { Ticketing::DeleteComment.call(comment:, actor:) }.to change { evaluations_for(ticket) }.by(1)

      expect(ticket.reload).to be_agent_eligibility_pending
    end

    it "rolls back a new comment when withdrawal history cannot be saved" do
      approve
      allow(Ticketing::RecordActivity).to receive(:call).and_call_original
      allow(Ticketing::RecordActivity).to receive(:call).with(hash_including(action: "agent_eligibility_overridden"))
        .and_raise("history failed")

      expect do
        Ticketing::AddComment.call(ticket:, author: actor, params: { body: "Reverse the order" })
      end.to raise_error("history failed")

      expect(ticket.reload).to be_agent_eligibility_allowed
      expect(ticket.comments).to be_empty
      expect(ticket.events.where(action: "agent_eligibility_overridden")).to be_empty
    end

    it "rolls back comment deletion and withdrawal when deletion history cannot be saved" do
      comment = Ticketing::AddComment.call(ticket:, author: actor, params: { body: "Only the local list" }).value
      approve
      allow(Ticketing::RecordActivity).to receive(:call).and_call_original
      allow(Ticketing::RecordActivity).to receive(:call).with(hash_including(action: "comment_deleted"))
        .and_raise("history failed")

      expect { Ticketing::DeleteComment.call(comment:, actor:) }.to raise_error("history failed")

      expect(ticket.reload).to be_agent_eligibility_allowed
      expect(ticket.comments.find(comment.id).body).to eq("Only the local list")
      expect(ticket.events.where(action: "agent_eligibility_overridden")).to be_empty
    end

    it "does not schedule physical deletion when detachment is rolled back" do
      Ticketing::AttachToTicket.call(ticket:, files: [ upload ], actor:)
      approve
      attachment = ticket.files.first
      blob = attachment.blob
      allow(Ticketing::RecordActivity).to receive(:call).and_call_original
      allow(Ticketing::RecordActivity).to receive(:call).with(hash_including(action: "attachment_removed"))
        .and_raise("history failed")
      clear_enqueued_jobs

      expect do
        Ticketing::RemoveAttachment.call(ticket:, attachment_id: attachment.id, actor:)
      end.to raise_error("history failed")

      expect(enqueued_jobs).to be_empty
      expect(blob.reload).to be_present
      expect(ticket.reload.files.find(attachment.id)).to be_present
    end

    %w[allowed blocked].each do |decision|
      it "preserves a manual #{decision} decision despite a stale caller" do
        stale = Ticketing::Ticket.find(ticket.id)
        Ticketing::SetAgentEligibility.call(ticket:, source: :human, eligibility: decision, actor:)

        Ticketing::SetAgentEligibility.call(ticket: stale, source: :invalidate)

        expect(ticket.reload).to have_attributes(agent_eligibility: decision, agent_eligibility_source: "human")
      end
    end
  end

  describe "alla creazione" do
    it "records the external origin before queueing evaluation" do
      allow(Ticketing::AgentEligibilityQueue).to receive(:enqueue) do |ticket:|
        expect(ticket.reload).to have_attributes(origin: "helpdesk", created_by: actor)
      end

      result = Ticketing::CreateTicket.call(
        organization:, reporter: actor, origin: :helpdesk,
        params: { project_id: project.id, title: "Sort the list", description: "Sort names", kind: "bug",
                  status_id: create(:ticket_status, organization:).id,
                  priority_id: create(:ticket_priority, organization:).id }
      )

      expect(result).to be_ok
      expect(Ticketing::AgentEligibilityQueue).to have_received(:enqueue).with(ticket: result.value)
    end

    it "accoda sempre la valutazione" do
      result = nil

      expect do
        result = Ticketing::CreateTicket.call(
          organization:, reporter: actor, origin: :form,
          params: { project_id: project.id, title: "Bottone rotto", description: "Non risponde", kind: "bug",
                    status_id: create(:ticket_status, organization:).id,
                    priority_id: create(:ticket_priority, organization:).id }
        )
      end.to change { enqueued_jobs.count { |j| j["job_class"] == "Ticketing::EvaluateAgentEligibilityJob" } }.by(1)

      expect(result).to be_ok
      expect(result.value).to be_agent_eligibility_pending
      expect(result.value.events.find_by!(action: "created")).to have_attributes(actor: actor)
      expect(result.value.events.find_by!(action: "created").data).to include("origin" => "form")
      expect(result.value).to have_attributes(origin: "form", created_by: actor)
    end

    # AC-14 — the creator is who typed it, never the reporter they named.
    it "keeps the customer that typed it, not the team member it names as reporter" do
      customer = create(:account).tap { |account| create(:membership, account:, organization:, role: :customer) }
      create(:project_membership, project:, account: customer)

      result = Ticketing::CreateTicket.call(
        organization:, reporter: customer, true_actor: customer, origin: :form,
        params: { project_id: project.id, title: "Sort the list", description: "Sort names", kind: "bug",
                  reporter_id: actor.id, status_id: create(:ticket_status, organization:).id,
                  priority_id: create(:ticket_priority, organization:).id }
      )

      expect(result.value).to have_attributes(reporter: actor, created_by: customer)
      expect(result.value).not_to be_team_authored
    end

    it "refuses a channel name nobody declared" do
      result = Ticketing::CreateTicket.call(
        organization:, reporter: actor, origin: :somewhere,
        params: { project_id: project.id, title: "Sort the list", description: "Sort names", kind: "bug",
                  status_id: create(:ticket_status, organization:).id,
                  priority_id: create(:ticket_priority, organization:).id }
      )

      expect(result).to be_err
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

  # CYRA-1343 — a person's comment can carry what kept the ticket from the agents. An allowed ticket
  # is left alone, so a lively thread does not pay one evaluation per comment.
  describe "on comments" do
    let(:ticket) { create(:ticket, organization:, project:, description: "corpo") }

    it "enqueues when a person comments a ticket that is not allowed" do
      expect do
        Ticketing::AddComment.call(ticket:, author: actor, params: { body: "un commento" })
      end.to change { evaluations_for(ticket) }.by(1)
    end

    it "does not enqueue on a manually allowed ticket" do
      ticket.update!(agent_eligibility: :allowed, agent_eligibility_source: :human)

      expect do
        Ticketing::AddComment.call(ticket:, author: actor, params: { body: "un commento" })
      end.not_to change { evaluations_for(ticket) }
    end
  end
end
