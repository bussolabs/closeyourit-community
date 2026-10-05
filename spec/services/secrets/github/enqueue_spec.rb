require "rails_helper"

# Enqueue del push sync dai service di mutazione (dopo il commit) quando il progetto ha un repo GitHub
# con sync_secrets attivo.
RSpec.describe "Secrets::Github enqueue del sync" do
  let(:repository) { create(:github_repository, :with_env_mapping, sync_secrets: true) }
  let(:project) { repository.project }
  let(:environment) { repository.production_environment }

  describe "Secrets::Variables::Set" do
    it "enfila SyncJob per il repo quando sync_secrets è on" do
      expect { Secrets::Variables::Set.call(project:, environment:, name: "A", value: "1") }
        .to have_enqueued_job(Secrets::Github::SyncJob).with(github_repository_id: repository.id)
    end

    it "non enfila se il progetto non ha un repo GitHub" do
      other = create(:project)
      env = create(:environment, organization: other.organization).tap { |e| other.environments << e }

      expect { Secrets::Variables::Set.call(project: other, environment: env, name: "A", value: "1") }
        .not_to have_enqueued_job(Secrets::Github::SyncJob)
    end

    it "non enfila se sync_secrets è off" do
      repository.update_column(:sync_secrets, false)

      expect { Secrets::Variables::Set.call(project:, environment:, name: "A", value: "1") }
        .not_to have_enqueued_job(Secrets::Github::SyncJob)
    end
  end

  describe "Secrets::Variables::Delete" do
    it "enfila SyncJob dopo l'eliminazione" do
      variable = Secrets::Variables::Set.call(project:, environment:, name: "A", value: "1", enqueue_sync: false).value

      expect { Secrets::Variables::Delete.call(variable:) }
        .to have_enqueued_job(Secrets::Github::SyncJob).with(github_repository_id: repository.id)
    end
  end

  describe "Secrets::Variables::Import" do
    it "enfila SyncJob UNA sola volta per l'intero bulk" do
      entries = [ { name: "A", value: "1" }, { name: "B", value: "2" } ]

      expect { Secrets::Variables::Import.call(project:, environment:, entries:) }
        .to have_enqueued_job(Secrets::Github::SyncJob).exactly(1).times
    end
  end
end
