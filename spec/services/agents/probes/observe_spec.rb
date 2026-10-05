# frozen_string_literal: true

require "rails_helper"

# ── CYRA-624 ──────────────────────────────────────────────────────────────────────────────────────
#
# Il ticket diventava «Fatto» nell'istante in cui la macchina diceva di aver messo l'etichetta della
# versione. Lì non era stato rilasciato niente: il rilascio parte dopo, e può andare male un minuto
# dopo — e il ticket restava Fatto lo stesso, senza che nessuno venisse avvisato.
#
# Qui si prova la cosa che rende «Fatto» un fatto e non una parola: tre domande, e servono tutte e
# tre. Ognuna può essere l'unica a mancare.
RSpec.describe Agents::Probes::Observe do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:repository) { create(:github_repository, project:, full_name: "bussolabs/closeyourit-rails") }
  let!(:fatto) { create(:ticket_status, :done, organization:) }
  let(:in_progress) { create(:ticket_status, :in_progress, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, status: in_progress, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:sealed_sha) { "3f2a91c0d4e6b8079a1c5f3d2e7b4a6c8d0f1e29" }
  let(:versione) { "v0.30.0" }

  let(:probe) do
    workflow.probes.create!(kind: "deploy_smoke", bound_at: 5.minutes.ago, next_check_at: 1.minute.ago,
                            expected: { "version" => versione, "sha" => sealed_sha,
                                        "repo" => repository.full_name, "environment_id" => 42 })
  end

  before { pronta_per!(workflow, "closer_production") && workflow.update!(closer_production_completed_at: Time.current) }

  # Il finto risponde alle tre domande separatamente: ogni prova ne guasta UNA sola, così un rosso
  # dice quale delle tre è venuta a mancare.
  def client_che(tag: sealed_sha, jobs: passaggi_riusciti, run_conclusion: "success", runs: :uno)
    instance_double(Github::Client).tap do |c|
      allow(c).to receive(:tag_commit).and_return(tag)
      allow(c).to receive(:workflow_runs)
        .and_return(runs == :nessuno ? [] : [ { "id" => 7, "conclusion" => run_conclusion } ])
      allow(c).to receive(:workflow_run_jobs).and_return(jobs)
    end
  end

  def passaggi_riusciti
    [ { "name" => "deploy / deploy-production", "conclusion" => "success" },
      { "name" => "deploy / smoke-prod", "conclusion" => "success" } ]
  end

  def row_proved!(sha: sealed_sha, proved_at: Time.current, version: nil)
    project.releases.create!(version: version || versione, environment: "production", sha:, proved_at:)
  end

  def osserva(client) = described_class.call(probe:, client:)

  it "chiede il tag a GitHub col numero dell'installazione, non con la chiave interna (CYRA-762)" do
    client = client_che

    osserva(client)

    expect(client).to have_received(:tag_commit)
      .with(repository.installation.installation_id, anything, anything)
  end

  describe "quando tutte e tre le risposte tornano" do
    before { row_proved! }

    it "il ticket diventa Fatto, il lavoro è concluso e la prova si chiude, tutto insieme" do
      esito = osserva(client_che)

      expect(esito).to be_ok
      expect(ticket.reload.status).to eq(fatto)
      expect(workflow.reload.completed_at).to be_present
      expect(probe.reload).to have_attributes(closed_at: be_present, next_check_at: nil)
    end

    # O tutte e tre o nessuna: un ticket «Fatto» con la prova ancora agganciata verrebbe riguardato
    # per sempre; una prova chiusa col ticket non Fatto sparirebbe in silenzio.
    it "se una delle tre scritture non riesce non ne resta nessuna" do
      allow(Ticketing::ChangeStatus).to receive(:call).and_raise(ActiveRecord::StatementInvalid, "no")

      expect { osserva(client_che) }.to raise_error(ActiveRecord::StatementInvalid)

      expect(ticket.reload.status).to eq(in_progress)
      expect(workflow.reload.completed_at).to be_nil
      expect(probe.reload.closed_at).to be_nil
    end

    # CYRA-597 — il cancello dei prerequisiti non sparisce, si sposta dove il ticket si muove davvero.
    it "con un prerequisito ancora aperto non chiude niente" do
      blocker = create(:ticket, organization:, project:, status: in_progress)
      create(:ticket_dependency, ticket:, blocker:)

      osserva(client_che)

      expect(ticket.reload.status).to eq(in_progress)
      expect(workflow.reload.completed_at).to be_nil
      expect(probe.reload).to have_attributes(closed_at: nil, last_error_code: "dependency_blocked")
    end
  end

  describe "l'etichetta della versione" do
    before { row_proved! }

    it "su un commit diverso: non chiude, e conserva scritti tutti e due" do
      altro = "b" * 40

      osserva(client_che(tag: altro))

      expect(probe.reload).to have_attributes(closed_at: nil, last_error_code: "tag_mismatch")
      expect(probe.evidence["tag_commit"]).to eq(altro)
      expect(probe.expected_sha).to eq(sealed_sha)
    end

    # Nemmeno «ci sta sopra»: un commit che DISCENDE dal codice sigillato non è il codice sigillato, e
    # pubblicarlo vorrebbe dire aver messo fuori righe che nessuno ha guardato.
    it "su un commit che discende dal sigillato: non chiude lo stesso" do
      discendente = "c" * 40

      osserva(client_che(tag: discendente))

      expect(probe.reload.closed_at).to be_nil
    end

    it "assente: non chiude" do
      osserva(client_che(tag: nil))

      expect(probe.reload).to have_attributes(closed_at: nil, last_error_code: "tag_missing")
    end
  end

  describe "i due passaggi del rilascio" do
    before { row_proved! }

    # Il nome arriva da un file di lavorazione richiamato, quindi porta il prefisso del lavoro che lo
    # richiama: si confronta l'ultimo pezzo, non tutto il nome.
    it "riconosce i passaggi anche col prefisso del lavoro che li richiama" do
      expect(osserva(client_che)).to be_ok
      expect(probe.reload.closed_at).to be_present
    end

    it "uno dei due mancante: non chiude" do
      solo_uno = [ { "name" => "deploy / deploy-production", "conclusion" => "success" } ]

      osserva(client_che(jobs: solo_uno))

      expect(probe.reload).to have_attributes(closed_at: nil, last_error_code: "release_run_missing")
    end

    # Non basta che il giro nel suo insieme sia verde: un giro con quei passaggi SALTATI resta verde,
    # e saltato vuol dire che non è stato fatto niente.
    %w[skipped cancelled neutral].each do |esito|
      it "un passaggio «#{esito}» non conta come riuscito, nemmeno col giro verde" do
        jobs = [ { "name" => "deploy / deploy-production", "conclusion" => "success" },
                 { "name" => "deploy / smoke-prod", "conclusion" => esito } ]

        osserva(client_che(jobs:, run_conclusion: "success"))

        expect(probe.reload.closed_at).to be_nil
      end
    end

    it "un passaggio ancora senza esito: non chiude e non si ferma" do
      jobs = [ { "name" => "deploy / deploy-production", "conclusion" => "success" },
               { "name" => "deploy / smoke-prod", "conclusion" => nil } ]

      osserva(client_che(jobs:, run_conclusion: nil))

      expect(probe.reload.closed_at).to be_nil
      expect(workflow.reload.blocked_at).to be_nil
    end

    # Un rilascio andato male non è «non ancora»: è una cosa che una persona deve guardare.
    it "un giro di rilascio concluso male ferma la lavorazione e scrive dove" do
      jobs = [ { "name" => "deploy / deploy-production", "conclusion" => "failure" } ]

      osserva(client_che(jobs:, run_conclusion: "failure"))

      expect(workflow.reload).to have_attributes(blocked_at: be_present, blocked_phase: "closer_production",
                                                 blocked_kind: "release_probe")
      expect(workflow.blocked_reason).to include("release_run_failed")
      expect(workflow.phase).not_to eq("awaiting_production_proof")
    end

    # Sullo stesso commit girano anche altre lavorazioni: fermare tutto perché un controllo di stile è
    # rosso vorrebbe dire chiamare una persona per una cosa che col rilascio non c'entra.
    it "un giro rosso che non contiene i due passaggi non ferma niente" do
      estranei = [ { "name" => "lint / rubocop", "conclusion" => "failure" } ]

      osserva(client_che(jobs: estranei, run_conclusion: "failure"))

      expect(workflow.reload.blocked_at).to be_nil
      expect(probe.reload.last_error_code).to eq("release_run_missing")
    end
  end

  describe "la riga del rilascio" do
    it "manca: non chiude" do
      osserva(client_che)

      expect(probe.reload).to have_attributes(closed_at: nil, last_error_code: "release_not_proved")
    end

    it "senza l'istante di prova: non chiude" do
      row_proved!(proved_at: nil)

      osserva(client_che)

      expect(probe.reload.closed_at).to be_nil
    end

    # Due valori vuoti non contano come uguali: sarebbe la stessa promessa dichiarata e non
    # mantenuta, scritta con un confronto.
    it "col codice vuoto sulla riga: non chiude" do
      row_proved!(sha: nil)

      osserva(client_che)

      expect(probe.reload.closed_at).to be_nil
    end

    it "con un codice diverso: non chiude" do
      row_proved!(sha: "d" * 40)

      osserva(client_che)

      expect(probe.reload.closed_at).to be_nil
    end

    # Mai «l'ultimo rilascio registrato»: l'ultimo può essere di un altro lavoro.
    it "non si accontenta dell'ultimo rilascio del progetto" do
      row_proved!(version: "v0.31.0")

      osserva(client_che)

      expect(probe.reload.closed_at).to be_nil
    end
  end

  describe "quando GitHub non risponde" do
    let(:rotto) do
      instance_double(Github::Client).tap do |c|
        allow(c).to receive(:tag_commit).and_raise(Github::Client::Error.new("timeout", code: "R502-GITHUB-001"))
      end
    end

    it "resta agganciata, non risulta ferma, e si riprova più in là" do
      prima = probe.next_check_at

      osserva(rotto)

      expect(probe.reload).to have_attributes(closed_at: nil, last_error_code: "R502-GITHUB-001", checks_count: 1)
      expect(probe.next_check_at).to be > prima
      expect(workflow.reload.blocked_at).to be_nil
      expect(workflow.phase).to eq("awaiting_production_proof")
    end

    # Passata l'ora non è più «non ancora»: si chiama una persona, e con un motivo diverso da quello
    # del rilascio andato male — si sistemano in due posti diversi.
    it "passata l'ora si ferma, con un motivo distinguibile da quello del giro fallito" do
      probe.update!(bound_at: 61.minutes.ago)

      osserva(rotto)

      expect(workflow.reload).to have_attributes(blocked_at: be_present, blocked_kind: "release_probe")
      expect(workflow.blocked_reason).to include("release_proof_timeout")
      expect(workflow.blocked_reason).not_to include("release_run_failed")
    end

    it "prima dell'ora non si ferma" do
      probe.update!(bound_at: 59.minutes.ago)

      osserva(rotto)

      expect(workflow.reload.blocked_at).to be_nil
    end
  end

  # Mentre il sistema guarda, la lavorazione NON chiede niente: non deve comparire fra le cose da
  # decidere. Quando il rilascio va male, invece, deve comparirci — ed è la misura che conta, perché
  # prima di questo lavoro il ticket era già «Fatto» e non compariva mai da nessuna parte.
  describe "chi viene chiamato, e quando" do
    let(:account) do
      create(:account).tap do |riga|
        create(:membership, organization:, account: riga)
        create(:project_membership, account: riga, project:)
      end
    end

    def coda
      Home::Approvals::Queue.call(
        account:, organization:,
        visible_projects: Projects::Project.where(id: project.id),
        visible_tickets: Ticketing::Ticket.where(project_id: project.id)
      ).items.map(&:key)
    end

    before do
      organization.update!(cto: account)
      row_proved!
    end

    it "mentre guarda non chiede niente a nessuno" do
      osserva(client_che(tag: nil))

      expect(workflow.reload.phase).to eq("awaiting_production_proof")
      expect(coda).not_to include(a_string_including(workflow.id))
    end

    it "quando il rilascio va male compare fra quelle che aspettano una persona" do
      jobs = [ { "name" => "deploy / deploy-production", "conclusion" => "failure" } ]

      osserva(client_che(jobs:, run_conclusion: "failure"))

      expect(coda).to include(a_string_including(workflow.id))
    end
  end

  # Una prova già chiusa non si guarda più: né per bloccarla, né per farla scadere, né per
  # riscriverci sopra. Toccarla vorrebbe dire che il verbale di un rilascio già concluso cambia da
  # solo dopo — e fra un mese chi lo rilegge trova l'ultimo errore di un controllo che non contava.
  it "una prova chiusa non viene toccata: né riaperta, né scaduta, né riscritta" do
    probe.update!(closed_at: 1.minute.ago, bound_at: 2.hours.ago, next_check_at: nil,
                  last_error_code: nil, checks_count: 2)

    expect(osserva(client_che(tag: "e" * 40))).to be_ok

    expect(workflow.reload.blocked_at).to be_nil
    expect(probe.reload).to have_attributes(next_check_at: nil, last_error_code: nil, checks_count: 2)
  end
end
