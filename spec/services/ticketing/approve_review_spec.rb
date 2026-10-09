# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::ApproveReview do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:in_review) { create(:ticket_status, :in_review, organization: org, position: 2) }
  let!(:resolved) { create(:ticket_status, :done, organization: org, position: 3) }
  let(:ticket) { create(:ticket, organization: org, project: project, status: in_review, with_agent_workflow: true) }
  let(:actor) { ticket.reporter }

  def approve(**overrides)
    described_class.call(**{ organization: org, ticket: ticket, actor: actor }.merge(overrides))
  end

  it "porta il ticket sul primo status done (Result.ok)" do
    result = approve
    expect(result).to be_ok
    expect(ticket.reload.status).to eq(resolved)
  end

  it "sceglie il target per position tra più candidati done, ignorando gli inattivi" do
    create(:ticket_status, :done, organization: org, position: 1, active: false, label: "Archived")
    closed = create(:ticket_status, :done, organization: org, position: 2, label: "Closed")
    approve
    expect(ticket.reload.status).to eq(closed)
  end

  it "registra un evento review_approved con label prima→dopo (senza reason)" do
    expect { approve }.to change(Ticketing::Event, :count).by(1)

    event = Ticketing::Event.last
    expect(event.action).to eq("review_approved")
    expect(event.actor).to eq(actor)
    expect(event.data).to eq("status" => { "from" => in_review.label, "to" => resolved.label })
  end

  it "registra true_actor in impersonation" do
    god = create(:account)
    approve(true_actor: god)
    expect(Ticketing::Event.last.true_actor).to eq(god)
  end

  it "NON crea commenti e accoda NotifyJob" do
    expect { approve }.to not_change(Ticketing::Comment, :count)
      .and have_enqueued_job(Ticketing::NotifyJob)
  end

  describe "guard" do
    it "ticket non in review → err R422-TICKET-006, nessuna mutazione" do
      working = create(:ticket_status, :in_progress, organization: org)
      ticket.update!(status: working)
      expect { @result = approve }.not_to change(Ticketing::Event, :count)
      expect(@result).to be_err
      expect(@result.error.code).to eq("R422-TICKET-006")
      expect(ticket.reload.status).to eq(working)
    end

    it "nessun candidato done attivo → err R422-TICKET-008" do
      resolved.update!(active: false)
      result = approve
      expect(result).to be_err
      expect(result.error.code).to eq("R422-TICKET-008")
      expect(ticket.reload.status).to eq(in_review)
    end
  end

  it "rollback atomico: se l'evento fallisce, status invariato" do
    allow(Ticketing::RecordActivity).to receive(:call).and_raise(ActiveRecord::RecordInvalid)
    expect { approve }.to raise_error(ActiveRecord::RecordInvalid)
    expect(ticket.reload.status).to eq(in_review)
  end

  # Host-first (CYAU-100): la pipeline closer è "configurata" quando esiste una macchina che
  # Agents::Hosts::Eligibility.capable? considera in grado di servirla — non revocata, certificata,
  # col progetto nella ProjectScope del suo service account, nella host-map (`repositories`) e col
  # runtime della fase presente; più un repo GitHub sul progetto. Senza, ApproveReview NON avanza ai
  # closer (restano opt-in) — vedi il describe "senza pipeline closer".
  def configure_closer_pipeline(visible_project: project, **host_attributes)
    create(:github_repository, project:) unless project.github_repository
    service_account = create(:account, :service).tap do |account|
      create(:project_membership, account:, project: visible_project)
    end
    create(:agent_host, organization: org, service_account:,
                        **{ repositories: [ project.key ],
                            runtimes: [ { "name" => "claude", "present" => true } ] }.merge(host_attributes))
  end

  describe "gate post-autopilot (B.4)" do
    let!(:in_progress) { create(:ticket_status, :in_progress, organization: org, position: 1) }

    before do
      ticket.agent_workflow.update!(autopilot_completed_at: Time.current, candidate_verified_at: Time.current)
      configure_closer_pipeline
    end

    it "avanza ai closer invece di chiudere: ticket in in_progress non-gate, autopilot_approved_at timbrato" do
      result = approve

      expect(result).to be_ok
      expect(result.value).to eq(ticket)
      expect(ticket.reload.status).to eq(in_progress)
      expect(ticket.agent_workflow.reload).to have_attributes(
        autopilot_approved_at: be_present, autopilot_approved_by: actor, phase: "closer_staging_queued"
      )
    end

    # CYRA-622 — lo spostamento passa dalla porta unica dei cambi stato, quindi lascia una riga in
    # timeline: prima il ticket saltava colonna senza traccia. Quello che NON deve comparire è
    # `review_approved`, che vorrebbe dire «chiuso»: qui il lavoro sta andando al rilascio.
    it "non chiude a done né registra un evento review_approved" do
      expect { approve }.to change { Ticketing::Event.where(action: "status_changed").count }.by(1)
      expect(Ticketing::Event.where(action: "review_approved")).to be_empty
      expect(ticket.reload.status).not_to eq(resolved)
    end

    it "avanza ai closer anche senza uno status done attivo (il gate post-autopilot non richiede category_done)" do
      resolved.update!(active: false)

      result = approve

      expect(result).to be_ok
      expect(ticket.reload.status).to eq(in_progress)
      expect(ticket.agent_workflow.reload.autopilot_approved_at).to be_present
    end

    it "senza un in_progress non-gate di destinazione fallisce e non muta lo stato" do
      in_progress.update!(review_gate: true)

      result = approve

      expect(result.error.code).to eq("R422-TICKET-008")
      expect(ticket.reload.status).to eq(in_review)
      expect(ticket.agent_workflow.reload.autopilot_approved_at).to be_nil
    end

    it "broadcasta il cambio stato sul board (post-commit) come il path di approvazione normale" do
      seen = []
      expect { approve }
        .to have_broadcasted_to(Realtime::Streams.project_board(ticket.project))
        .exactly(:once).with { |html| seen << html }

      expect(seen.first).to include(%(action="refresh"))
    end

    it "guard fallito nel ramo autopilot → nessun broadcast" do
      in_progress.update!(review_gate: true)

      expect { approve }.not_to have_broadcasted_to(Realtime::Streams.project_board(ticket.project))
    end
  end

  describe "gate post-autopilot (B.4) senza pipeline closer configurata" do
    before { ticket.agent_workflow.update!(autopilot_completed_at: Time.current, candidate_verified_at: Time.current) }

    it "chiude a done, completa il workflow e registra review_approved (i closer restano opt-in)" do
      expect { @result = approve }.to change(Ticketing::Event, :count).by(1)

      expect(@result).to be_ok
      expect(ticket.reload.status).to eq(resolved)
      expect(ticket.agent_workflow.reload).to have_attributes(
        phase: "completed", autopilot_approved_by: actor, completed_at: be_present
      )
      expect(Ticketing::Event.last.action).to eq("review_approved")
    end

    it "avanza ai closer appena la pipeline closer viene configurata" do
      in_progress = create(:ticket_status, :in_progress, organization: org, position: 1)
      configure_closer_pipeline

      expect(approve).to be_ok
      expect(ticket.reload.status).to eq(in_progress)
      expect(ticket.agent_workflow.reload.phase).to eq("closer_staging_queued")
    end

    it "NON avanza se l'host non è certificato (nessun via libera umano) → chiude a done" do
      create(:ticket_status, :in_progress, organization: org, position: 1)
      configure_closer_pipeline(certified_at: nil)

      expect(approve).to be_ok
      expect(ticket.reload.status).to eq(resolved)
      expect(ticket.agent_workflow.reload.phase).to eq("completed")
    end

    it "NON avanza se l'unico host è revocato → chiude a done" do
      create(:ticket_status, :in_progress, organization: org, position: 1)
      configure_closer_pipeline(revoked_at: Time.current)

      expect(approve).to be_ok
      expect(ticket.reload.status).to eq(resolved)
      expect(ticket.agent_workflow.reload.phase).to eq("completed")
    end

    it "NON avanza se il service account dell'host non vede il progetto del ticket → chiude a done" do
      create(:ticket_status, :in_progress, organization: org, position: 1)
      configure_closer_pipeline(visible_project: create(:project, organization: org))

      expect(approve).to be_ok
      expect(ticket.reload.status).to eq(resolved)
    end

    # Rilievo della review Codex: scope e certificazione non bastano. Un host che non ha il progetto
    # nella host-map, o senza il runtime della fase, non potrebbe MAI reclamare — accodare i closer
    # lascerebbe il ticket appeso.
    it "NON avanza se il progetto non è nella host-map dell'host → chiude a done" do
      create(:ticket_status, :in_progress, organization: org, position: 1)
      configure_closer_pipeline(repositories: [])

      expect(approve).to be_ok
      expect(ticket.reload.status).to eq(resolved)
      expect(ticket.agent_workflow.reload.phase).to eq("completed")
    end

    it "NON avanza se il runtime della fase non è presente sull'host → chiude a done" do
      create(:ticket_status, :in_progress, organization: org, position: 1)
      configure_closer_pipeline(runtimes: [ { "name" => "claude", "present" => false } ])

      expect(approve).to be_ok
      expect(ticket.reload.status).to eq(resolved)
      expect(ticket.agent_workflow.reload.phase).to eq("completed")
    end

    it "NON avanza se il progetto non ha un repository GitHub → chiude a done" do
      create(:ticket_status, :in_progress, organization: org, position: 1)
      configure_closer_pipeline
      project.github_repository.destroy!

      expect(approve).to be_ok
      expect(ticket.reload.status).to eq(resolved)
    end

    it "avanza anche con l'host offline: l'heartbeat è liveness, non capacità" do
      in_progress = create(:ticket_status, :in_progress, organization: org, position: 1)
      configure_closer_pipeline(last_heartbeat_at: 1.day.ago)

      expect(approve).to be_ok
      expect(ticket.reload.status).to eq(in_progress)
      expect(ticket.agent_workflow.reload.phase).to eq("closer_staging_queued")
    end
  end

  # CYRA-1066 — after the human approved the delivered work, the closers own the ticket until
  # production is up: approving it again as a plain review would mark it resolved before the release.
  describe "closing run still open" do
    before do
      ticket.agent_workflow.update!(triage_started_at: 5.hours.ago, autopilot_completed_at: 2.hours.ago,
                                    candidate_verified_at: 2.hours.ago, autopilot_approved_at: 1.hour.ago,
                                    closer_staging_started_at: 30.minutes.ago)
    end

    it "refuses with R409-TICKET-022 and leaves the ticket in review" do
      result = nil
      expect { result = approve }.to not_change { ticket.reload.status_id }.and not_change(Ticketing::Event, :count)

      expect(result).to be_err
      expect(result.error.code).to eq("R409-TICKET-022")
    end

    it "resolves again once the closing run has completed" do
      ticket.agent_workflow.update!(completed_at: Time.current)

      expect(approve).to be_ok
      expect(ticket.reload.status).to eq(resolved)
    end
  end

  it "un ticket review-gate il cui workflow NON è post-autopilot va a resolved come prima" do
    expect(ticket.agent_workflow.phase).to eq("triage_queued")

    expect(approve).to be_ok
    expect(ticket.reload.status).to eq(resolved)
  end

  describe "gate dipendenze (CYRA-81)" do
    let(:open_status) { create(:ticket_status, organization: org) }
    # A (ticket, in review) dipende da B (blocker) ancora aperto → A è bloccato.
    let(:blocker) { create(:ticket, organization: org, project: project, status: open_status) }

    before { create(:ticket_dependency, ticket: ticket, blocker: blocker) }

    it "scenario 5 — approve con blocker riaperto: err R422-TICKET-014, A resta in review, nessuna mutazione" do
      result = nil
      expect { result = approve }
        .to not_change { ticket.reload.status_id }.and not_change(Ticketing::Event, :count)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-TICKET-014")
      expect(ticket.reload.status).to eq(in_review)
    end

    it "blocco → nessun broadcast sul board" do
      expect { approve }.not_to have_broadcasted_to(Realtime::Streams.project_board(ticket.project))
    end

    it "prerequisito done → l'approvazione riesce (A va a resolved)" do
      blocker.update!(status: resolved)

      result = approve

      expect(result).to be_ok
      expect(ticket.reload.status).to eq(resolved)
    end
  end

  describe "gate dipendenze nel ramo closer post-autopilot (target in_progress, anch'esso gated)" do
    let(:open_status) { create(:ticket_status, organization: org) }
    let(:blocker) { create(:ticket, organization: org, project: project, status: open_status) }
    let!(:in_progress) { create(:ticket_status, :in_progress, organization: org, position: 1) }

    before do
      ticket.agent_workflow.update!(autopilot_completed_at: Time.current, candidate_verified_at: Time.current)
      configure_closer_pipeline
      create(:ticket_dependency, ticket: ticket, blocker: blocker)
    end

    it "blocker aperto → err R422-TICKET-014, A resta in review, workflow non timbrato, nessun broadcast" do
      result = nil
      expect { result = approve }.not_to have_broadcasted_to(Realtime::Streams.project_board(ticket.project))

      expect(result).to be_err
      expect(result.error.code).to eq("R422-TICKET-014")
      expect(ticket.reload.status).to eq(in_review)
      expect(ticket.agent_workflow.reload.autopilot_approved_at).to be_nil
    end

    it "prerequisito done → l'avanzamento ai closer riesce (in_progress non-gate)" do
      blocker.update!(status: resolved)

      result = approve

      expect(result).to be_ok
      expect(ticket.reload.status).to eq(in_progress)
      expect(ticket.agent_workflow.reload.autopilot_approved_at).to be_present
    end
  end

  describe "broadcast realtime (post-commit)" do
    let(:board_stream) { Realtime::Streams.project_board(ticket.project) }
    let(:card_id) { "ticketing_ticket_#{ticket.id}" }

    it "manda un refresh sulla board del progetto, senza HTML della card (CYRA-257)" do
      seen = []
      expect { approve }.to have_broadcasted_to(board_stream).exactly(:once).with { |html| seen << html }

      expect(seen.first).to include(%(action="refresh"))
      expect(seen.first).not_to include(card_id, ticket.title)
    end

    it "guard fallito → nessun broadcast" do
      resolved.update!(active: false)
      expect { approve }.not_to have_broadcasted_to(board_stream)
    end
  end
  # ── CYRA-611 ──────────────────────────────────────────────────────────────────────────────────
  #
  # Il sistema ha due fermate umane: il piano e il lavoro finito. La prima era già chiusa nel modo
  # giusto; la seconda controllava una cosa sola — che chi chiama avesse `tickets.edit`. Quel permesso
  # ce l'ha anche il service account dell'host, che lo usa per portare il ticket in revisione quando
  # consegna: la macchina poteva quindi firmare da sola il proprio via libera, e da lì il codice andava
  # unito, taggato e rilasciato senza che nessuna persona avesse guardato niente.
  describe "la firma la mette una persona" do
    let(:in_review) { create(:ticket_status, :in_review, organization: org) }
    let(:done) { create(:ticket_status, :done, organization: org) }
    let(:persona) { create(:account).tap { |a| create(:membership, account: a, organization: org) } }
    let(:macchina) do
      create(:account, :service).tap { |a| create(:membership, account: a, organization: org) }
    end

    before do
      done
      ticket.update!(status: in_review)
    end

    it "una persona approva, come sempre" do
      expect(described_class.call(organization: org, ticket:, actor: persona)).to be_ok
      expect(ticket.reload.status).to eq(done)
    end

    it "l'identità di una macchina non firma, e il ticket non si muove" do
      result = described_class.call(organization: org, ticket:, actor: macchina)

      expect(result.error.code).to eq("R403-TICKET-021")
      expect(result.error.status).to eq(:forbidden)
      expect(ticket.reload.status).to eq(in_review)
    end

    # Il messaggio nomina l'identità che sta chiamando: senza, chi si è collegato alla macchina e sta
    # usando la sua identità vede un rifiuto e non capisce cosa deve rifare.
    it "il rifiuto dice quale identità sta firmando" do
      result = described_class.call(organization: org, ticket:, actor: macchina)

      expect(result.error.message).to include(macchina.handle)
    end

    # Non sapere chi firma non è meglio che saperlo: attore assente = rifiuto, mai un `&.service?` che
    # su `nil` risponde «non è di servizio» e lascia passare.
    it "senza attore non si firma" do
      result = described_class.call(organization: org, ticket:, actor: nil)

      expect(result.error.code).to eq("R403-TICKET-021")
      expect(ticket.reload.status).to eq(in_review)
    end

    # Il discriminante è CHI CHIAMA, non a che punto è il lavoro: approvare a lavorazione aperta È
    # esattamente il gesto di questa fermata, e rifiutarlo bloccherebbe l'operatore.
    it "una persona approva anche mentre la lavorazione è aperta" do
      ticket.agent_workflow.update!(triage_started_at: Time.current)

      expect(described_class.call(organization: org, ticket:, actor: persona)).to be_ok
    end
  end
end
