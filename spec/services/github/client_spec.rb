# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::Client do
  let(:rsa) { OpenSSL::PKey::RSA.new(2048) }
  let(:installation_id) { 999 }

  subject(:client) do
    described_class.new(app_id: "42", private_key: rsa.to_pem, base_url: "https://api.github.test")
  end

  before { Rails.cache.clear }

  def token_url = "https://api.github.test/app/installations/#{installation_id}/access_tokens"

  def stub_token
    stub_request(:post, token_url).to_return(status: 201, body: { token: "ghs_installtoken" }.to_json)
  end

  describe "#installation_token" do
    it "conia il token via JWT App (Bearer) e lo ritorna" do
      req = stub_request(:post, token_url).to_return(status: 201, body: { token: "ghs_x" }.to_json)

      expect(client.installation_token(installation_id)).to eq("ghs_x")
      expect(req).to have_been_requested
      expect(
        a_request(:post, token_url).with { |r| r.headers["Authorization"].to_s.start_with?("Bearer ") }
      ).to have_been_made
    end

    # In test il cache store è :null_store (non memorizza nulla): qui serve una cache VERA, perché
    # l'oggetto del ticket è proprio cosa finisce scritto — in produzione una tabella PostgreSQL
    # (Solid Cache), quindi backup e repliche (CYRA-277).
    context "con la memoria di servizio reale" do
      let(:cache) { ActiveSupport::Cache::MemoryStore.new }
      let(:cache_key) { "github:installation_token:#{installation_id}" }

      before { allow(Rails).to receive(:cache).and_return(cache) }

      def stub_secret_token
        stub_request(:post, token_url).to_return(status: 201, body: { token: "ghs_segreto" }.to_json)
      end

      it "scrive la voce cifrata con le chiavi del vault, mai il token in chiaro" do
        stub_secret_token

        client.installation_token(installation_id)

        stored = cache.read(cache_key)
        expect(stored).to be_present
        expect(stored).not_to include("ghs_segreto")
        expect(ActiveRecord::Encryption.encryptor.decrypt(stored)).to eq("ghs_segreto")
      end

      it "rilegge la voce cifrata senza ri-coniare il token" do
        req = stub_secret_token

        expect(client.installation_token(installation_id)).to eq("ghs_segreto")
        expect(client.installation_token(installation_id)).to eq("ghs_segreto")

        expect(req).to have_been_requested.once
      end

      it "conia un token nuovo se la voce in memoria non è decifrabile" do
        cache.write(cache_key, "ghs_residuo_in_chiaro")
        req = stub_secret_token

        expect(client.installation_token(installation_id)).to eq("ghs_segreto")
        expect(req).to have_been_requested
      end

      it "lascia scadere la voce prima che il token perda validità" do
        req = stub_secret_token
        client.installation_token(installation_id)

        travel(described_class::TOKEN_TTL + 1.minute) do
          expect(client.installation_token(installation_id)).to eq("ghs_segreto")
        end

        expect(req).to have_been_requested.twice
      end

      it "non scrive nulla se la cifratura non è disponibile" do
        broken = instance_double(ActiveRecord::Encryption::Encryptor)
        allow(broken).to receive(:encrypt).and_raise(ActiveRecord::Encryption::Errors::Configuration)
        allow(broken).to receive(:decrypt).and_raise(ActiveRecord::Encryption::Errors::Configuration)
        allow(ActiveRecord::Encryption).to receive(:encryptor).and_return(broken)
        stub_secret_token

        expect(client.installation_token(installation_id)).to eq("ghs_segreto")
        expect(cache.read(cache_key)).to be_nil
      end
    end
  end

  describe "#ref" do
    it "GET del ref e ritorna l'oggetto" do
      stub_token
      stub_request(:get, "https://api.github.test/repos/bussolabs/app/git/ref/heads/main")
        .to_return(status: 200, body: { object: { sha: "deadbeef" } }.to_json)

      expect(client.ref(installation_id, "bussolabs/app", "heads/main").dig("object", "sha")).to eq("deadbeef")
    end
  end

  # CYRA-876 — in `base...head`, `ahead_by` counts the commits of head missing from base. Reading
  # `behind_by` answered the opposite question and blocked every staging proof with staging_not_merged.
  describe "#commit_contained?" do
    def stub_compare(ahead_by:, behind_by:)
      stub_token
      stub_request(:get, "https://api.github.test/repos/bussolabs/app/compare/merge...approved")
        .to_return(status: 200, body: { ahead_by:, behind_by: }.to_json)
    end

    it "is true when head is an ancestor of base" do
      stub_compare(ahead_by: 0, behind_by: 2)

      expect(client.commit_contained?(installation_id, "bussolabs/app", "merge", "approved")).to be(true)
    end

    it "is false when head has commits that base lacks" do
      stub_compare(ahead_by: 1, behind_by: 0)

      expect(client.commit_contained?(installation_id, "bussolabs/app", "merge", "approved")).to be(false)
    end
  end

  describe "#repositories" do
    it "legge tutte le pagine dei repository accessibili all'installazione" do
      stub_token
      first_page = Array.new(100) { |index| { id: index + 1, full_name: "bussolabs/repo-#{index + 1}" } }
      stub_request(:get, "https://api.github.test/installation/repositories?per_page=100&page=1")
        .to_return(status: 200, body: { total_count: 101, repositories: first_page }.to_json)
      stub_request(:get, "https://api.github.test/installation/repositories?per_page=100&page=2")
        .to_return(status: 200, body: {
          total_count: 101, repositories: [ { id: 101, full_name: "bussolabs/closeyourit-agent" } ]
        }.to_json)

      repositories = client.repositories(installation_id)

      expect(repositories.size).to eq(101)
      expect(repositories.last["full_name"]).to eq("bussolabs/closeyourit-agent")
    end
  end

  describe "#create_ref" do
    it "POSTa refs/heads con sha" do
      stub_token
      create = stub_request(:post, "https://api.github.test/repos/bussolabs/app/git/refs")
               .with(body: { ref: "refs/heads/DRRA-1-fix", sha: "abc123" })
               .to_return(status: 201, body: { ref: "refs/heads/DRRA-1-fix" }.to_json)

      result = client.create_ref(installation_id, "bussolabs/app", "refs/heads/DRRA-1-fix", "abc123")

      expect(result["ref"]).to eq("refs/heads/DRRA-1-fix")
      expect(create).to have_been_requested
    end
  end

  describe "#create_pull" do
    it "POSTa la PR con title/head/base" do
      stub_token
      pull = stub_request(:post, "https://api.github.test/repos/bussolabs/app/pulls")
             .with(body: hash_including("title" => "DRRA-1 Fix", "head" => "DRRA-1-fix", "base" => "main"))
             .to_return(status: 201, body: { number: 7 }.to_json)

      result = client.create_pull(
        installation_id, "bussolabs/app",
        title: "DRRA-1 Fix", head: "DRRA-1-fix", base: "main", body: "chiude il ticket"
      )

      expect(result["number"]).to eq(7)
      expect(pull).to have_been_requested
    end
  end

  describe "#repository_file" do
    it "legge e decodifica un file dal default branch" do
      stub_token
      stub_request(:get, "https://api.github.test/repos/bussolabs/app/contents/.kamal/secrets-common?ref=main")
        .to_return(status: 200, body: {
          encoding: "base64",
          content: Base64.strict_encode64("A=$A\n")
        }.to_json)

      expect(client.repository_file(installation_id, "bussolabs/app", ".kamal/secrets-common", ref: "main"))
        .to eq("A=$A\n")
    end

    it "ritorna nil quando il file non esiste" do
      stub_token
      stub_request(:get, "https://api.github.test/repos/bussolabs/app/contents/.kamal/secrets?ref=main")
        .to_return(status: 404, body: { message: "Not Found" }.to_json)

      expect(client.repository_file(installation_id, "bussolabs/app", ".kamal/secrets", ref: "main")).to be_nil
    end
  end

  describe "#git_tree" do
    it "legge l'albero ricorsivo del ref e ne ritorna le voci" do
      stub_token
      stub_request(:get, "https://api.github.test/repos/bussolabs/app/git/trees/main?recursive=1")
        .to_return(status: 200, body: {
          tree: [
            { path: "Gemfile.lock", type: "blob", sha: "aaa", size: 120 },
            { path: "web", type: "tree", sha: "bbb" }
          ]
        }.to_json)

      result = client.git_tree(installation_id, "bussolabs/app", "main")

      expect(result[:entries].map { |e| e["path"] }).to eq(%w[Gemfile.lock web])
      expect(result[:truncated]).to be(false)
    end

    it "riporta l'albero troncato invece di far credere che sia completo" do
      stub_token
      stub_request(:get, "https://api.github.test/repos/bussolabs/app/git/trees/main?recursive=1")
        .to_return(status: 200, body: { tree: [], truncated: true }.to_json)

      expect(client.git_tree(installation_id, "bussolabs/app", "main")[:truncated]).to be(true)
    end

    it "un repository senza quel ref (o vuoto) ritorna nil, non un errore" do
      stub_token
      stub_request(:get, "https://api.github.test/repos/bussolabs/app/git/trees/main?recursive=1")
        .to_return(status: 404, body: { message: "Not Found" }.to_json)

      expect(client.git_tree(installation_id, "bussolabs/app", "main")).to be_nil
    end
  end

  describe "#blob" do
    it "decodifica il contenuto per sha (via che regge i file oltre 1 MB)" do
      stub_token
      stub_request(:get, "https://api.github.test/repos/bussolabs/app/git/blobs/aaa")
        .to_return(status: 200, body: {
          encoding: "base64", content: "#{Base64.strict_encode64("GEM\n  remote: x\n")}\n"
        }.to_json)

      expect(client.blob(installation_id, "bussolabs/app", "aaa")).to eq("GEM\n  remote: x\n")
    end

    it "ritorna nil su blob inesistente" do
      stub_token
      stub_request(:get, "https://api.github.test/repos/bussolabs/app/git/blobs/zzz")
        .to_return(status: 404, body: { message: "Not Found" }.to_json)

      expect(client.blob(installation_id, "bussolabs/app", "zzz")).to be_nil
    end

    it "un encoding inatteso è un errore, non un contenuto vuoto" do
      stub_token
      stub_request(:get, "https://api.github.test/repos/bussolabs/app/git/blobs/aaa")
        .to_return(status: 200, body: { encoding: "utf-8", content: "GEM" }.to_json)

      expect { client.blob(installation_id, "bussolabs/app", "aaa") }
        .to raise_error(Github::Client::Error) { |e| expect(e.code).to eq("R502-GITHUB-001") }
    end
  end

  describe "gestione errori" do
    it "solleva Error R502 su risposta 422" do
      stub_token
      stub_request(:post, "https://api.github.test/repos/bussolabs/app/git/refs").to_return(status: 422, body: "{}")

      expect { client.create_ref(installation_id, "bussolabs/app", "refs/heads/x", "sha") }
        .to raise_error(Github::Client::Error) { |e| expect(e.code).to eq("R502-GITHUB-001") }
    end

    it "solleva Error su timeout" do
      stub_token
      stub_request(:get, "https://api.github.test/repos/bussolabs/app/git/ref/heads/main").to_timeout

      expect { client.ref(installation_id, "bussolabs/app", "heads/main") }
        .to raise_error(Github::Client::Error)
    end
  end

  describe "Environment secrets (Fase 2)" do
    let(:repository_id) { 12_345 }

    it "#environment_public_key → GET public-key con repository_id + environment" do
      stub_token
      stub_request(:get, "https://api.github.test/repositories/#{repository_id}/environments/production/secrets/public-key")
        .to_return(status: 200, body: { key_id: "kid1", key: "cHVia2V5" }.to_json)

      result = client.environment_public_key(installation_id, repository_id, "production")
      expect(result["key_id"]).to eq("kid1")
      expect(result["key"]).to eq("cHVia2V5")
    end

    it "#put_environment_secret → PUT con encrypted_value + key_id (204 senza crash)" do
      stub_token
      put = stub_request(:put, "https://api.github.test/repositories/#{repository_id}/environments/production/secrets/DATABASE_URL")
        .with(body: { encrypted_value: "enc==", key_id: "kid1" }.to_json)
        .to_return(status: 204, body: "")

      client.put_environment_secret(installation_id, repository_id, "production", "DATABASE_URL", encrypted_value: "enc==", key_id: "kid1")
      expect(put).to have_been_requested
    end

    it "#delete_environment_secret → DELETE del secret (204)" do
      stub_token
      del = stub_request(:delete, "https://api.github.test/repositories/#{repository_id}/environments/production/secrets/API_KEY")
        .to_return(status: 204, body: "")

      client.delete_environment_secret(installation_id, repository_id, "production", "API_KEY")
      expect(del).to have_been_requested
    end

    it "#delete_environment_secret treats a secret already gone from GitHub (404) as deleted" do
      stub_token
      stub_request(:delete, "https://api.github.test/repositories/#{repository_id}/environments/production/secrets/API_KEY")
        .to_return(status: 404, body: { message: "Not Found" }.to_json)

      expect { client.delete_environment_secret(installation_id, repository_id, "production", "API_KEY") }
        .not_to raise_error
    end
  end
end
