# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Github::Webhooks — branch/PR ↔ ticket" do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:repository) do
    create(:github_repository, project:, installation: create(:github_installation, organization:))
  end
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }

  def repo_payload(extra = {})
    {
      "repository" => { "id" => repository.repo_id },
      "installation" => { "id" => repository.installation.installation_id }
    }.merge(extra)
  end

  describe Github::Webhooks::Create do
    it "aggancia il branch al ticket via prefisso e registra branch_created" do
      name = "#{ticket.code}-fix-login"

      described_class.call(payload: repo_payload("ref_type" => "branch", "ref" => name))

      branch = repository.branches.find_by(name: name)
      expect(branch.ticket).to eq(ticket)
      expect(ticket.events.where(action: "branch_created")).to exist
    end

    it "un branch senza codice ticket è registrato senza link né evento" do
      described_class.call(payload: repo_payload("ref_type" => "branch", "ref" => "hotfix"))

      expect(repository.branches.find_by(name: "hotfix").ticket).to be_nil
      expect(Ticketing::Event.where(action: "branch_created")).to be_empty
    end

    it "non raddoppia l'evento se il branch è già registrato (creato da CloseYourIt)" do
      name = "#{ticket.code}-fix"
      create(:github_branch, repository:, ticket:, name:)

      expect { described_class.call(payload: repo_payload("ref_type" => "branch", "ref" => name)) }
        .not_to change { ticket.events.where(action: "branch_created").count }
    end
  end

  describe Github::Webhooks::PullRequest do
    def pr_payload(action:, pr:)
      repo_payload("action" => action, "pull_request" => pr)
    end

    def pr(overrides = {})
      {
        "number" => 5, "title" => "#{ticket.code} Fix", "body" => "",
        "html_url" => "https://github.com/bussolabs/app/pull/5", "id" => 999, "state" => "open",
        "user" => { "login" => "alice" }, "head" => { "ref" => "#{ticket.code}-fix" }, "base" => { "ref" => "main" }
      }.merge(overrides)
    end

    it "opened → crea la PR agganciata al ticket + evento pull_request_opened" do
      described_class.call(payload: pr_payload(action: "opened", pr: pr))

      record = repository.pull_requests.find_by(number: 5)
      expect(record.ticket).to eq(ticket)
      expect(record).to be_state_open
      expect(ticket.events.where(action: "pull_request_opened")).to exist
    end

    it "closed + merged → PR merged + evento pull_request_merged" do
      described_class.call(payload: pr_payload(action: "closed",
                                               pr: pr("state" => "closed", "merged" => true,
                                                      "merged_at" => "2026-07-07T10:00:00Z")))

      record = repository.pull_requests.find_by(number: 5)
      expect(record).to be_state_merged
      expect(ticket.events.where(action: "pull_request_merged")).to exist
    end

    it "closed non mergiata → evento pull_request_closed" do
      described_class.call(payload: pr_payload(action: "closed", pr: pr("state" => "closed", "merged" => false)))

      expect(ticket.events.where(action: "pull_request_closed")).to exist
    end

    it "merged con autoclose_on_merge → ticket in stato done" do
      repository.update!(autoclose_on_merge: true)
      done = create(:ticket_status, :done, organization:)

      described_class.call(payload: pr_payload(action: "closed", pr: pr("merged" => true)))

      expect(ticket.reload.status).to eq(done)
    end

    # CYRA-609 — unire il codice non chiude più il ticket da sé mentre una macchina ci sta lavorando:
    # segnarlo «fatto» prima che il rilascio in produzione parta fa smettere quella parola di dire a
    # che punto è il lavoro. Il tentativo però resta scritto sulla scheda.
    it "merged con una lavorazione in corso: il ticket NON viene chiuso, e il tentativo resta scritto" do
      repository.update!(autoclose_on_merge: true)
      create(:ticket_status, :done, organization:)
      ticket.agent_workflow.update!(triage_started_at: Time.current)
      prima = ticket.status

      described_class.call(payload: pr_payload(action: "closed", pr: pr("merged" => true)))

      expect(ticket.reload.status).to eq(prima)
      expect(ticket.events.where(action: "pull_request_autoclose_declined")).to exist
    end

    # CYRA-613 — anche questo ramo era muto: il codice veniva unito, il ticket restava aperto, e da
    # fuori era identico a una chiusura riuscita.
    it "senza uno stato «Fatto» attivo lo dice, invece di tacere" do
      repository.update!(autoclose_on_merge: true)
      organization.ticket_statuses.where(category: :done).update_all(active: false)

      described_class.call(payload: pr_payload(action: "closed", pr: pr("merged" => true)))

      evento = ticket.events.where(action: "pull_request_autoclose_declined").last
      expect(evento).to be_present
      expect(evento.data["reason"]).to eq("no_done_status")
    end

    # Il motivo del rifiuto resta scritto: «si è fermato» e «si è fermato per questo» sono due cose
    # diverse per chi apre la scheda e si chiede perché il ticket è ancora aperto.
    it "quando la lavorazione rifiuta, sulla scheda resta scritto perché" do
      repository.update!(autoclose_on_merge: true)
      create(:ticket_status, :done, organization:)
      ticket.agent_workflow.update!(triage_started_at: Time.current)

      described_class.call(payload: pr_payload(action: "closed", pr: pr("merged" => true)))

      evento = ticket.events.where(action: "pull_request_autoclose_declined").last
      expect(evento.data["reason"]).to eq("R409-TICKET-020")
    end

    it "idempotente: due consegne merged → un solo evento pull_request_merged" do
      payload = pr_payload(action: "closed", pr: pr("merged" => true))
      described_class.call(payload:)

      expect { described_class.call(payload:) }
        .not_to change { ticket.events.where(action: "pull_request_merged").count }
    end

    it "non raddoppia pull_request_opened se la PR è già registrata (aperta da CloseYourIt)" do
      create(:github_pull_request, repository:, ticket:, number: 5, state: :open)

      expect { described_class.call(payload: pr_payload(action: "opened", pr: pr)) }
        .not_to change { ticket.events.where(action: "pull_request_opened").count }
    end

    # Simula la race delle consegne gemelle (webhook at-least-once): la riga è già stata scritta,
    # ma il nostro lookup iniziale non l'ha vista e prova comunque a crearla. `doppione` è il
    # record nuovo che il service tenterebbe di salvare.
    def stub_concurrent_delivery
      # Il service risolve il repo SOTTO l'installazione del payload (CYRA-227), non più con un
      # Github::Repository.find_by globale: per far arrivare gli stub sull'istanza dello spec va
      # intercettata quella catena, altrimenti il service lavora su un oggetto ricaricato dal DB.
      installation = repository.installation
      allow(Github::Installation).to receive(:find_by).and_call_original
      allow(Github::Installation).to receive(:find_by)
        .with(installation_id: installation.installation_id).and_return(installation)
      allow(installation).to receive(:repositories).and_return(
        instance_double(ActiveRecord::Relation).tap do |relation|
          allow(relation).to receive(:find_by).with(repo_id: repository.repo_id).and_return(repository)
        end
      )
      doppione = repository.pull_requests.build(number: 5)
      allow(repository.pull_requests).to receive(:find_or_initialize_by).with(number: 5).and_return(doppione)
      doppione
    end

    it "consegna concorrente vista dalla validazione locale: nessun errore, una sola riga, nessun evento doppio" do
      create(:github_pull_request, repository:, ticket:, number: 5, state: :open, github_id: 999)
      stub_concurrent_delivery # la validazione di unicità vede la riga gemella → RecordInvalid

      expect { described_class.call(payload: pr_payload(action: "opened", pr: pr)) }.not_to raise_error
      expect(Github::PullRequest.where(repository:, number: 5).count).to eq(1)
      expect(ticket.events.where(action: "pull_request_opened")).to be_empty
    end

    it "consegna concorrente che colpisce il vincolo del database: nessun errore, una sola riga" do
      create(:github_pull_request, repository:, ticket:, number: 5, state: :open, github_id: 999)
      doppione = stub_concurrent_delivery # la validazione passa ma l'INSERT viola l'indice unico
      allow(doppione).to receive(:save!).and_raise(
        ActiveRecord::RecordNotUnique.new("PG::UniqueViolation: index_github_pull_requests_on_repository_id_and_number")
      )

      expect { described_class.call(payload: pr_payload(action: "opened", pr: pr)) }.not_to raise_error
      expect(Github::PullRequest.where(repository:, number: 5).count).to eq(1)
    end

    it "una validazione fallita che non sia l'unicità del numero resta un errore" do
      doppione = stub_concurrent_delivery
      doppione.errors.add(:html_url, :blank)
      allow(doppione).to receive(:save!).and_raise(ActiveRecord::RecordInvalid.new(doppione))

      expect { described_class.call(payload: pr_payload(action: "opened", pr: pr)) }
        .to raise_error(ActiveRecord::RecordInvalid)
    end

    it "PR senza codice ticket → registrata senza ticket né evento" do
      described_class.call(payload: pr_payload(action: "opened",
                                               pr: pr("title" => "Random", "body" => "", "head" => { "ref" => "topic" })))

      expect(repository.pull_requests.find_by(number: 5).ticket).to be_nil
      expect(Ticketing::Event.where(action: "pull_request_opened")).to be_empty
    end

    it "repo trasferito con vecchia registrazione ancora viva (stesso repo_id in due org): il webhook tocca solo l'org dell'installation.id del payload" do
      repository.update!(autoclose_on_merge: true)
      done_a = create(:ticket_status, :done, organization:)

      other_organization = create(:organization)
      other_project = create(:project, organization: other_organization)
      other_installation = create(:github_installation, organization: other_organization)
      other_repository = create(:github_repository, project: other_project, installation: other_installation,
                                                      repo_id: repository.repo_id, autoclose_on_merge: true)
      other_ticket = create(:ticket, organization: other_organization, project: other_project)
      create(:ticket_status, :done, organization: other_organization)
      other_status_before = other_ticket.status

      described_class.call(payload: pr_payload(action: "closed", pr: pr("merged" => true)))

      record = repository.pull_requests.find_by(number: 5)
      expect(record.ticket).to eq(ticket)
      expect(ticket.events.where(action: "pull_request_merged")).to exist
      expect(ticket.reload.status).to eq(done_a)

      expect(other_repository.pull_requests.find_by(number: 5)).to be_nil
      expect(other_ticket.events).to be_empty
      expect(other_ticket.reload.status).to eq(other_status_before)
    end
  end
end
