require "rails_helper"

RSpec.describe Accounts::Account, type: :model do
  describe "factory" do
    it "produce un account valido" do
      expect(build(:account)).to be_valid
    end
  end

  describe "validazioni email" do
    it "richiede email" do
      account = build(:account, email: nil)
      expect(account).not_to be_valid
      expect(account.errors[:email]).to be_present
    end

    it "rifiuta email vuota" do
      expect(build(:account, email: "")).not_to be_valid
    end

    it "rifiuta email di soli spazi" do
      expect(build(:account, email: "   ")).not_to be_valid
    end

    it "rifiuta un formato email non valido" do
      expect(build(:account, email: "non-una-email")).not_to be_valid
    end

    it "impedisce email duplicate" do
      create(:account, email: "dup@example.com")
      expect(build(:account, email: "dup@example.com")).not_to be_valid
    end

    it "tratta le email come case-insensitive (normalize downcase)" do
      create(:account, email: "User@Example.com")
      expect(build(:account, email: "user@example.com")).not_to be_valid
    end
  end

  describe "validazioni name" do
    it "richiede name" do
      expect(build(:account, name: nil)).not_to be_valid
    end

    it "rifiuta name di soli spazi" do
      expect(build(:account, name: "   ")).not_to be_valid
    end
  end

  describe "normalizzazioni" do
    it "abbassa e trimma l'email" do
      account = create(:account, email: "  Mixed@Example.COM  ")
      expect(account.email).to eq("mixed@example.com")
    end

    it "trimma il name" do
      account = create(:account, name: "  Ada  ")
      expect(account.name).to eq("Ada")
    end
  end

  describe "god" do
    it "ha default false" do
      expect(build(:account).god).to be(false)
    end
  end

  describe "autenticazione (has_secure_password)" do
    it "autentica con la password corretta" do
      account = create(:account, password: "Secret123!")
      expect(account.authenticate("Secret123!")).to be_truthy
    end

    it "fallisce con la password errata" do
      account = create(:account, password: "Secret123!")
      expect(account.authenticate("sbagliata")).to be(false)
    end

    it "richiede la password alla creazione" do
      expect(build(:account, password: nil)).not_to be_valid
    end
  end

  describe "policy password (min 8 + 4 classi)" do
    it "valida con maiuscola, minuscola, numero e speciale (8 char)" do
      expect(build(:account, password: "Aa1!aaaa")).to be_valid
    end

    it "rifiuta password di 7 caratteri anche con tutte le classi" do
      account = build(:account, password: "Aa1!aaa")
      expect(account).not_to be_valid
      expect(account.errors[:password]).to be_present
    end

    it "rifiuta senza maiuscola" do
      expect(build(:account, password: "secret123!")).not_to be_valid
    end

    it "rifiuta senza minuscola" do
      expect(build(:account, password: "SECRET123!")).not_to be_valid
    end

    it "rifiuta senza numero" do
      expect(build(:account, password: "Secret!!!")).not_to be_valid
    end

    it "rifiuta senza carattere speciale" do
      expect(build(:account, password: "Secret123")).not_to be_valid
    end

    it "rifiuta quando la conferma non combacia" do
      account = build(:account, password: "Secret123!", password_confirmation: "Diversa123!")
      expect(account).not_to be_valid
      expect(account.errors[:password_confirmation]).to be_present
    end

    it "non rivalida la policy se la password non viene impostata" do
      account = create(:account).reload
      account.name = "Nuovo Nome"
      expect(account).to be_valid
    end
  end

  describe "associazioni con le organizzazioni" do
    let(:account) { create(:account) }

    it "nessuna organizzazione di default (0)" do
      expect(account.organizations).to be_empty
    end

    it "una organizzazione via membership (1)" do
      org = create(:organization)
      create(:membership, account: account, organization: org)
      expect(account.organizations).to contain_exactly(org)
    end

    it "più organizzazioni via membership (N)" do
      orgs = create_list(:organization, 3)
      orgs.each { |o| create(:membership, account: account, organization: o) }
      expect(account.organizations).to match_array(orgs)
    end

    it "distrugge le membership quando l'account è eliminato" do
      org = create(:organization)
      create(:membership, account: account, organization: org)
      expect { account.destroy }.to change(Connections::Membership, :count).by(-1)
    end

    it "nullifica i log link creati quando l'account è eliminato (audit preservato)" do
      link = create(:log_link, created_by: account)
      account.destroy
      expect(link.reload.created_by_id).to be_nil
    end

    it "azzera l'assegnatario di default dei progetti quando l'account è eliminato (entità preservata)" do
      org = create(:organization)
      create(:membership, account: account, organization: org)
      project = create(:project, organization: org, default_assignee: account)
      account.destroy
      expect(project.reload.default_assignee_id).to be_nil
    end
  end

  describe "token di reset password" do
    it "ritrova l'account da un token valido" do
      account = create(:account)
      token = account.generate_token_for(:password_reset)
      expect(Accounts::Account.find_by_token_for(:password_reset, token)).to eq(account)
    end

    it "ritorna nil su token non valido" do
      expect(Accounts::Account.find_by_token_for(:password_reset, "spazzatura")).to be_nil
    end

    it "invalida il token dopo il cambio password" do
      account = create(:account)
      token = account.generate_token_for(:password_reset)
      account.update!(password: "Nuova-password1!")
      expect(Accounts::Account.find_by_token_for(:password_reset, token)).to be_nil
    end

    it "scade dopo la TTL" do
      account = create(:account)
      token = account.generate_token_for(:password_reset)
      travel_to(Accounts::Constants::TTL_PASSWORD_RESET.from_now + 1.second) do
        expect(Accounts::Account.find_by_token_for(:password_reset, token)).to be_nil
      end
    end

    it "genera un token anche senza password_digest (safe-nav sul digest nil)" do
      # Esercita il ramo else di `password_digest&.last(10)` quando il digest è nil.
      account = Accounts::Account.new
      expect { account.generate_token_for(:password_reset) }.not_to raise_error
    end
  end

  describe "preferenza projects_view (store_accessor su preferences jsonb)" do
    it "è nil di default" do
      expect(build(:account).projects_view).to be_nil
    end

    it "accetta 'cards'" do
      expect(build(:account, projects_view: "cards")).to be_valid
    end

    it "accetta 'table'" do
      expect(build(:account, projects_view: "table")).to be_valid
    end

    it "accetta nil (nessuna preferenza)" do
      expect(build(:account, projects_view: nil)).to be_valid
    end

    it "rifiuta un valore fuori dall'insieme ammesso" do
      account = build(:account, projects_view: "kanban")
      expect(account).not_to be_valid
      expect(account.errors[:projects_view]).to be_present
    end

    it "persiste la scelta nella colonna jsonb" do
      account = create(:account, projects_view: "table")
      expect(account.reload.projects_view).to eq("table")
      expect(account.reload.preferences).to include("projects_view" => "table")
    end
  end

  describe "preferenza locale (store_accessor su preferences jsonb)" do
    it "è nil di default" do
      expect(build(:account).locale).to be_nil
    end

    it "accetta 'en'" do
      expect(build(:account, locale: "en")).to be_valid
    end

    it "accetta 'it'" do
      expect(build(:account, locale: "it")).to be_valid
    end

    it "accetta nil (nessuna preferenza)" do
      expect(build(:account, locale: nil)).to be_valid
    end

    it "rifiuta una lingua fuori dall'insieme ammesso" do
      account = build(:account, locale: "fr")
      expect(account).not_to be_valid
      expect(account.errors[:locale]).to be_present
    end

    it "persiste la scelta nella colonna jsonb" do
      account = create(:account, locale: "it")
      expect(account.reload.locale).to eq("it")
      expect(account.reload.preferences).to include("locale" => "it")
    end
  end

  describe "#effective_locale" do
    it "restituisce la preferenza quando ammessa" do
      expect(build(:account, locale: "it").effective_locale).to eq("it")
    end

    it "ricade sul default I18n quando la preferenza è nil" do
      expect(build(:account, locale: nil).effective_locale).to eq(I18n.default_locale)
    end

    it "ricade sul default I18n quando la preferenza non è ammessa" do
      # locale bypassa la validazione scrivendo direttamente nel jsonb: effective_locale è la rete
      # di sicurezza per dati storici/non validati.
      account = build(:account)
      account.preferences["locale"] = "fr"
      expect(account.effective_locale).to eq(I18n.default_locale)
    end
  end

  describe "handle (per le @menzioni)" do
    it "genera un handle dalla parte locale dell'email quando non impostato" do
      account = create(:account, email: "mario.rossi@example.com", handle: nil)
      expect(account.handle).to eq("mario_rossi")
    end

    it "normalizza l'handle (downcase + trim)" do
      account = create(:account, handle: "  Mario_R  ")
      expect(account.handle).to eq("mario_r")
    end

    it "rifiuta un handle con caratteri non ammessi" do
      account = build(:account, handle: "mario rossi!")
      expect(account).not_to be_valid
      expect(account.errors[:handle]).to be_present
    end

    it "impedisce handle duplicati" do
      create(:account, handle: "mario")
      expect(build(:account, handle: "mario")).not_to be_valid
    end

    it "deduplica l'handle generato con suffisso numerico" do
      create(:account, email: "sam@a.com", handle: nil)            # → sam
      second = create(:account, email: "sam@b.com", handle: nil)   # → sam1
      expect(second.handle).to eq("sam1")
    end
  end

  describe "collegamento Telegram" do
    it "#connected_telegram? è falso senza chat_id, vero con chat_id" do
      expect(build(:account, telegram_chat_id: nil).connected_telegram?).to be(false)
      expect(build(:account, telegram_chat_id: "123456").connected_telegram?).to be(true)
    end

    # Il collegamento via deep-link /start usa ora Accounts::TelegramLinkCode (codice corto monouso),
    # non più generates_token_for :telegram_link (238 char, non valido nel parametro `start` Telegram):
    # emissione/consumo/scadenza sono coperti da spec/models/accounts/telegram_link_code_spec.rb.
  end

  describe "kind (human/service)" do
    it "è human di default" do
      account = build(:account)
      expect(account).to be_human
      expect(account).not_to be_service
    end

    it "riconosce un service account col trait" do
      account = build(:account, :service)
      expect(account).to be_service
      expect(account).not_to be_human
    end

    it "un service account col trait è valido" do
      expect(build(:account, :service)).to be_valid
    end

    it "espone gli scope human e service" do
      human = create(:account)
      service = create(:account, :service)
      expect(Accounts::Account.human).to include(human)
      expect(Accounts::Account.human).not_to include(service)
      expect(Accounts::Account.service).to include(service)
      expect(Accounts::Account.service).not_to include(human)
    end

    describe "god riservato agli umani" do
      it "un account umano può essere god" do
        expect(build(:account, god: true)).to be_valid
      end

      it "un service account non può essere god" do
        account = build(:account, :service, god: true)
        expect(account).not_to be_valid
        expect(account.errors[:god]).to be_present
      end
    end
  end


  describe "#board_collapsed_statuses (colonne board ridotte, preferenza personale — CYRA-390)" do
    it "di default è una lista vuota" do
      expect(build(:account).board_collapsed_statuses).to eq([])
    end

    it "conserva i codici stato assegnati" do
      account = build(:account, board_collapsed_statuses: %w[resolved closed])
      expect(account.board_collapsed_statuses).to eq(%w[resolved closed])
    end

    it "scarta i valori vuoti e deduplica" do
      account = build(:account, board_collapsed_statuses: [ "resolved", "", "resolved", nil, "closed" ])
      expect(account.board_collapsed_statuses).to eq(%w[resolved closed])
    end

    it "porta uno scalare a lista" do
      expect(build(:account, board_collapsed_statuses: "resolved").board_collapsed_statuses).to eq(%w[resolved])
    end

    it "ricorda la scelta tra i caricamenti" do
      account = create(:account)
      account.update!(board_collapsed_statuses: %w[closed])
      expect(account.reload.board_collapsed_statuses).to eq(%w[closed])
    end

    it "non è configurata finché non si scrive la preferenza (default: concluse ridotte)" do
      expect(build(:account).board_columns_configured?).to be(false)
    end

    it "risulta configurata dopo aver scritto la preferenza, anche vuota" do
      account = create(:account)
      account.update!(board_collapsed_statuses: [])
      expect(account.reload.board_columns_configured?).to be(true)
    end
  end
end
