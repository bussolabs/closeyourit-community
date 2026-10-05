# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Account::Cli::Tokens (configurazione)", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  before { create(:membership, account:, organization:) }

  def sign_in_as(acc)
    post login_path, params: { email: acc.email, password: "Secret123!" }
  end

  it "senza login → redirect a /login" do
    get account_cli_tokens_path
    expect(response).to redirect_to(login_path)
  end

  it "lista i propri token ed esclude quelli di altri account" do
    sign_in_as(account)
    mine = create(:api_token, account:, organization:, name: "Mio Mac")
    other = create(:api_token)

    get account_cli_tokens_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("account-cli-tokens-row-#{mine.id}")
    expect(response.body).not_to include("account-cli-tokens-row-#{other.id}")
    expect(response.body).to include("Mio Mac")
  end

  it "stato vuoto se nessun token" do
    sign_in_as(account)
    get account_cli_tokens_path
    expect(response.body).to include('data-test="account-cli-tokens-empty"')
  end

  # CYRA-685 — la tinta canonica del «positivo» è emerald (211 usi contro 19): green era la deriva.
  it "badge stato attivo e bottone revoca usano i token red/emerald del design system" do
    sign_in_as(account)
    create(:api_token, account:, organization:, name: "Mio Mac")

    get account_cli_tokens_path

    expect(response.body).to include("bg-emerald-50")
    expect(response.body).to include("text-emerald-700")
    expect(response.body).to include("text-red-600")
    expect(response.body).to include("hover:bg-red-50")
    # Le classi, non la parola: il body contiene anche il nome dell'account, che Faker genera a
    # caso — un "Ambrose" qualsiasi contiene "rose" e faceva fallire il test senza colpa della view.
    expect(response.body).not_to match(/-(green|rose)-\d/)
  end

  # CYRA-717 — la pagina deve dire QUANDO un token smette di valere, e distinguere "scaduto" da
  # "revocato": sono due cose diverse da fare (rifare login vs. non farci più conto).
  describe "colonna scadenza" do
    it "mostra la data di scadenza e i giorni residui di un token che sta per scadere" do
      sign_in_as(account)
      create(:api_token, :expiring_soon, account:, organization:, name: "Mio Mac")

      get account_cli_tokens_path

      expect(response.body).to include('data-test="account-cli-tokens-expiry"')
      expect(response.body).to include(I18n.t("account.cli_tokens.expiry.due_in_days", count: 3))
    end

    it "un token senza scadenza lo dice invece di lasciare la cella vuota" do
      sign_in_as(account)
      create(:api_token, account:, organization:, expires_at: nil)

      get account_cli_tokens_path

      expect(response.body).to include(I18n.t("account.cli_tokens.expiry.never"))
    end

    it "un token scaduto ha il badge Scaduto, distinguibile da quello grigio dei revocati" do
      sign_in_as(account)
      create(:api_token, :expired, account:, organization:, name: "Vecchio Mac")

      get account_cli_tokens_path

      expect(response.body).to include(I18n.t("account.cli_tokens.status_expired"))
      expect(response.body).to include(Ui::BadgeComponent::COLORS.fetch(:red)[:box])
      expect(response.body).not_to include(I18n.t("account.cli_tokens.status_revoked"))
    end

    it "ordina per scadenza (?sort=expiry)" do
      sign_in_as(account)
      create(:api_token, account:, organization:, name: "Tardi", expires_at: 60.days.from_now)
      create(:api_token, account:, organization:, name: "Presto", expires_at: 2.days.from_now)

      get account_cli_tokens_path, params: { sort: "expiry" }
      expect(response.body.index("Presto")).to be < response.body.index("Tardi")

      get account_cli_tokens_path, params: { sort: "-expiry" }
      expect(response.body.index("Tardi")).to be < response.body.index("Presto")
    end
  end

  it "revoca un proprio token" do
    sign_in_as(account)
    token = create(:api_token, account:, organization:)

    delete account_cli_token_path(token)

    expect(response).to redirect_to(account_cli_tokens_path)
    expect(token.reload.revoked?).to be(true)
  end

  it "ordina i propri token per nome (?sort=name) asc/desc" do
    sign_in_as(account)
    create(:api_token, account:, organization:, name: "Zed laptop")
    create(:api_token, account:, organization:, name: "alfa laptop")

    get account_cli_tokens_path, params: { sort: "name" }
    expect(response.body.index("alfa laptop")).to be < response.body.index("Zed laptop")

    get account_cli_tokens_path, params: { sort: "-name" }
    expect(response.body.index("Zed laptop")).to be < response.body.index("alfa laptop")
  end

  describe "lettura dell'elenco" do
    before { sign_in_as(account) }

    it "i token attivi vengono prima dei revocati, che non servono più a niente" do
      create(:api_token, account:, organization:, name: "Vecchio revocato", revoked_at: 1.day.ago)
      create(:api_token, account:, organization:, name: "Mac in uso")

      get account_cli_tokens_path
      expect(response.body.index("Mac in uso")).to be < response.body.index("Vecchio revocato")
    end

    it "l'ultimo uso si legge nel formato data delle altre pagine, non ISO" do
      used_at = Time.zone.local(2026, 7, 12, 2, 8)
      create(:api_token, account:, organization:, last_used_at: used_at)

      get account_cli_tokens_path
      expect(response.body).to include(I18n.l(used_at, format: :default))
      expect(response.body).not_to include("2026-07-12 02:08")
    end

    it "il conteggio in testa dice che conta gli attivi, non le righe della tabella" do
      create(:api_token, account:, organization:)
      create(:api_token, account:, organization:, revoked_at: 1.day.ago)

      get account_cli_tokens_path
      expect(response.body).to include(I18n.t("account.cli_tokens.active_count", count: 1))
    end
  end
  # CYRA-924 — delete asks in a dialog that names the thing, never in the browser box (F16, C77).
  describe "delete confirmation (dialog)" do
    it "opens a dialog that sends the revoke" do
      sign_in_as(account)
      token = create(:api_token, account:, organization:, name: "Mio Mac")

      get account_cli_tokens_path

      html = Nokogiri::HTML(response.body)
      dialog = html.at_css("dialog[data-test='account-cli-tokens-revoke-dialog-#{token.id}']")
      expect(dialog.text).to include(I18n.t("account.cli_tokens.revoke_dialog.title", name: "Mio Mac"))
      expect(dialog.at_css("form")["action"]).to eq(account_cli_token_path(token))
      expect(dialog.at_css("input[name='confirm']")["value"]).to eq("1")
      expect(html.at_css("[data-test='account-cli-tokens-revoke-#{token.id}']")["data-action"]).to eq("ui--dialog#open")
      expect(response.body).not_to include("data-turbo-confirm")
    end
  end
end
