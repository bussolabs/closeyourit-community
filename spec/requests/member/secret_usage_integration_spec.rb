# frozen_string_literal: true

require "rails_helper"

# CYRA-401 — «Usa questo segreto» deve vivere nel CORPO di ogni pagina che elenca segreti (non in un
# tooltip), col comando già compilato per il contesto, e le guide devono parlare d'uso, non di
# navigazione. Questo spec blinda l'integrazione end-to-end sulle quattro pagine e sulle due guide.
RSpec.describe "Member — sezione «Usa questo segreto» (CYRA-401)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in(who)
    post login_path, params: { email: who.email, password: "Secret123!" }
  end

  describe "pagina dei secret di progetto" do
    let(:project) { create(:project, organization: org) }
    let!(:production) { create(:environment, organization: org, code: "production").tap { |e| project.environments << e } }

    it "mostra la sezione nel corpo, col comando già compilato per progetto e ambiente" do
      sign_in(owner)
      get member_project_secrets_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="secret-usage"')
      expect(response.body).to include("cyi run -p #{project.key} -e production")
      # Le tre varianti richieste dalla DoD.
      expect(response.body).to include('data-test="secret-usage-tab-server"')
      expect(response.body).to include("cyi secrets sync -p #{project.key}")
      expect(response.body).to include("CLOSEYOURIT_TOKEN")
    end
  end

  describe "pagina dei secret personali" do
    it "porta le istruzioni nel corpo (prima erano solo nel tooltip del titolo)" do
      sign_in(owner)
      get member_personal_secrets_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="secret-usage"')
      expect(response.body).to include("cyi personal run")
      expect(response.body).to include("use_cyi_personal")
      # Il tooltip non è più l'unica sede: niente più comando lì dentro.
      expect(response.body).not_to include("Iniettale in shell con")
    end
  end

  describe "pagina dei secret dell'organizzazione" do
    it "mostra la sezione e spiega di delegarli prima a un progetto" do
      sign_in(owner)
      get member_shared_secrets_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="secret-usage"')
      expect(response.body).to include('data-test="secret-usage-shared-note"')
    end
  end

  describe "panoramica del Vault" do
    before { Types::InstallDefaults.call(organization: org) }

    it "insegna il primo giro completo (crealo → delegalo → leggilo) e mostra il comando" do
      sign_in(owner)
      get member_vault_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="vault-onboarding"')
      expect(response.body).to include('data-test="vault-onboarding-create"')
      expect(response.body).to include('data-test="vault-onboarding-read"')
      expect(response.body).to include('data-test="secret-usage"')
    end
  end

  describe "guide" do
    before { create(:membership, account: member, organization: org, role: :member) }

    let(:member) { create(:account) }

    it "la guida del Vault descrive i tre passi d'uso, non più i passi di navigazione" do
      sign_in(member)
      get member_guides_vault_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("member.guides.vault.how_step3"))
      # Il terzo passo chiude sull'uso (leggere dall'app), in ogni lingua.
      expect(I18n.t("member.guides.vault.how_step3")).to match(/applicazione|application/i)
      # Non più il passo di navigazione col selettore di spazio.
      expect(response.body).not_to include("space switcher")
    end

    it "la guida dei secret dell'organizzazione chiude sull'uso" do
      sign_in(member)
      get member_guides_secrets_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("member.guides.secrets.setup_step3"))
      # Lo step finale non si ferma alla delega: arriva alla lettura dall'applicazione.
      expect(I18n.t("member.guides.secrets.setup_step3")).to match(/applicazione|application/i)
    end
  end
end
