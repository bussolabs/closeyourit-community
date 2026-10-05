# frozen_string_literal: true

require "rails_helper"

# CYRA-597 — il cancello dei prerequisiti esiste da tempo e funziona: un ticket con un prerequisito
# aperto non entra in lavorazione e non si chiude. Ma lo interrogano solo le tre strade che passano
# da una persona. La consegna della macchina scriveva lo stato per conto suo, e quella era l'unica
# porta che restava aperta — proprio dal lato dove nessuno guarda.
#
# Cosa NON deve fare il cancello, ed è la parte delicata: la consegna resta valida e registrata. Il
# lavoro è stato fatto davvero, e buttarlo obbligherebbe a rifarlo. Si ferma solo lo stato del
# ticket. E i marcatori di fine fase si scrivono lo stesso, o il sistema riapre la fase e produce una
# seconda proposta di modifica (o un secondo rilascio) sullo stesso lavoro.
RSpec.describe Agents::Attempts::Deliver, "il cancello dei prerequisiti" do
  def build_delivery_scope(phase:, organization:, project:, ticket:, workflow:)
    Agents::Lease.where(ticket:).delete_all
    profile = Agents::PhaseProfile.for(phase)
    host_sa = Accounts::Service::Create.call(organization:, name: "Host SA #{phase}",
                                             project_ids: [ project.id ]).value
    host = create(:agent_host, organization:, service_account: host_sa, last_heartbeat_at: Time.current,
                               repositories: [ project.key ],
                               runtimes: [ { "name" => profile.runtime, "present" => true } ])
    attempt = create(:agent_attempt, organization:, workflow:, host:, service_account: host_sa,
                                     skill_key: profile.skill_key, external_run_id: "run-dep-#{phase}",
                                     phase:, runtime: profile.runtime)
    create(:agent_lease, organization:, ticket:, host:, run_id: "run-dep-#{phase}",
                         execution_phase: phase, profile_digest: profile.digest,
                         expires_at: 5.minutes.from_now)
    { host:, attempt: }
  end

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:repository) { create(:github_repository, project:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:prerequisito) { create(:ticket, organization:, project:) }

  def dipendenza!
    Connections::TicketDependency.create!(ticket:, blocker: prerequisito,
                                          created_by: create(:account))
  end

  describe "quando la macchina consegna il lavoro" do
    let(:review_status) do
      organization.ticket_statuses.review_gates.active.ordered.first ||
        create(:ticket_status, :in_review, organization:)
    end

    let(:payload) do
      { runtime: "claude", reviewer_runtime: "codex",
        result: { code: ticket.code, state: "delivered", security_findings: [], gate: { passed: true },
                  review: { verdict: "approved" }, cycles: 1,
                  delivery: { prUrl: "https://github.com/bussolabs/closeyourit-rails/pull/1", cyiStatus: "in_review", autoMerged: false } },
        review: review_for("autopilot"), observed: observed_head }
    end

    before do
      review_status
      workflow.update!(triage_started_at: nil, triaged_at: Time.current, planned_at: Time.current,
                       approved_at: Time.current, autopilot_started_at: Time.current,
                       ticket_snapshot_digest: "snapshot")
      congela_piano!(workflow)
    end

    def consegna
      scope = build_delivery_scope(phase: "autopilot", organization:, project:, ticket:, workflow:)
      described_class.call(organization:, host: scope[:host], attempt: scope[:attempt], payload:)
    end

    # CYRA-612 — la consegna non sposta più il ticket, quindi il cancello dei prerequisiti non ha più
    # niente da guardare QUI: la porta che CYRA-597 aveva chiuso adesso non esiste proprio. Il cancello
    # resta dov'è sempre stato, sulle tre strade da cui una persona fa avanzare il lavoro.
    it "il ticket non si muove, né con prerequisiti aperti né senza" do
      partenza = ticket.status

      expect(consegna).to be_ok
      expect(ticket.reload.status).to eq(partenza)

      dipendenza!
      expect(consegna).to be_ok
      expect(ticket.reload.status).to eq(partenza)
    end

    # La consegna resta valida: il lavoro è stato fatto, e il tentativo è la sua prova.
    it "la consegna resta registrata e accettata: il lavoro non si butta" do
      dipendenza!

      esito = consegna

      expect(esito).to be_ok
      expect(esito.value.reload.review_status).to eq("accepted")
    end

    # Senza questo, MarkStale e ReportFailure riaprono la fase e la macchina apre una SECONDA
    # proposta di modifica sullo stesso lavoro.
    it "la fase risulta comunque conclusa, così nessuno la riapre" do
      dipendenza!

      consegna

      expect(workflow.reload.autopilot_completed_at).to be_present
      expect(workflow.ready_execution_phase).not_to eq("autopilot")
    end

    # Con un prerequisito aperto il ticket non si muoveva già prima; adesso non si muove per una
    # ragione più semplice, quindi non c'è nessun blocco da scrivere.
    it "non scrive più un blocco dei prerequisiti: non c'è niente che stia provando ad avanzare" do
      dipendenza!

      expect { consegna }.not_to change { ticket.events.where(action: "dependency_blocked").count }
    end
  end

  describe "quando la macchina dichiara il rilascio in produzione" do
    let!(:in_progress) { create(:ticket_status, :in_progress, organization:) }
    let!(:done_status) { create(:ticket_status, :done, organization:) }

    let(:payload) do
      { runtime: "claude", reviewer_runtime: "codex",
        result: { code: ticket.code, state: "production-released", tag: "v0.30.0", commit: "3f2a91c0d4e6b8079a1c5f3d2e7b4a6c8d0f1e29",
                  awaiting_human_approval: true },
        review: review_for("closer_production"), observed: observed_head }
    end

    before do
      ticket.update!(status: in_progress)
      workflow.update!(triage_started_at: nil, triaged_at: Time.current, planned_at: Time.current,
                       approved_at: Time.current, autopilot_started_at: Time.current,
                       autopilot_completed_at: Time.current, autopilot_approved_at: Time.current,
                       closer_staging_started_at: Time.current, closer_staging_completed_at: Time.current,
                       ticket_snapshot_digest: "snapshot")
    end

    def consegna
      scope = build_delivery_scope(phase: "closer_production", organization:, project:, ticket:, workflow:)
      # CYRA-621 — il numero lo assegna il server prima che la fase parta: la consegna deve portare
      # QUELLO, e senza la riga viene rifiutata.
      assigned_version(workflow, "closer_production", version: "v0.30.0", sha: "3f2a91c0d4e6b8079a1c5f3d2e7b4a6c8d0f1e29")
      described_class.call(organization:, host: scope[:host], attempt: scope[:attempt], payload:)
    end

    # È il caso peggiore: un ticket portato a «fatto» con un prerequisito ancora aperto non lo guarda
    # più nessuno.
    it "con un prerequisito aperto il ticket NON viene chiuso" do
      dipendenza!

      expect(consegna).to be_ok
      expect(ticket.reload.status).to eq(in_progress)
    end

    it "non registra il cambio di stato e non annuncia niente alla lavagna" do
      dipendenza!

      expect { consegna }.not_to change { ticket.events.where(action: "status_changed").count }
      expect(ticket.reload.status).to eq(in_progress)
    end

    # Il marcatore di fine FASE si scrive lo stesso: senza, la produzione torna riapribile, cioè un
    # secondo rilascio dello stesso lavoro. CYRA-624 — quel marcatore non è più `completed_at`: il
    # lavoro non è concluso finché il rilascio non si è visto in piedi.
    it "la fase risulta comunque conclusa, così non parte un secondo rilascio" do
      dipendenza!

      consegna

      expect(workflow.reload.closer_production_completed_at).to be_present
      expect(workflow.completed_at).to be_nil
      expect(workflow.ready_execution_phase).to be_nil
    end

    # CYRA-624 — la consegna non chiude più il ticket nemmeno senza prerequisiti aperti: chiuderlo lì
    # vorrebbe dire dirlo «Fatto» prima che il rilascio sia partito. Il cancello dei prerequisiti non
    # sparisce: si sposta dove il ticket si muove davvero, cioè alla chiusura della prova.
    it "senza prerequisiti aperti il ticket resta dov'è: a chiuderlo sarà la prova" do
      congela_piano!(workflow, kind: "deploy_smoke", environment_id: 42)

      expect(consegna).to be_ok
      expect(ticket.reload.status).to eq(in_progress)
      expect(done_status.reload).to be_present
      expect(workflow.reload.phase).to eq("awaiting_production_proof")
    end
  end

  # Il cancello vale su chi FA AVANZARE il lavoro del TICKET. Cerca chi scrive lo stato del ticket —
  # `ticket.update!(status:)` — non chi scrive quello di un tentativo, che è un'altra cosa e non ha
  # niente a che vedere coi prerequisiti. Distinguere le due è il punto: una regex più larga
  # segnalerebbe MarkStale e ReportFailure, che aggiornano il tentativo, ed è esattamente il difetto
  # che questo piano esiste per togliere — una spia che si accende per il motivo sbagliato.
  #
  # Chi riporta INDIETRO un ticket resta fuori: è una persona che ha guardato, e metterle davanti un
  # cancello sarebbe una porta chiusa dal lato sbagliato.
  it "nessun altro servizio degli agenti sposta lo stato del ticket saltando il cancello" do
    sorgenti = Dir.glob(Rails.root.join("app/services/agents/**/*.rb")).map { |f| [ f, File.read(f) ] }
    colpevoli = sorgenti.select do |file, testo|
      next false if file.end_with?("deliver.rb")
      next false if testo.include?("DependencyGuard")

      testo.match?(/ticket(?:\.\w+)*\.update!\(\s*status:/m)
    end.map { |file, _| Pathname.new(file).relative_path_from(Rails.root).to_s }

    expect(colpevoli).to eq([]), "spostano lo stato del ticket senza passare dal cancello: #{colpevoli.join(', ')}"
  end
end
