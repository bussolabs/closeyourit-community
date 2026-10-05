# frozen_string_literal: true

require "rails_helper"

# CYRA-720 — il payload di un webhook è JSON arbitrario che arriva da fuori: la firma dice DA CHI
# viene, non com'è fatto dentro. Un campo che il contratto vuole oggetto può arrivare stringa, lista
# o assente, e `dig` su una stringa solleva TypeError. Qui si prova che una consegna malformata non
# manda in errore il server: nessun handler solleva, nessun dato viene scritto a caso.
RSpec.describe "Github::Webhooks — consegne malformate" do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:repository) do
    create(:github_repository, project:, installation: create(:github_installation, organization:))
  end

  def repo_payload(extra = {})
    {
      "repository" => { "id" => repository.repo_id },
      "installation" => { "id" => repository.installation.installation_id }
    }.merge(extra)
  end

  # Consegne che non sono nemmeno un oggetto: nessun handler deve sollevare.
  [ nil, "una stringa", [ 1, 2, 3 ], 42 ].each do |payload|
    it "una consegna che non è un oggetto (#{payload.inspect}) non manda in errore nessun handler" do
      [ Github::Webhooks::Push, Github::Webhooks::Create, Github::Webhooks::Release,
        Github::Webhooks::Installation, Github::Webhooks::PullRequest ].each do |handler|
        expect { handler.call(payload: payload) }.not_to raise_error
      end
    end
  end

  describe Github::Webhooks::Base do
    it "l'installazione non è un oggetto → nessun errore, nessuna corrispondenza" do
      payload = repo_payload("installation" => "1234", "ref" => "refs/tags/v1.0.0")

      expect { Github::Webhooks::Push.call(payload: payload) }.not_to raise_error
    end

    it "il repository non è un oggetto → nessun errore, nessun ramo registrato" do
      payload = repo_payload("repository" => "boom", "ref_type" => "branch", "ref" => "hotfix")

      expect { Github::Webhooks::Create.call(payload: payload) }.not_to raise_error
      expect(Github::Branch.where(name: "hotfix")).to be_empty
    end
  end

  describe Github::Webhooks::PullRequest do
    it "la proposta non è un oggetto → nessun errore, nessuna proposta scritta" do
      expect { described_class.call(payload: repo_payload("pull_request" => "numero 7")) }.not_to raise_error
      expect(repository.pull_requests).to be_empty
    end

    it "il numero della proposta non è un numero → ignorata senza errore" do
      payload = repo_payload("action" => "opened", "pull_request" => { "number" => { "id" => 1 }, "title" => "X" })

      expect { described_class.call(payload: payload) }.not_to raise_error
      expect(repository.pull_requests).to be_empty
    end

    it "il numero della proposta è fuori dalla misura di una colonna → ignorata senza errore" do
      payload = repo_payload("action" => "opened",
                             "pull_request" => { "number" => 99_999_999_999, "title" => "X",
                                                 "html_url" => "https://github.com/bussolabs/app/pull/1" })

      expect { described_class.call(payload: payload) }.not_to raise_error
      expect(repository.pull_requests).to be_empty
    end

    it "la proposta non porta il proprio indirizzo → ignorata senza errore" do
      payload = repo_payload("action" => "opened", "pull_request" => { "number" => 9, "title" => "X" })

      expect { described_class.call(payload: payload) }.not_to raise_error
      expect(repository.pull_requests).to be_empty
    end

    # Una consegna malformata non deve nemmeno DEGRADARE quel che è già scritto: prima del filtro
    # sollevava (e non toccava niente), col filtro i campi malformati diventano nil e senza questa
    # difesa cancellerebbero dati buoni arrivati da una consegna sana.
    it "una consegna malformata non cancella i dati già annotati sulla proposta" do
      sana = repo_payload(
        "action" => "opened",
        "pull_request" => {
          "number" => 11, "title" => "Fix", "state" => "open", "id" => 4242,
          "html_url" => "https://github.com/bussolabs/app/pull/11",
          "head" => { "ref" => "fix-login" }, "base" => { "ref" => "main" }, "user" => { "login" => "alice" }
        }
      )
      described_class.call(payload: sana)

      storta = repo_payload(
        "action" => "opened",
        "pull_request" => { "number" => 11, "state" => "open", "head" => "rotto", "base" => 42, "user" => [] }
      )
      expect { described_class.call(payload: storta) }.not_to raise_error

      pull = repository.pull_requests.find_by(number: 11)
      expect(pull.head_ref).to eq("fix-login")
      expect(pull.base_ref).to eq("main")
      expect(pull.author_login).to eq("alice")
      expect(pull.github_id).to eq(4242)
      expect(pull.html_url).to eq("https://github.com/bussolabs/app/pull/11")
    end

    it "ramo, base, autore e codice non sono oggetti → la proposta è scritta lo stesso, senza quei dati" do
      payload = repo_payload(
        "action" => "opened",
        "pull_request" => {
          "number" => 7, "title" => "Fix", "state" => "open",
          "html_url" => "https://github.com/bussolabs/app/pull/7",
          "head" => "main", "base" => [ "main" ], "user" => "alice", "updated_at" => "2026-13-45"
        }
      )

      expect { described_class.call(payload: payload) }.not_to raise_error

      pull = repository.pull_requests.find_by(number: 7)
      expect(pull).to be_present
      expect(pull.head_ref).to be_nil
      expect(pull.base_ref).to be_nil
      expect(pull.author_login).to be_nil
      expect(pull.head_sha).to be_nil
    end
  end

  describe Github::Webhooks::Release do
    it "la release non è un oggetto → nessun errore, nessun rilascio legato" do
      payload = repo_payload("action" => "published", "release" => "v1.0.0")

      expect { described_class.call(payload: payload) }.not_to raise_error
    end
  end

  describe Github::Webhooks::Installation do
    it "l'installazione non è un oggetto → nessun errore e nessuna installazione rimossa" do
      payload = { "action" => "deleted", "installation" => "1234" }

      expect { described_class.call(payload: payload) }.not_to raise_error
      expect(Github::Installation.where(id: repository.installation.id)).to exist
    end
  end

  describe Github::WebhookJob do
    it "una consegna malformata non fa fallire la lavorazione" do
      %w[push create release installation pull_request].each do |event|
        expect { described_class.perform_now(event: event, payload: "spazzatura") }.not_to raise_error
      end
    end
  end
end
