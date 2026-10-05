# frozen_string_literal: true

require "rails_helper"

# CYRA-416: delegare e revocare decidono chi legge un segreto. La revoca passa da una conferma legata
# allo stato visto a schermo; se quello stato è cambiato, la richiesta va respinta invece di applicare
# una revoca decisa su premesse vecchie.
RSpec.describe "Member shared secret delegations", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:environment) { create(:environment, organization:, code: "production") }
  let(:project) { create(:project, organization:) }

  before do
    create(:membership, account: owner, organization:, role: :owner)
    create(:membership, account: member, organization:, role: :member)
    create(:project_environment, project:, environment:)
  end

  def sign_in(account) = post(login_path, params: { email: account.email, password: "Secret123!" })

  let(:shared_value) do
    Secrets::Shared::Save.call(organization:, environment:, name: "api_key", value: "secret").value
  end
  let(:variable) { shared_value.shared_variable }

  def delegate! = Secrets::Shared::Delegate.call(shared_value:, project:)

  describe "POST create" do
    it "delega il segreto al progetto e lo conferma" do
      sign_in(owner)

      post member_shared_secret_delegations_path(variable),
           params: { confirm: "1", value_id: shared_value.id, project_id: project.id }

      expect(response).to redirect_to(member_shared_secrets_path)
      expect(shared_value.reload.projects).to include(project)
    end

    it "è negata a chi non ha il permesso" do
      sign_in(member)

      post member_shared_secret_delegations_path(variable),
           params: { value_id: shared_value.id, project_id: project.id }

      expect(response).to redirect_to(root_path)
      expect(shared_value.reload.projects).not_to include(project)
    end
  end

  describe "DELETE destroy" do
    it "con la conferma giusta toglie la delega" do
      delegate!
      delegation = shared_value.reload.delegations.first
      digest = Secrets::Shared::Impact.call(shared_value:, effect: :unlink).value["digest"]
      sign_in(owner)

      delete member_shared_secret_delegation_path(variable, delegation),
             params: { confirm: "1", confirmation_digest: digest }

      expect(response).to redirect_to(member_shared_secrets_path)
      expect(Secrets::Shared::Delegation.where(id: delegation.id)).not_to exist
    end

    it "con una conferma obsoleta avvisa e lascia la delega dov'è" do
      delegate!
      delegation = shared_value.reload.delegations.first
      sign_in(owner)

      delete member_shared_secret_delegation_path(variable, delegation),
             params: { confirm: "1", confirmation_digest: "vecchio-digest" }

      expect(response).to redirect_to(member_shared_secrets_path)
      expect(flash[:alert]).to be_present
      expect(Secrets::Shared::Delegation.where(id: delegation.id)).to exist
    end
  end
end
