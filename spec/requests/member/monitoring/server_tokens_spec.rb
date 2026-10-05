# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Monitoring::ServerTokens", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }

  before do
    create(:membership, account: owner, organization: organization, role: :owner)
    create(:membership, account: member, organization: organization, role: :member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET index" do
    it "owner → 200 con la lista" do
      create(:server_enrollment_token, organization: organization, name: "fleet")
      sign_in(owner)

      get member_monitoring_server_tokens_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("fleet")
    end

    it "member senza servers.manage → redirect (forbidden)" do
      sign_in(member)
      get member_monitoring_server_tokens_path
      expect(response).to redirect_to(root_path)
    end

    # CYRA-469 — DoD: quante macchine usano ciascun codice, ed è possibile vederle.
    it "mostra quante macchine sono collegate a ciascun codice, con link alla flotta filtrata" do
      token = create(:server_enrollment_token, organization: organization, name: "fleet")
      create(:server_host, organization: organization, enrollment_token: token)
      create(:server_host, organization: organization, enrollment_token: token)
      sign_in(owner)

      get member_monitoring_server_tokens_path

      cell = Nokogiri::HTML(response.body).at_css(%([data-test="server-token-servers-#{token.id}"]))
      expect(cell).to be_present
      expect(cell.text.strip).to include("2")
      expect(cell["href"]).to eq(member_monitoring_servers_path(enrollment_token: token.id))
    end

    it "non conta le macchine registrate con un altro codice" do
      token = create(:server_enrollment_token, organization: organization, name: "fleet")
      other = create(:server_enrollment_token, organization: organization, name: "altro")
      create(:server_host, organization: organization, enrollment_token: other)
      sign_in(owner)

      get member_monitoring_server_tokens_path

      # Nessun host su "fleet" → non è cliccabile (nessun link alla flotta filtrata per fleet).
      expect(response.body).not_to include(member_monitoring_servers_path(enrollment_token: token.id))
    end

    # CYRA-469 — DoD: indicata la scadenza, o scritto esplicitamente che non scade.
    it "dichiara che i codici non scadono" do
      create(:server_enrollment_token, organization: organization)
      sign_in(owner)

      get member_monitoring_server_tokens_path

      expect(response.body).to include(I18n.t("member.servers.tokens.never_expires"))
    end

    # CYRA-469 Scenario 2: la colonna della data dice cosa misura davvero (l'enrollment, non il push).
    it "intitola la colonna della data «Ultima registrazione», senza il gergo «enrollment»" do
      create(:server_enrollment_token, organization: organization)
      sign_in(owner)

      get member_monitoring_server_tokens_path

      expect(response.body).to include(I18n.t("member.servers.tokens.col_last_enrollment"))
      expect(I18n.t("member.servers.tokens.col_last_enrollment", locale: :it)).to eq("Ultima registrazione")
    end

    it "sotto il titolo i conteggi dei codici, non un paragrafo" do
      create(:server_enrollment_token, organization: organization, name: "attivo")
      create(:server_enrollment_token, organization: organization, name: "vecchio", revoked_at: 1.day.ago)
      sign_in(owner)

      get member_monitoring_server_tokens_path

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='server-tokens-stat-active']").text.squish).to start_with("1 ")
      expect(doc.at_css("[data-test='server-tokens-stat-revoked']").text.squish).to start_with("1 ")
    end

    # CYRA-469 — DoD: la pagina spiega cosa fare se un codice viene compromesso.
    it "spiega cosa fare con un codice compromesso" do
      sign_in(owner)

      get member_monitoring_server_tokens_path

      expect(response.body).to include("data-test=\"server-tokens-compromised\"")
      expect(response.body).to include(I18n.t("member.servers.tokens.compromised_body"))
    end
  end

  describe "POST create" do
    it "crea il token e mostra il segreto UNA volta (reveal-once, mai in DB)" do
      sign_in(owner)

      expect { post member_monitoring_server_tokens_path, params: { confirm: "1", name: "fleet" } }
        .to change(Servers::EnrollmentToken, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(response.body).to include("server-token-reveal")
      secret = response.body[/cyi_s_[A-Za-z0-9]+/]
      expect(secret).to be_present
      expect(Servers::EnrollmentToken.last.token_digest).to eq(Digest::SHA256.hexdigest(secret))

      # il segreto non ricompare al reload
      get member_monitoring_server_tokens_path
      expect(response.body).not_to include(secret)
    end

    it "nome duplicato → 422 con errori" do
      create(:server_enrollment_token, organization: organization, name: "fleet")
      sign_in(owner)

      post member_monitoring_server_tokens_path, params: { name: "fleet" }

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  # CYRA-469 Scenario 1: non si scollega la flotta con un clic distratto — serve la conferma scritta.
  describe "DELETE destroy" do
    it "con il nome digitato correttamente revoca (soft)" do
      token = create(:server_enrollment_token, organization: organization, name: "fleet")
      sign_in(owner)

      delete member_monitoring_server_token_path(token), params: { confirm: "fleet" }

      expect(token.reload.revoked?).to be(true)
      expect(response).to redirect_to(member_monitoring_server_tokens_path)
    end

    it "senza conferma NON revoca e lo dice" do
      token = create(:server_enrollment_token, organization: organization, name: "fleet")
      sign_in(owner)

      delete member_monitoring_server_token_path(token), params: { confirm: "1" }

      expect(token.reload.revoked?).to be(false)
      expect(flash[:alert]).to eq(I18n.t("member.servers.tokens.revoke_denied"))
    end

    it "con una conferma che non combacia NON revoca" do
      token = create(:server_enrollment_token, organization: organization, name: "fleet")
      sign_in(owner)

      delete member_monitoring_server_token_path(token), params: { confirm: "sbagliato" }

      expect(token.reload.revoked?).to be(false)
      expect(flash[:alert]).to eq(I18n.t("member.servers.tokens.revoke_denied"))
    end

    it "annuncia quante macchine erano collegate" do
      token = create(:server_enrollment_token, organization: organization, name: "fleet")
      create(:server_host, organization: organization, enrollment_token: token)
      sign_in(owner)

      delete member_monitoring_server_token_path(token), params: { confirm: "fleet" }

      expect(flash[:notice]).to eq(I18n.t("member.servers.tokens.revoked", count: 1))
    end

    it "token di un'altra org → 404 (anti-BOLA)" do
      other = create(:server_enrollment_token, name: "fleet")
      sign_in(owner)

      delete member_monitoring_server_token_path(other), params: { confirm: "fleet" }

      expect(response).to have_http_status(:not_found)
      expect(other.reload.revoked?).to be(false)
    end
  end
end
