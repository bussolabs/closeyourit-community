# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Github::Webhooks handlers" do
  let(:repository) { create(:github_repository, :with_env_mapping) }
  let(:project) { repository.project }

  def repo_payload(extra = {})
    {
      "repository" => { "id" => repository.repo_id },
      "installation" => { "id" => repository.installation.installation_id }
    }.merge(extra)
  end

  describe Github::Webhooks::Push do
    it "su un tag stabile marca la release production come live" do
      release = create(:release, project:, version: "v1.0.0", environment: "production")

      described_class.call(payload: repo_payload("ref" => "refs/tags/v1.0.0"))

      expect(release.reload).to be_current
    end

    it "ignora i push di branch" do
      result = described_class.call(payload: repo_payload("ref" => "refs/heads/main"))
      expect(result.value).to be_nil
    end

    it "no-op se il payload non porta installation.id" do
      result = described_class.call(payload: { "repository" => { "id" => repository.repo_id }, "ref" => "refs/tags/v1.0.0" })
      expect(result.value).to be_nil
    end

    it "no-op se installation.id non corrisponde a nessuna installazione nel DB" do
      result = described_class.call(payload: repo_payload("installation" => { "id" => 999_999 }, "ref" => "refs/tags/v1.0.0"))
      expect(result.value).to be_nil
    end

    it "no-op se il repo_id non è agganciato a nessun progetto dentro quell'installazione" do
      result = described_class.call(payload: repo_payload("repository" => { "id" => 987_654 }, "ref" => "refs/tags/v1.0.0"))
      expect(result.value).to be_nil
    end

    # CYRA-722 — un'organizzazione sospesa non lavora: le consegne di GitHub continuano ad arrivare
    # (l'app resta installata) ma non muovono più niente dentro il prodotto.
    it "no-op se l'organizzazione del repo è sospesa" do
      release = create(:release, project:, version: "v1.0.0", environment: "production")
      repository.installation.organization.update!(suspended_at: Time.current)

      result = described_class.call(payload: repo_payload("ref" => "refs/tags/v1.0.0"))

      expect(result.value).to be_nil
      expect(release.reload).not_to be_current
    end

    it "no-op se sync è disabilitato" do
      repository.update!(sync_enabled: false)
      release = create(:release, project:, version: "v1.0.0", environment: "production")

      described_class.call(payload: repo_payload("ref" => "refs/tags/v1.0.0"))

      expect(release.reload).not_to be_current
    end
  end

  describe Github::Webhooks::Create do
    it "su ref_type tag pre-release marca la release staging come live" do
      release = create(:release, project:, version: "v1.0.0-beta", environment: "staging")

      described_class.call(payload: repo_payload("ref_type" => "tag", "ref" => "v1.0.0-beta"))

      expect(release.reload).to be_current
    end

    it "un branch senza codice ticket viene registrato senza collegarlo (Fase 2)" do
      result = described_class.call(payload: repo_payload("ref_type" => "branch", "ref" => "feature"))
      expect(result.value.ticket).to be_nil
    end
  end

  describe Github::Webhooks::Release do
    it "su release published arricchisce con l'URL e marca live" do
      release = create(:release, project:, version: "v2.0.0", environment: "production")

      described_class.call(payload: repo_payload(
        "action" => "published",
        "release" => { "tag_name" => "v2.0.0", "html_url" => "https://github.com/bussolabs/app/releases/tag/v2.0.0" }
      ))

      expect(release.reload).to be_current
      expect(release.git_tag_url).to eq("https://github.com/bussolabs/app/releases/tag/v2.0.0")
    end

    it "ignora le release non published" do
      result = described_class.call(payload: repo_payload("action" => "created", "release" => { "tag_name" => "v2.0.0" }))
      expect(result.value).to be_nil
    end
  end

  describe Github::Webhooks::Installation do
    it "su action deleted rimuove installazione e repo agganciati" do
      installation = repository.installation

      described_class.call(payload: { "action" => "deleted", "installation" => { "id" => installation.installation_id } })

      expect(Github::Installation.exists?(installation.id)).to be(false)
      expect(Github::Repository.exists?(repository.id)).to be(false)
    end

    it "ignora le altre action" do
      installation = create(:github_installation)

      described_class.call(payload: { "action" => "suspend", "installation" => { "id" => installation.installation_id } })

      expect(Github::Installation.exists?(installation.id)).to be(true)
    end
  end
end
