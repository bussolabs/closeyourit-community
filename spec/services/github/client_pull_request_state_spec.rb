# frozen_string_literal: true

require "rails_helper"

# CYRA-599 — l'occhio: il server legge una proposta di modifica invece di farsela raccontare, e
# soprattutto SA DIRE cosa ha visto.
#
# Il difetto che questo ticket toglie non è «manca una lettura»: è che quattro fatti diversi —
# «non esiste», «non ho il permesso», «GitHub è in avaria», «ho aspettato troppo» — diventavano un
# errore identico. Due di quei fatti sono opposti: sul primo serve una persona, sul secondo si
# aspetta e si riprova. Finché restano indistinguibili, il sistema può solo sbagliare in un verso o
# nell'altro.
RSpec.describe Github::Client, "leggere una proposta di modifica" do
  let(:rsa) { OpenSSL::PKey::RSA.new(2048) }
  let(:installation_id) { 999 }

  subject(:client) do
    described_class.new(app_id: "42", private_key: rsa.to_pem, base_url: "https://api.github.test")
  end

  before do
    Rails.cache.clear
    stub_request(:post, "https://api.github.test/app/installations/#{installation_id}/access_tokens")
      .to_return(status: 201, body: { token: "ghs_installtoken" }.to_json)
  end

  def graphql = "https://api.github.test/graphql"

  def risposta(pull_request)
    { data: { repository: { pullRequest: pull_request } } }.to_json
  end

  def proposta(**sovrascritture)
    {
      headRefOid: "a" * 40, baseRefName: "main", state: "OPEN", isDraft: false,
      mergeable: "MERGEABLE", mergeCommit: nil,
      commits: { nodes: [ { commit: { statusCheckRollup: {
        state: "SUCCESS",
        contexts: { nodes: [ { __typename: "CheckRun", name: "test", conclusion: "SUCCESS", status: "COMPLETED" } ] }
      } } } ] }
    }.merge(sovrascritture)
  end

  describe "distinguere «non esiste» da «non ho potuto guardare»" do
    # È la ragione per cui questo ticket esiste. Prima erano lo stesso errore.
    it "un 404 è una negazione autorevole: chiede una persona, non un altro tentativo" do
      stub_request(:get, "https://api.github.test/repos/acme/api/pulls/7")
        .to_return(status: 404, body: "{}")

      expect { client.send(:token_request, Net::HTTP::Get, installation_id, "/repos/acme/api/pulls/7") }
        .to raise_error(Github::Client::Error) { |e|
          expect(e.code).to eq("R404-GITHUB-010")
          expect(e.status).to eq(:not_found)
          expect(e).not_to be_transient
        }
    end

    it "un 500 è un canale rotto: si riprova, e non si chiede niente a nessuno" do
      stub_request(:get, "https://api.github.test/repos/acme/api/pulls/7")
        .to_return(status: 500, body: "{}")

      expect { client.send(:token_request, Net::HTTP::Get, installation_id, "/repos/acme/api/pulls/7") }
        .to raise_error(Github::Client::Error) { |e|
          expect(e.code).to eq("R502-GITHUB-001")
          expect(e).to be_transient
        }
    end

    # Il 403 è l'unico ambiguo: GitHub lo usa sia per «non hai il permesso» sia per «quota finita».
    # A separarli sono le intestazioni, che prima nessuna riga leggeva.
    it "un 403 senza segnali di limite è una negazione autorevole" do
      stub_request(:get, "https://api.github.test/repos/acme/api/pulls/7")
        .to_return(status: 403, body: "{}", headers: { "x-ratelimit-remaining" => "4321" })

      expect { client.send(:token_request, Net::HTTP::Get, installation_id, "/repos/acme/api/pulls/7") }
        .to raise_error(Github::Client::Error) { |e| expect(e.code).to eq("R404-GITHUB-010") }
    end

    it "un 403 con la quota esaurita è un canale rotto, e porta i secondi da aspettare" do
      stub_request(:get, "https://api.github.test/repos/acme/api/pulls/7")
        .to_return(status: 403, body: "{}",
                   headers: { "x-ratelimit-remaining" => "0",
                              "x-ratelimit-reset" => (Time.current.to_i + 90).to_s })

      expect { client.send(:token_request, Net::HTTP::Get, installation_id, "/repos/acme/api/pulls/7") }
        .to raise_error(Github::Client::Error) { |e|
          expect(e.code).to eq("R502-GITHUB-001")
          expect(e.retry_after).to be_within(5).of(90)
        }
    end

    it "un 429 con retry-after porta i secondi dichiarati da GitHub" do
      stub_request(:get, "https://api.github.test/repos/acme/api/pulls/7")
        .to_return(status: 429, body: "{}", headers: { "retry-after" => "42" })

      expect { client.send(:token_request, Net::HTTP::Get, installation_id, "/repos/acme/api/pulls/7") }
        .to raise_error(Github::Client::Error) { |e| expect(e.retry_after).to eq(42) }
    end

    # Il ramo che restituisce nil deve restare PRIMO: tre lettori contano su quel nil per dire
    # «non c'è», e spostarlo li farebbe sollevare al posto di rispondere.
    it "chi chiede di tollerare l'assenza continua a ricevere nil, non un errore" do
      stub_request(:get, %r{/repos/acme/api/contents/}).to_return(status: 404, body: "{}")

      expect(client.repository_file(installation_id, "acme/api", "Gemfile", ref: "main")).to be_nil
    end
  end

  describe "#pull_request_state" do
    it "riporta il codice esatto dentro la proposta, la base e lo stato" do
      stub_request(:post, graphql).to_return(status: 200, body: risposta(proposta))

      stato = client.pull_request_state(installation_id, "acme/api", 7)

      expect(stato[:head_sha]).to eq("a" * 40)
      expect(stato[:base_ref]).to eq("main")
      expect(stato[:state]).to eq("OPEN")
      expect(stato[:draft]).to be(false)
    end

    # Tre risposte, non due: trattare «non l'ho ancora calcolato» come un no fa respingere un lavoro
    # sano solo perché è stato guardato troppo presto.
    it "la mergiabilità arriva con tutti e tre i valori, senza essere schiacciata su sì/no" do
      %w[MERGEABLE CONFLICTING UNKNOWN].each do |valore|
        stub_request(:post, graphql).to_return(status: 200, body: risposta(proposta(mergeable: valore)))

        expect(client.pull_request_state(installation_id, "acme/api", 7)[:mergeable]).to eq(valore)
      end
    end

    it "riporta i controlli girati su QUEL commit, e dichiara di averli visti" do
      stub_request(:post, graphql).to_return(status: 200, body: risposta(proposta))

      stato = client.pull_request_state(installation_id, "acme/api", 7)

      expect(stato[:checks].map { |c| c["name"] }).to eq([ "test" ])
      expect(stato[:checks_known]).to be(true)
    end

    # «Nessun controllo configurato» è un fatto osservato e vale l'elenco vuoto. Il «non lo so» non
    # arriva mai qui: esce come errore, sotto.
    it "un repository senza controlli dà elenco vuoto, e resta un fatto osservato" do
      senza = proposta(commits: { nodes: [ { commit: { statusCheckRollup: nil } } ] })
      stub_request(:post, graphql).to_return(status: 200, body: risposta(senza))

      stato = client.pull_request_state(installation_id, "acme/api", 7)

      expect(stato[:checks]).to eq([])
      expect(stato[:checks_known]).to be(true)
    end

    it "porta il commit di unione con i suoi genitori" do
      unita = proposta(mergeCommit: { oid: "m" * 40, parents: { nodes: [ { oid: "b" * 40 }, { oid: "c" * 40 } ] } })
      stub_request(:post, graphql).to_return(status: 200, body: risposta(unita))

      merge = client.pull_request_state(installation_id, "acme/api", 7)[:merge_commit]

      expect(merge[:sha]).to eq("m" * 40)
      expect(merge[:parents]).to eq([ "b" * 40, "c" * 40 ])
    end

    it "una proposta che non c'è è una negazione autorevole" do
      stub_request(:post, graphql).to_return(status: 200, body: risposta(nil))

      expect { client.pull_request_state(installation_id, "acme/api", 7) }
        .to raise_error(Github::Client::Error) { |e|
          expect(e.code).to eq("R404-GITHUB-010")
          expect(e).not_to be_transient
        }
    end

    # GraphQL risponde 200 anche quando fallisce: se non lo si guarda, un guasto diventa una lista
    # vuota, e una lista vuota chi legge la scambia per «zero controlli falliti». È il guasto peggiore
    # che questo pezzo possa produrre: far passare per sano un lavoro che nessuno ha verificato.
    it "un errore GraphQL non diventa mai un elenco vuoto" do
      stub_request(:post, graphql)
        .to_return(status: 200, body: { errors: [ { message: "Something went wrong" } ] }.to_json)

      expect { client.pull_request_state(installation_id, "acme/api", 7) }
        .to raise_error(Github::Client::Error) { |e|
          expect(e.code).to eq("R502-GITHUB-001")
          expect(e).to be_transient
          expect(e.message).to include("Something went wrong")
        }
    end

    it "una risposta senza dati è un canale rotto, non una proposta vuota" do
      stub_request(:post, graphql).to_return(status: 200, body: { data: nil }.to_json)

      expect { client.pull_request_state(installation_id, "acme/api", 7) }
        .to raise_error(Github::Client::Error) { |e| expect(e.code).to eq("R502-GITHUB-001") }
    end

    it "un nome di repository senza barra si ferma prima di chiamare GitHub" do
      chiamata = stub_request(:post, graphql)

      expect { client.pull_request_state(installation_id, "senza-barra", 7) }
        .to raise_error(Github::Client::Error)
      expect(chiamata).not_to have_been_requested
    end
  end
end
