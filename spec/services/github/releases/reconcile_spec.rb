# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::Releases::Reconcile do
  let(:repository) { create(:github_repository, :with_env_mapping) }
  let(:project) { repository.project }

  def reconcile(version:, environment:, git_tag_url: nil)
    described_class.call(project: project, version: version, environment: environment, git_tag_url: git_tag_url)
  end

  context "tag stabile sull'environment di produzione" do
    it "marca la release come current, fissa deployed_at e salva l'URL del tag" do
      release = create(:release, project: project, version: "v1.0.0", environment: "production")

      result = reconcile(version: "v1.0.0", environment: "production",
                         git_tag_url: "https://github.com/bussolabs/app/releases/tag/v1.0.0")

      expect(result).to be_ok
      expect(release.reload).to be_current
      expect(release.deployed_at).to be_present
      expect(release.git_tag_url).to eq("https://github.com/bussolabs/app/releases/tag/v1.0.0")
    end
  end

  context "tag stabile ma environment staging" do
    it "non marca nulla (il target di uno stabile è production)" do
      release = create(:release, project: project, version: "v1.0.0", environment: "staging")

      reconcile(version: "v1.0.0", environment: "staging")

      expect(release.reload).not_to be_current
    end
  end

  context "tag pre-release su staging" do
    it "marca la release staging come current" do
      release = create(:release, project: project, version: "v1.0.0-beta", environment: "staging")

      reconcile(version: "v1.0.0-beta", environment: "staging")

      expect(release.reload).to be_current
    end
  end

  context "release assente (deploy non ancora arrivato)" do
    it "è no-op e ritorna ok(nil)" do
      result = reconcile(version: "v9.9.9", environment: "production")

      expect(result).to be_ok
      expect(result.value).to be_nil
    end
  end

  context "tag_binding disabilitato" do
    it "non marca nulla" do
      repository.update!(tag_binding_enabled: false)
      release = create(:release, project: project, version: "v1.0.0", environment: "production")

      reconcile(version: "v1.0.0", environment: "production")

      expect(release.reload).not_to be_current
    end
  end

  context "progetto senza repo agganciato" do
    it "è no-op" do
      result = described_class.call(project: create(:project), version: "v1.0.0", environment: "production")

      expect(result.value).to be_nil
    end
  end

  context "una nuova release live per environment" do
    it "azzera la current precedente (indice parziale unico)" do
      old = create(:release, project: project, version: "v1.0.0", environment: "production",
                             current: true, deployed_at: 1.day.ago)
      fresh = create(:release, project: project, version: "v1.1.0", environment: "production")

      reconcile(version: "v1.1.0", environment: "production")

      expect(fresh.reload).to be_current
      expect(old.reload).not_to be_current
    end
  end

  context "idempotenza" do
    it "richiamata due volte lascia la release current senza errori" do
      release = create(:release, project: project, version: "v1.0.0", environment: "production")

      reconcile(version: "v1.0.0", environment: "production")
      expect { reconcile(version: "v1.0.0", environment: "production") }.not_to raise_error

      expect(release.reload).to be_current
    end
  end
end
