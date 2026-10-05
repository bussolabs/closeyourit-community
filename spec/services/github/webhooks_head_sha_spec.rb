# frozen_string_literal: true

require "rails_helper"

# CYRA-600 — il nome del ramo è un'etichetta mobile: chi spinge un commit sposta il ramo e il nome
# resta identico. Chi guardava non aveva modo di accorgersi che il codice fosse cambiato dopo essere
# stato visto. Qui si annota il codice, e ci si accorge quando cambia.
#
# La parte delicata non è scrivere lo sha: è NON scriverlo quando la consegna è vecchia. Gli webhook
# arrivano at-least-once e fuori ordine, e una consegna vecchia che sovrascrive una nuova
# mostrerebbe come testa un commit che non lo è più. Il confronto non può usare l'ora del nostro
# salvataggio: quella dice quando abbiamo scritto noi, non quando è successo.
RSpec.describe "Github::Webhooks — il codice dentro la proposta" do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:repository) do
    create(:github_repository, project:, installation: create(:github_installation, organization:))
  end
  let(:ticket) { create(:ticket, organization:, project:) }

  def consegna(sha:, updated_at:, action: "synchronize")
    Github::Webhooks::PullRequest.call(payload: {
      "repository" => { "id" => repository.repo_id },
      "installation" => { "id" => repository.installation.installation_id },
      "action" => action,
      "pull_request" => {
        "number" => 7, "title" => "#{ticket.code} una proposta", "state" => "open",
        "head" => { "ref" => "#{ticket.code}-lavoro", "sha" => sha },
        "base" => { "ref" => "main" }, "id" => 12_345,
        "html_url" => "https://github.com/acme/api/pull/7",
        "user" => { "login" => "octocat" }, "updated_at" => updated_at
      }
    })
    repository.pull_requests.find_by(number: 7)
  end

  it "annota il codice che c'è dentro, non solo il nome del ramo" do
    pull = consegna(sha: "a" * 40, updated_at: "2026-08-19T10:00:00Z")

    expect(pull.head_sha).to eq("a" * 40)
    expect(pull.head_ref).to eq("#{ticket.code}-lavoro")
    expect(pull.github_updated_at).to eq(Time.zone.parse("2026-08-19T10:00:00Z"))
  end

  it "una consegna più recente aggiorna il codice" do
    consegna(sha: "a" * 40, updated_at: "2026-08-19T10:00:00Z")

    expect(consegna(sha: "b" * 40, updated_at: "2026-08-19T10:05:00Z").head_sha).to eq("b" * 40)
  end

  # Il caso per cui esiste l'orologio dedicato.
  it "una consegna vecchia NON riporta indietro il codice" do
    consegna(sha: "b" * 40, updated_at: "2026-08-19T10:05:00Z")
    pull = consegna(sha: "a" * 40, updated_at: "2026-08-19T10:00:00Z")

    expect(pull.head_sha).to eq("b" * 40)
    expect(pull.github_updated_at).to eq(Time.zone.parse("2026-08-19T10:05:00Z"))
  end

  it "una consegna senza orario riempie una colonna vuota" do
    pull = consegna(sha: "a" * 40, updated_at: nil)

    expect(pull.head_sha).to eq("a" * 40)
    expect(pull.github_updated_at).to be_nil
  end

  # Senza orario non si può ordinare: scrivere sopra un valore messo da chi l'orologio ce l'aveva
  # sarebbe una scommessa, e la si perde proprio nel caso che conta.
  it "una consegna senza orario NON sovrascrive un codice già annotato" do
    consegna(sha: "b" * 40, updated_at: "2026-08-19T10:05:00Z")

    expect(consegna(sha: "a" * 40, updated_at: nil).head_sha).to eq("b" * 40)
  end

  # La guardia vale su questi due campi soltanto: allargarla cambierebbe comportamenti che nessuno
  # ha chiesto di cambiare, e la chiusura di una proposta è uno di quelli.
  it "una consegna vecchia aggiorna comunque lo stato, come prima" do
    consegna(sha: "b" * 40, updated_at: "2026-08-19T10:05:00Z")
    pull = consegna(sha: "a" * 40, updated_at: "2026-08-19T10:00:00Z", action: "closed")

    expect(pull.state).to eq("closed")
    expect(pull.head_sha).to eq("b" * 40)
  end
end
