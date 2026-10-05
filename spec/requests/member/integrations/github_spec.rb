# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Integrations::Github", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let!(:owner_m) { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  before { sign_in(owner) }

  around do |example|
    saved = ENV.to_h.slice("GH_APP_ID", "GH_APP_PRIVATE_KEY", "GH_APP_CLIENT_ID", "GH_APP_CLIENT_SECRET")
    ENV["GH_APP_ID"] = "123"
    ENV["GH_APP_PRIVATE_KEY"] = "test-key"
    ENV["GH_APP_CLIENT_ID"] = "test-client"
    ENV["GH_APP_CLIENT_SECRET"] = "test-secret"
    example.run
  ensure
    %w[GH_APP_ID GH_APP_PRIVATE_KEY GH_APP_CLIENT_ID GH_APP_CLIENT_SECRET].each { |name| saved.key?(name) ? ENV[name] = saved[name] : ENV.delete(name) }
  end

  def page = Nokogiri::HTML(response.body)

  describe "GET show" do
    it "senza installazione → link di installazione" do
      get member_integrations_github_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("github-install-link")
    end

    it "says the App is not configured on an install without GitHub (CYRA-916)" do
      ENV.delete("GH_APP_ID")
      get member_integrations_github_path

      expect(response.body).to include("github-not-configured")
      expect(response.body).not_to include("github-install-link")
    end

    it "con installazione → mostra il login GitHub" do
      create(:github_installation, organization: org, account_login: "bussolabs")

      get member_integrations_github_path

      expect(response.body).to include("bussolabs")
    end
  end

  # CYRA-581 — era l'unica pagina dell'Amministrazione costruita a mano: titolo nudo, prosa sotto,
  # nessuna briciola e nessun collegamento per uscirne, con dentro il pulsante che scollega
  # l'integrazione di tutta l'organizzazione. Chi ci arrivava non aveva modo di sapere dove fosse.
  describe "l'intestazione della pagina (CYRA-581)" do
    it "porta la briciola con l'area, e da lì si esce senza il tasto del browser" do
      get member_integrations_github_path

      # CYRA-545 — in mezzo c'è l'elenco delle Integrazioni, di cui questa pagina è una scheda:
      # senza quel livello l'unica via di ritorno sarebbe l'area intera.
      briciole = page.css('[data-test="breadcrumb"] [data-test="breadcrumb-crumb"]')
      expect(briciole.map(&:text)).to eq(
        [ I18n.t("member.nav.home"), I18n.t("member.nav.group_settings"),
          I18n.t("member.integrations.title"), I18n.t("member.integrations.github.title") ]
      )
      uscite = page.css('[data-test="breadcrumb"] a').map { |a| a["href"] }
      # CYRA-911 — Administration has no landing page: its crumb is text, not a link.
      expect(uscite).to eq([ root_path, member_integrations_path ])
    end

    it "il titolo è quello standard dell'area, non un h1 scritto a mano" do
      get member_integrations_github_path

      titolo = page.at_css("h1")
      expect(titolo.text).to eq(I18n.t("member.integrations.github.title"))
      expect(titolo["class"]).to include("text-[22px]")
    end

    it "senza installazione le chip dicono che non c'è nulla di collegato" do
      get member_integrations_github_path

      expect(page.at_css('[data-test="github-counts"]')).to be_present
      expect(page.at_css('[data-test="github-stat-status"]').text)
        .to include(I18n.t("member.integrations.github.status_missing"))
      expect(page.at_css('[data-test="github-stat-repositories"]').text).to include("0")
    end

    it "con installazione le chip contano i repository collegati" do
      installation = create(:github_installation, organization: org)
      create(:github_repository, project: create(:project, organization: org), installation:)

      get member_integrations_github_path

      expect(page.at_css('[data-test="github-stat-status"]').text)
        .to include(I18n.t("member.integrations.github.status_installed"))
      expect(page.at_css('[data-test="github-stat-repositories"]').text).to include("1")
    end

    it "nessuna prosa resta sotto il titolo: la spiegazione vive dentro la scheda" do
      get member_integrations_github_path

      intestazione = page.at_css('[data-test="github-header"]')
      expect(intestazione.at_css('[data-test="page-header-subtitle"]')).to be_nil
      expect(intestazione.text).not_to include(I18n.t("member.integrations.github.description"))
      expect(page.at_css('[data-test="github-intro"]').text).to eq(I18n.t("member.integrations.github.description"))
    end

    # A GitHub App già installata, «Installa la GitHub App…» e un bottone rosso pieno per disinstallare
    # erano l'invito e l'azione sbagliati: la descrizione dice a cosa serve, «Disinstalla» è secondario.
    it "a installazione fatta la descrizione non invita a installare e «Disinstalla» non è pieno" do
      owner.update!(locale: "it")
      create(:github_installation, organization: org, account_login: "bussolabs")

      get member_integrations_github_path

      expect(page.at_css('[data-test="github-intro"]').text).not_to start_with("Installa")
      expect(page.at_css('[data-test="github-org-disconnect"]')["class"]).not_to include("bg-red-600")
    end

    # CYRA-545 — la voce del menu non è più «GitHub App» ma «Integrazioni», l'elenco dei servizi
    # collegabili di cui questa pagina è una scheda: resta accesa su tutta l'area, questa compresa.
    it "la voce di menu dell'area risulta accesa" do
      get member_integrations_github_path

      accesa = page.css('#member-sidebar [aria-current="page"]')
      # The sidebar shows Administration as one entry; Integrations lives in its section list.
      expect(accesa.text).to include(I18n.t("member.nav.group_settings"))
    end
  end

  describe "GET callback" do
    def installation_state
      get member_integrations_github_path
      link = page.at_css('[data-test="github-install-link"]')["href"]
      URI.decode_www_form(URI(link).query).to_h.fetch("state")
    end

    def oauth_state
      state = installation_state
      get callback_member_integrations_github_path, params: { installation_id: "555", setup_action: "install", state: }
      URI.decode_www_form(URI(response.location).query).to_h.fetch("state")
    end

    it "requires a session-bound setup and verified GitHub ownership" do
      state = oauth_state
      allow(Github::Installations::Verify).to receive(:call).with(
        installation_id: "555", code: "test-code", redirect_uri: callback_member_integrations_github_url
      ).and_return(Result.ok({ "account" => { "login" => "test-owner" } }))

      get callback_member_integrations_github_path, params: { code: "test-code", state:, installation_id: "999" }

      expect(response).to redirect_to(member_integrations_github_path)
      expect(org.reload.github_installation).to have_attributes(installation_id: 555, account_login: "test-owner")
    end

    it "rejects an unbound setup redirect" do
      expect(Github::Installations::Verify).not_to receive(:call)
      get callback_member_integrations_github_path, params: { installation_id: "555", setup_action: "install" }
      expect(org.reload.github_installation).to be_nil
    end

    it "rejects an incorrect OAuth state before contacting GitHub" do
      oauth_state
      expect(Github::Installations::Verify).not_to receive(:call)
      get callback_member_integrations_github_path, params: { code: "test-code", state: "wrong" }
      expect(org.reload.github_installation).to be_nil
    end

    it "expires the flow after ten minutes" do
      state = oauth_state
      travel 11.minutes do
        expect(Github::Installations::Verify).not_to receive(:call)
        get callback_member_integrations_github_path, params: { code: "test-code", state: }
      end
      expect(org.reload.github_installation).to be_nil
    end

    it "does not retry a consumed OAuth state" do
      state = oauth_state
      expect(Github::Installations::Verify).to receive(:call).once.and_return(
        Result.err(AppError.new("Denied", code: "R403-GITHUB-001"))
      )
      # The repeated queries belong to separate HTTP requests.
      allow_n_plus_one do
        2.times { get callback_member_integrations_github_path, params: { code: "test-code", state: } }
      end
      expect(org.reload.github_installation).to be_nil
    end
  end

  describe "DELETE destroy" do
    it "disinstalla la GitHub App dell'org" do
      create(:github_installation, organization: org)

      delete member_integrations_github_path, params: { confirm: "1" }

      expect(org.reload.github_installation).to be_nil
    end
  end
end
