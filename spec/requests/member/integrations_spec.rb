# frozen_string_literal: true

require "rails_helper"

# CYRA-545 — LA PAGINA DA CUI UN'ORGANIZZAZIONE COLLEGA I PROPRI SERVIZI ESTERNI.
#
# Fino a qui le credenziali per-organizzazione esistevano (CYRA-544) ma non c'era una schermata da
# cui incollarle: si scrivevano da console o si adottavano quelle dell'operatore. Chi amministra
# vedeva funzioni spente e nessun posto dove accenderle.
#
# Le tre cose che questa pagina deve garantire, e che qui sotto sono presidiate una per una: la
# chiave si prova NEL MOMENTO in cui la si incolla (una chiave storta non si scopre più tardi come
# una funzione che tace); non si rilegge MAI (il campo resta vuoto, si sostituisce); e salvare senza
# toccarla non la cancella.
RSpec.describe "Member::Integrations", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def page = Nokogiri::HTML(response.body)

  def accetta_la_chiave
    allow(Integrations::Verify).to receive(:call).and_return(Result.ok(nil))
  end

  def rifiuta_la_chiave(outcome = Integrations::Verify::INVALID_KEY)
    errore = AppError.new(I18n.t("integrations.errors.#{outcome}"),
                          code: "R422-INTEGRATION-001", status: :unprocessable_content,
                          details: { outcome: outcome })
    allow(Integrations::Verify).to receive(:call).and_return(Result.err(errore))
  end

  # Scenario 1 — la voce si vede solo a chi amministra.
  describe "chi può aprirla" do
    it "senza sessione porta all'accesso" do
      get member_integrations_path

      expect(response).to redirect_to(login_path)
    end

    it "chi amministra l'organizzazione la apre" do
      sign_in(owner)

      get member_integrations_path

      expect(response).to have_http_status(:ok)
      expect(page.at_css('[data-test="member-integrations"]')).to be_present
    end

    it "chi non amministra viene respinto anche scrivendo l'indirizzo a mano" do
      sign_in(member)

      get member_integrations_path

      expect(response).to redirect_to(root_path)
    end

    it "la voce del menu compare a chi amministra e non agli altri" do
      sign_in(owner)
      get member_members_path
      expect(page.at_css('[data-test="admin-nav"] [data-test="member-nav-integrations"]')).to be_present

      sign_in(member)
      get member_tickets_path
      expect(page.at_css('#member-sidebar [data-test="member-nav-integrations"]')).to be_nil
    end

    it "chi non amministra non può nemmeno collegare o scollegare" do
      credential = create(:integration_credential, organization: org, provider: "pagespeed")
      sign_in(member)

      patch member_integration_path("pagespeed"), params: { api_key_pagespeed: "chiave-nuova" }
      expect(response).to redirect_to(root_path)

      expect { delete member_integration_path("pagespeed") }.not_to change(Integrations::Credential, :count)
      expect(credential.reload).to be_present
    end
  end

  # Scenario 4 — la briciola di pane dice dove sei.
  describe "l'intestazione della pagina" do
    before { sign_in(owner) }

    it "il titolo è quello standard dell'area, non un h1 scritto a mano" do
      get member_integrations_path

      titolo = page.at_css("h1")
      expect(titolo.text).to eq(I18n.t("member.integrations.title"))
      expect(titolo["class"]).to include("text-[22px]")
    end

    # Collegato e «da controllare» non si escludono: una chiave che c'è ma non ha superato l'ultima
    # prova conta in tutte e due le chip, e sono due domande diverse.
    it "le chip contano i servizi, quelli collegati e quelli da controllare" do
      create(:integration_credential, :broken, organization: org, provider: "pagespeed")

      get member_integrations_path

      expect(page.at_css('[data-test="integrations-counts"]')).to be_present
      expect(page.at_css('[data-test="integrations-stat-services"]').text).to include("2")
      expect(page.at_css('[data-test="integrations-stat-connected"]').text).to include("1")
      expect(page.at_css('[data-test="integrations-stat-broken"]').text).to include("1")
    end

    it "nel menu si apre l'Amministrazione, e la voce risulta accesa" do
      get member_integrations_path

      # CYRA-911 — Administration is one sidebar entry; the page's own section list marks Integrations.
      expect(page.css('#member-sidebar [aria-current="page"]').text).to include(I18n.t("member.nav.group_settings"))
      expect(page.css('[data-test="admin-nav"] [aria-current="page"]').text).to include(I18n.t("member.nav.integrations"))
    end
  end

  describe "l'elenco dei servizi" do
    before { sign_in(owner) }

    it "ogni servizio dice a cosa serve, cosa accende e dove si prende la chiave" do
      get member_integrations_path

      Integrations::Providers.all.each do |provider|
        scheda = page.at_css(%([data-test="integration-card-#{provider.key}"]))
        expect(scheda).to be_present, "manca la scheda di #{provider.key}"
        expect(scheda.text).to include(provider.label)
        expect(scheda.text).to include(provider.summary)
        expect(scheda.text).to include(provider.where)
        provider.features.each do |feature|
          expect(scheda.text).to include(I18n.t("integrations.features.#{feature}"))
        end
      end
    end

    it "GitHub è l'altro servizio, in sola lettura, e porta alla sua pagina" do
      get member_integrations_path

      scheda = page.at_css('[data-test="integration-card-github"]')
      expect(scheda).to be_present
      expect(scheda.at_css("form")).to be_nil
      expect(scheda.at_css('a[href="/member/integrations/github"]')).to be_present
    end

    it "la chiave non si rilegge mai: campo di tipo password e sempre vuoto" do
      create(:integration_credential, :verified, organization: org, provider: "pagespeed", api_key: "chiave-segreta")

      get member_integrations_path

      campo = page.at_css('[data-test="integration-key-pagespeed"]')
      expect(campo["type"]).to eq("password")
      expect(campo["value"].to_s).to eq("")
      expect(response.body).not_to include("chiave-segreta")
    end

    it "un servizio la cui ultima prova è fallita lo dice, col motivo" do
      create(:integration_credential, :broken, organization: org, provider: "pagespeed")

      get member_integrations_path

      stato = page.at_css('[data-test="integration-status-pagespeed"]')
      expect(stato.text).to include(I18n.t("member.integrations.status_broken"))
      expect(page.at_css('[data-test="integration-card-pagespeed"]').text)
        .to include(I18n.t("integrations.errors.invalid_key"))
    end
  end

  # Scenario 2 — una chiave sbagliata viene bocciata sul momento.
  describe "collegare un servizio" do
    before { sign_in(owner) }

    it "la chiave buona viene provata e salvata come verificata" do
      accetta_la_chiave

      expect do
        patch member_integration_path("pagespeed"), params: { confirm: "1", api_key_pagespeed: "  chiave-buona  " }
      end.to change(Integrations::Credential, :count).by(1)

      expect(Integrations::Verify).to have_received(:call).with(provider: "pagespeed", api_key: "chiave-buona")
      credential = org.integration_credentials.find_by(provider: "pagespeed")
      expect(credential.api_key).to eq("chiave-buona")
      expect(credential).to be_verified
      expect(credential.connected_by).to eq(owner)
      expect(response).to redirect_to(member_integrations_path)
    end

    it "la chiave rifiutata non viene salvata, e la pagina lo dice subito" do
      rifiuta_la_chiave

      expect do
        patch member_integration_path("pagespeed"), params: { confirm: "1", api_key_pagespeed: "chiave-storta" }
      end.not_to change(Integrations::Credential, :count)

      expect(flash[:alert]).to eq(I18n.t("integrations.errors.invalid_key"))
      expect(Integrations::Resolve.connected?(organization: org, provider: "pagespeed")).to be(false)
    end

    it "la chiave rifiutata non butta via quella che funzionava" do
      create(:integration_credential, :verified, organization: org, provider: "pagespeed", api_key: "chiave-di-prima")
      rifiuta_la_chiave

      patch member_integration_path("pagespeed"), params: { api_key_pagespeed: "chiave-storta" }

      credential = org.integration_credentials.find_by(provider: "pagespeed")
      expect(credential.api_key).to eq("chiave-di-prima")
      expect(credential).to be_verified
    end

    it "un servizio che non esiste non collega niente" do
      accetta_la_chiave

      expect do
        patch member_integration_path("inventato"), params: { confirm: "1", api_key_inventato: "chiave" }
      end.not_to change(Integrations::Credential, :count)

      expect(response).to redirect_to(member_integrations_path)
      expect(Integrations::Verify).not_to have_received(:call)
    end
  end

  # Scenario 3 — salvare senza toccare il campo non cancella la chiave.
  describe "il campo lasciato vuoto" do
    before { sign_in(owner) }

    it "non azzera la chiave esistente e non chiama il fornitore" do
      credential = create(:integration_credential, :verified, organization: org,
                                                              provider: "pagespeed", api_key: "chiave-di-prima")
      allow(Integrations::Verify).to receive(:call)

      patch member_integration_path("pagespeed"), params: { confirm: "1", api_key_pagespeed: "   " }

      expect(credential.reload.api_key).to eq("chiave-di-prima")
      expect(credential).to be_verified
      expect(Integrations::Verify).not_to have_received(:call)
      expect(response).to redirect_to(member_integrations_path)
    end

    it "su un servizio mai collegato dice che senza chiave non c'è niente da collegare" do
      allow(Integrations::Verify).to receive(:call)

      expect do
        patch member_integration_path("pagespeed"), params: { confirm: "1", api_key_pagespeed: "" }
      end.not_to change(Integrations::Credential, :count)

      expect(flash[:alert]).to be_present
      expect(Integrations::Verify).not_to have_received(:call)
    end
  end

  # Scenario 5 — scollegando si legge cosa si spegne.
  describe "scollegare un servizio" do
    before { sign_in(owner) }

    it "prima di confermare la pagina elenca cosa smette di funzionare" do
      create(:integration_credential, :verified, organization: org, provider: "pagespeed")

      get member_integrations_path

      bottone = page.at_css('[data-test="integration-disconnect-pagespeed"]')
      expect(bottone).to be_present
      conferma = bottone["data-turbo-confirm"]
      expect(conferma).to be_present
      Integrations::Providers.find("pagespeed").features.each do |feature|
        expect(conferma).to include(I18n.t("integrations.features.#{feature}"))
      end
    end

    it "confermando, il servizio risulta non collegato" do
      create(:integration_credential, :verified, organization: org, provider: "pagespeed")

      expect do
        delete member_integration_path("pagespeed"), params: { confirm: "1" }
      end.to change(Integrations::Credential, :count).by(-1)

      expect(Integrations::Resolve.connected?(organization: org, provider: "pagespeed")).to be(false)
      expect(response).to redirect_to(member_integrations_path)
    end

    it "scollegare due volte non fa esplodere la pagina" do
      delete member_integration_path("pagespeed"), params: { confirm: "1" }

      expect(response).to redirect_to(member_integrations_path)
    end

    # La chiave è dell'organizzazione: quella di un'altra non si tocca nemmeno conoscendo il servizio.
    it "non tocca la chiave di un'altra organizzazione" do
      altra = create(:organization)
      credential = create(:integration_credential, organization: altra, provider: "pagespeed")

      delete member_integration_path("pagespeed")

      expect(credential.reload).to be_present
    end
  end
end
