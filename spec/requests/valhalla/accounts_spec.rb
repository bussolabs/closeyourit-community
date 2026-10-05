# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Valhalla::Accounts", type: :request do
  let(:god) { create(:account, god: true) }

  # CYRA-170: il god in Valhalla passa dal 2FA (sign_in_god lo attiva al volo + completa il 2° fattore).
  before { sign_in_god(god) }

  describe "GET /valhalla/accounts" do
    it "risponde 200" do
      create_list(:account, 2)
      get valhalla_accounts_path
      expect(response).to have_http_status(:ok)
    end

    it "filtra per query" do
      create(:account, email: "needle@example.com", name: "Needle")
      get valhalla_accounts_path, params: { q: "needle" }
      expect(response.body).to include("needle@example.com")
    end

    it "filtra per ruolo della membership (solo admin)" do
      admin = create(:account, email: "admin-role@example.com")
      create(:membership, account: admin, role: :admin)
      member = create(:account, email: "member-role@example.com")
      create(:membership, account: member, role: :member)

      get valhalla_accounts_path, params: { role: [ "admin" ] }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("admin-role@example.com")
      expect(response.body).not_to include("member-role@example.com")
    end

    it "il chip in testa conta tutti gli account, non solo quelli della pagina" do
      create_list(:account, App::Constants::TABLE_PER_PAGE + 1)

      get valhalla_accounts_path

      chip = Nokogiri::HTML(response.body).at_css('[data-test="accounts-count-accounts"]')
      expect(chip.text).to include(Accounts::Account.count.to_s)
    end

    it "mostra il ruolo tradotto, non la chiave interna" do
      god.update!(locale: "it")
      create(:membership, account: create(:account), role: :customer)

      get valhalla_accounts_path

      rows = Nokogiri::HTML(response.body).css('[data-test="valhalla-account-row"]').map(&:text).join
      expect(rows).to include(I18n.t("valhalla.accounts.roles.customer", locale: :it))
      expect(rows).not_to match(/\bcustomer\b/)
    end

    it "pagina i risultati (seconda pagina)" do
      create_list(:account, App::Constants::TABLE_PER_PAGE + 1)

      get valhalla_accounts_path, params: { page: 2 }

      expect(response).to have_http_status(:ok)
      # (TABLE_PER_PAGE + 1) account + il god loggato = TABLE_PER_PAGE + 2 → pagina 2 ha 2 righe.
      expect(response.body.scan('data-test="valhalla-account-row"').size).to eq(2)
    end

    it "sort=account (LOWER name) asc/desc" do
      create(:account, name: "zeta admin", email: "z@sort.test")
      create(:account, name: "Alfa admin", email: "a@sort.test")

      get valhalla_accounts_path, params: { sort: "account" }
      expect(response.body.index("Alfa admin")).to be < response.body.index("zeta admin")

      get valhalla_accounts_path, params: { sort: "-account" }
      expect(response.body.index("zeta admin")).to be < response.body.index("Alfa admin")
    end

    it "sort convive col filtro ruolo (subselect, niente DISTINCT)" do
      z = create(:account, name: "Zed one", email: "zed@sort.test")
      create(:membership, account: z, role: :admin)
      a = create(:account, name: "Ann two", email: "ann@sort.test")
      create(:membership, account: a, role: :admin)

      get valhalla_accounts_path, params: { role: [ "admin" ], sort: "account" }
      expect(response).to have_http_status(:ok)
      expect(response.body.index("Ann two")).to be < response.body.index("Zed one")
    end
  end

  describe "GET /valhalla/accounts/new" do
    it "risponde 200" do
      get new_valhalla_account_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /valhalla/accounts" do
    it "crea un account con password" do
      expect {
        post valhalla_accounts_path, params: { name: "Bob", email: "bob@example.com", password: "Secret123!", password_confirmation: "Secret123!" }
      }.to change(Accounts::Account, :count).by(1)
      expect(response).to redirect_to(valhalla_accounts_path)
    end

    it "con self_password crea senza password digitata e invia il reset" do
      expect {
        post valhalla_accounts_path, params: { name: "Carol", email: "carol@example.com", self_password: "1" }
      }.to change(Accounts::Account, :count).by(1)
        .and have_enqueued_mail(Auth::PasswordsMailer, :reset)
      expect(Accounts::Account.find_by(email: "carol@example.com")).to be_present
    end

    it "password debole → 422" do
      post valhalla_accounts_path, params: { name: "X", email: "x@example.com", password: "weak", password_confirmation: "weak" }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "edit / update" do
    it "edit risponde 200" do
      get edit_valhalla_account_path(create(:account))
      expect(response).to have_http_status(:ok)
    end

    it "update modifica i dati" do
      account = create(:account, name: "Old")
      patch valhalla_account_path(account), params: { name: "New", email: account.email }
      expect(response).to redirect_to(valhalla_accounts_path)
      expect(account.reload.name).to eq("New")
    end

    it "update con email non valida → 422 render edit" do
      account = create(:account, email: "valid@example.com")
      patch valhalla_account_path(account), params: { name: "X", email: "" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(account.reload.email).to eq("valid@example.com")
    end
  end

  describe "PATCH toggle_god" do
    it "attiva il flag god" do
      account = create(:account, god: false)
      patch toggle_god_valhalla_account_path(account)
      expect(account.reload).to be_god
    end

    it "non sul proprio account (resta invariato)" do
      patch toggle_god_valhalla_account_path(god)
      expect(response).to redirect_to(valhalla_accounts_path)
      expect(god.reload).to be_god
    end
  end

  describe "POST reset_password" do
    it "accoda l'email di reset" do
      account = create(:account)
      expect { post reset_password_valhalla_account_path(account) }
        .to have_enqueued_mail(Auth::PasswordsMailer, :reset)
    end
  end

  describe "DELETE destroy" do
    it "elimina l'account" do
      account = create(:account)
      expect { delete valhalla_account_path(account) }.to change(Accounts::Account, :count).by(-1)
    end

    it "FK RESTRICT residua (InvalidForeignKey) → alert pulito, nessun 500 (rescue)" do
      account = create(:account)
      allow_any_instance_of(Accounts::Account).to receive(:destroy).and_raise(ActiveRecord::InvalidForeignKey)

      delete valhalla_account_path(account)

      expect(response).to redirect_to(valhalla_accounts_path)
    end

    it "non elimina il proprio account" do
      god
      expect { delete valhalla_account_path(god) }.not_to change(Accounts::Account, :count)
      expect(response).to redirect_to(valhalla_accounts_path)
    end

    it "elimina un account con metadati 'creato da' → FK nullificate" do
      account = create(:account)
      org = create(:organization)
      org.update_column(:created_by_id, account.id)

      expect { delete valhalla_account_path(account) }.to change(Accounts::Account, :count).by(-1)
      expect(org.reload.created_by_id).to be_nil
    end

    # CYRA-746 — le `has_many` di solo metadato non stanno più sull'account: il nullify lo fa la
    # chiave esterna. Qui si guarda proprio quel passaggio, su un campione delle aree potate — chi
    # ha creato, chi ha assegnato di default, chi era l'attore di un evento — perché è l'unico punto
    # in cui la rimozione potrebbe essersi portata via un comportamento invece di una riga inutile.
    it "elimina un account che è 'creato da', 'assegnatario di default' e attore → tutte le FK nullificate" do
      account = create(:account)
      org = create(:organization)
      progetto = create(:project, organization: org)
      ruolo = create(:role, organization: org)
      invito = create(:invitation, organization: org)
      evento = create(:authorization_event, organization: org, actor: account, true_actor: account)
      org.update_columns(created_by_id: account.id, default_assignee_id: account.id)
      progetto.update_columns(created_by_id: account.id, default_assignee_id: account.id)
      ruolo.update_column(:created_by_id, account.id)
      invito.update_column(:invited_by_id, account.id)

      expect { delete valhalla_account_path(account) }.to change(Accounts::Account, :count).by(-1)

      expect(org.reload).to have_attributes(created_by_id: nil, default_assignee_id: nil)
      expect(progetto.reload).to have_attributes(created_by_id: nil, default_assignee_id: nil)
      expect(ruolo.reload.created_by_id).to be_nil
      expect(invito.reload.invited_by_id).to be_nil
      # L'evento di autorizzazione sopravvive senza attore: è audit, non si cancella con chi l'ha fatto.
      expect(evento.reload).to have_attributes(actor_id: nil, true_actor_id: nil)
    end

    it "NON elimina un account coinvolto in impersonation → audit preservato, alert pulito" do
      god_actor = create(:account)
      target = create(:account)
      Accounts::ImpersonationEvent.create!(god: god_actor, account: target, started_at: Time.current)

      expect { delete valhalla_account_path(target) }.not_to change(Accounts::Account, :count)
      expect(flash[:alert]).to eq(I18n.t("valhalla.accounts.cannot_delete"))
      # l'evento di impersonation NON viene distrutto (no evidence tampering)
      expect(Accounts::ImpersonationEvent.where(account_id: target.id)).to be_present
    end

    it "NON elimina un account che ha segnalato ticket (restrict) e mostra un alert pulito" do
      reporter = create(:ticket).reporter

      expect { delete valhalla_account_path(reporter) }.not_to change(Accounts::Account, :count)
      expect(flash[:alert]).to eq(I18n.t("valhalla.accounts.cannot_delete"))
    end
  end

  context "come account non-god" do
    before do
      delete logout_path
      member = create(:account, god: false)
      post login_path, params: { email: member.email, password: "Secret123!" }
    end

    it "non accede alla lista (redirect home)" do
      get valhalla_accounts_path
      expect(response).to redirect_to(root_path)
    end
  end
  # CYRA-924 — delete asks in a dialog that names the thing, never in the browser box (F16, C77).
  describe "delete confirmation (dialog)" do
    it "opens a dialog that sends the delete" do
      account = create(:account, name: "Mario Rossi")

      get valhalla_accounts_path

      html = Nokogiri::HTML(response.body)
      dialog = html.at_css("dialog[data-test='valhalla-account-delete-dialog-#{account.id}']")
      expect(dialog.text).to include(I18n.t("valhalla.accounts.delete_dialog.title", name: "Mario Rossi"))
      expect(dialog.at_css("form")["action"]).to eq(valhalla_account_path(account))
      expect(dialog.at_css("input[name='confirm']")["value"]).to eq("1")
      expect(dialog.ancestors.first.at_css("[data-test='valhalla-account-delete']")["data-action"]).to eq("ui--dialog#open")
      expect(response.body).not_to include("data-turbo-confirm")
    end
  end
end
