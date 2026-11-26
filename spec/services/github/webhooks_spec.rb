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
      result = described_class.call(payload: repo_payload("ref" => "refs/heads/feature"))
      expect(result.value).to be_nil
    end

    # CYRA-1154 — main moved: the delivered proposals still waiting are checked against it.
    describe "push to the default branch" do
      let(:in_review) { create(:ticket_status, :in_review, organization: project.organization) }
      let(:ticket) do
        create(:ticket, organization: project.organization, project:, status: in_review, with_agent_workflow: true)
      end
      let!(:candidate) { delivered_waiting!(ticket:, repository:, number: 7) }

      def push(ref: "refs/heads/main", extra: {})
        described_class.call(payload: repo_payload({ "ref" => ref, "after" => "e" * 40,
                                                     "commits" => [ { "message" => "Rename the login form" } ] }
                                                   .merge(extra)))
      end

      it "creates a check per delivered proposal, with the titles from the delivery" do
        expect { push }.to have_enqueued_job(Agents::ConflictCheckJob)

        expect(Agents::ConflictCheck.sole).to have_attributes(delivery_candidate_id: candidate.id, main_sha: "e" * 40,
                                                              main_titles: [ "Rename the login form" ])
      end

      it "creates a single check when GitHub delivers the same push twice" do
        2.times { push }

        expect(Agents::ConflictCheck.count).to eq(1)
      end

      it "starts no check for a push to another branch" do
        expect(push(ref: "refs/heads/feature").value).to be_nil
        expect(Agents::ConflictCheck.count).to eq(0)
        expect(ticket.agent_workflow.reload.phase).to eq("awaiting_autopilot_approval")
      end

      it "starts no check when sync is off or the branch was deleted" do
        repository.update!(sync_enabled: false)
        push
        repository.update!(sync_enabled: true)
        push(extra: { "deleted" => true })

        expect(Agents::ConflictCheck.count).to eq(0)
      end
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
