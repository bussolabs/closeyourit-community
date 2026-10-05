# frozen_string_literal: true

require "rails_helper"

# ── CYRA-625 ──────────────────────────────────────────────────────────────────────────────────────
#
# Per i sei progetti che pubblicano un pacchetto, «fatto» è quello che il magazzino pubblico mostra a
# chi installa. Prima bastava che il lavoro di pubblicazione fosse finito senza errori: sul progetto
# Python l'etichetta 0.2.0 stava nel repository dal primo agosto e sul magazzino c'era ancora la
# 0.1.0, e in due settimane e mezzo non se n'era accorto nessuno.
RSpec.describe Agents::Probes::Observe, "il ramo del pacchetto" do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:repository) { create(:github_repository, project:, full_name: "bussolabs/closeyourit-cli") }
  let!(:fatto) { create(:ticket_status, :done, organization:) }
  let(:in_progress) { create(:ticket_status, :in_progress, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, status: in_progress, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:sealed_sha) { "3f2a91c0d4e6b8079a1c5f3d2e7b4a6c8d0f1e29" }

  def prova(registro: "npm", pacchetto: "closeyourit", versione: "v0.11.0")
    workflow.probes.create!(kind: "publish", bound_at: 5.minutes.ago, next_check_at: 1.minute.ago,
                            expected: { "version" => versione, "sha" => sealed_sha,
                                        "repo" => repository.full_name,
                                        "registry" => registro, "package" => pacchetto })
  end

  before do
    pronta_per!(workflow, "closer_production")
    workflow.update!(closer_production_completed_at: Time.current)
  end

  def npm_risponde(body)
    stub_request(:get, "https://registry.npmjs.org/closeyourit").to_return(status: 200, body: body.to_json)
  end

  def npm_ok(versione: "0.11.0", latest: "0.11.0", git_head: nil)
    npm_risponde("dist-tags" => { "latest" => latest },
                 "versions" => { versione => { "gitHead" => git_head || sealed_sha } })
  end

  # Sei risposte diverse, un solo effetto. Stanno qui e non in una tabella dentro il `describe`:
  # una lambda scritta lì non vede i finti, che vivono solo dentro l'esempio.
  def prepara_il_caso(caso)
    url = "https://registry.npmjs.org/closeyourit"
    case caso
    when "versione_assente" then npm_risponde("dist-tags" => { "latest" => "0.10.0" }, "versions" => {})
    when "pacchetto_assente" then stub_request(:get, url).to_return(status: 404, body: "")
    when "timeout" then stub_request(:get, url).to_timeout
    when "errore_server" then stub_request(:get, url).to_return(status: 503, body: "")
    when "troppe_richieste" then stub_request(:get, url).to_return(status: 429, body: "")
    when "corpo_illeggibile" then stub_request(:get, url).to_return(status: 200, body: "<html>")
    end
  end

  describe "quando il pacchetto è sullo scaffale e tutto torna" do
    it "il ticket diventa Fatto" do
      npm_ok
      probe = prova

      expect(described_class.call(probe:)).to be_ok
      expect(ticket.reload.status).to eq(fatto)
      expect(probe.reload.closed_at).to be_present
    end

    # La versione cercata è quella del TAG SIGILLATO, mai quella scritta in un file del repository:
    # su quattro progetti su sei il numero pubblicato veniva da lì, e non lo confrontava nessuno.
    it "cerca la versione del tag sigillato, non quella del file del repository" do
      npm_risponde("dist-tags" => { "latest" => "0.10.0" },
                   "versions" => { "0.10.0" => { "gitHead" => sealed_sha } })
      probe = prova

      described_class.call(probe:)

      expect(probe.reload).to have_attributes(closed_at: nil, last_error_code: "package_missing")
    end

    # Su un rilascio di pacchetto non si legge e non si scrive nessuna riga di rilascio: quel lettore
    # risponderebbe «non ancora provata» e terrebbe la prova aperta per sempre.
    it "non legge e non scrive nessuna riga di rilascio" do
      npm_ok
      # Con l'ambiente di produzione collegato quel lettore risponderebbe «non ancora provata» e
      # terrebbe la prova aperta per sempre: è il caso che conta.
      ambiente = create(:environment, organization:)
      create(:project_environment, project:, environment: ambiente)
      repository.reload.update!(production_environment: ambiente)
      allow_any_instance_of(Projects::Project).to receive(:releases).and_raise("non doveva leggerle")

      expect(described_class.call(probe: prova)).to be_ok
      expect(Projects::Release.where(project:)).to be_empty
    end

    # Il campo `gitHead` su npm È il commit del tag: confrontarlo col tag osservato sarebbe sempre
    # vero e non proverebbe niente. Si confronta col codice sigillato all'approvazione, letto dal
    # piano congelato — e senza chiedere niente a GitHub.
    it "non chiama GitHub nemmeno una volta" do
      npm_ok
      allow(Github::Client).to receive(:new).and_raise("non doveva chiamare GitHub")

      expect(described_class.call(probe: prova)).to be_ok
    end
  end

  describe "l'identità del codice su npm" do
    it "un codice diverso non chiude, e restano scritti tutti e due" do
      npm_ok(git_head: "b" * 40)
      probe = prova

      described_class.call(probe:)

      expect(probe.reload).to have_attributes(closed_at: nil, last_error_code: "git_head_mismatch")
      expect(probe.evidence["registry_sha"]).to eq("b" * 40)
      expect(probe.expected_sha).to eq(sealed_sha)
    end

    # Il confronto è per intero: un prefisso non è un'identità, in nessuno dei due versi.
    [ "3f2a91c", "#{'3f2a91c0d4e6b8079a1c5f3d2e7b4a6c8d0f1e29'}00" ].each do |quasi|
      it "un codice che è solo un pezzo dell'altro non passa (#{quasi.size} caratteri)" do
        npm_ok(git_head: quasi)

        described_class.call(probe: prova)

        expect(workflow.probes.live.sole.closed_at).to be_nil
      end
    end

    it "il campo assente non passa" do
      npm_risponde("dist-tags" => { "latest" => "0.11.0" }, "versions" => { "0.11.0" => {} })

      described_class.call(probe: prova)

      expect(workflow.probes.live.sole.last_error_code).to eq("git_head_mismatch")
    end
  end

  describe "il puntatore «ultima buona»" do
    # Si legge quello che il registro DICHIARA, non un massimo ricalcolato dall'elenco: ricalcolarlo
    # vorrebbe dire sostituire la parola del registro con la nostra.
    it "segue il puntatore dichiarato anche quando nell'elenco c'è una versione più alta" do
      npm_risponde("dist-tags" => { "latest" => "0.11.0" },
                   "versions" => { "0.11.0" => { "gitHead" => sealed_sha },
                                   "0.12.0" => { "gitHead" => "c" * 40 } })

      expect(described_class.call(probe: prova)).to be_ok
      expect(ticket.reload.status).to eq(fatto)
    end

    it "una definitiva successiva va bene" do
      npm_ok(latest: "0.12.0")

      expect(described_class.call(probe: prova)).to be_ok
    end

    it "una definitiva precedente no" do
      npm_ok(latest: "0.10.0")

      described_class.call(probe: prova)

      expect(workflow.probes.live.sole.last_error_code).to eq("latest_not_stable")
    end

    # La versione di prova la si scrive in forme diverse su ogni registro, e tutte hanno in comune di
    # non essere solo cifre: quel puntatore lo prendono tutti quelli che installano senza chiedere
    # una versione.
    %w[0.11.0-beta.1 0.11.0.rc1 0.11.0rc1 0.12.0-beta.1].each do |prerelease|
      it "un puntatore di prova (#{prerelease}) non chiude niente" do
        npm_ok(latest: prerelease)

        described_class.call(probe: prova)

        expect(workflow.probes.live.sole).to have_attributes(closed_at: nil,
                                                             last_error_code: "latest_not_stable")
      end
    end
  end

  describe "quando la risposta dice «non ancora»" do
    # Sei risposte, un solo effetto: si resta agganciati, non si chiama nessuno, si riprova più in là.
    %w[versione_assente pacchetto_assente timeout errore_server troppe_richieste corpo_illeggibile].each do |caso|
      it "«#{caso}»: resta agganciata, non risulta ferma, riprova più in là" do
        prepara_il_caso(caso)
        probe = prova
        prima = probe.next_check_at

        described_class.call(probe:)

        expect(probe.reload).to have_attributes(closed_at: nil, checks_count: 1)
        expect(probe.last_error_code).to be_present
        expect(probe.next_check_at).to be > prima
        expect(workflow.reload.blocked_at).to be_nil
        expect(workflow.phase).to eq("awaiting_production_proof")
      end
    end

    it "una versione ritirata dopo la pubblicazione non conta come pubblicata" do
      stub_request(:get, "https://pypi.org/pypi/closeyourit/0.11.0/json")
        .to_return(status: 200, body: { "info" => { "yanked" => true } }.to_json)
      stub_request(:get, "https://pypi.org/pypi/closeyourit/json")
        .to_return(status: 200, body: { "info" => { "version" => "0.11.0" } }.to_json)
      probe = prova(registro: "pypi")

      described_class.call(probe:)

      expect(probe.reload).to have_attributes(closed_at: nil, last_error_code: "package_yanked")
    end
  end

  # Il motivo riporta l'indirizzo DAVVERO interrogato: un motivo ricomposto a parte potrebbe
  # nascondere una richiesta diversa da quella fatta.
  it "passata l'ora si ferma, e il motivo porta l'indirizzo davvero interrogato" do
    stub_request(:get, "https://registry.npmjs.org/closeyourit").to_return(status: 404, body: "")
    probe = prova
    probe.update!(bound_at: 61.minutes.ago)

    described_class.call(probe:)

    expect(workflow.reload).to have_attributes(blocked_at: be_present, blocked_kind: "release_probe")
    expect(probe.reload.evidence["registry_url"]).to eq("https://registry.npmjs.org/closeyourit")
  end
end
