require "rails_helper"

RSpec.describe Secrets::Variables::Delete do
  describe ".call" do
    it "elimina la variabile e ritorna Result.ok" do
      variable = create(:secret_variable)

      expect do
        result = described_class.call(variable:)
        expect(result).to be_ok
      end.to change(Secrets::Variable, :count).by(-1)
    end

    it "accoda la notifica di cancellazione con i dati SNAPSHOTTATI (mai la variabile, già distrutta)" do
      variable = create(:secret_variable, name: "API_KEY")
      actor = create(:account)
      project = variable.project
      environment_label = variable.environment.label
      variable_id = variable.id

      expect { described_class.call(variable:, actor:) }
        .to have_enqueued_job(Secrets::Notifications::DeletedNotifyJob)
        .with(project_id: project.id, variable_id: variable_id, name: "API_KEY",
              environment_label: environment_label, actor_id: actor.id)
    end

    it "senza attore, accoda comunque la notifica con actor_id nil" do
      variable = create(:secret_variable)

      expect { described_class.call(variable:) }
        .to have_enqueued_job(Secrets::Notifications::DeletedNotifyJob).with(hash_including(actor_id: nil))
    end
  end
end
