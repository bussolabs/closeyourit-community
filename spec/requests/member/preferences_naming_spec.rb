# frozen_string_literal: true

require "rails_helper"

# CYRA-338 — gli scenari del ticket, provati sulle pagine vere.
#
# «Impostazioni» era il nome della pagina delle preferenze personali E dell'area che governa
# l'organizzazione. Chi cercava dove cambiare la propria lingua poteva finire in un'area che ha
# effetti su tutto il team. Qui si verifica quello che una persona legge davvero: la voce da cui si
# parte, il titolo su cui si arriva, e che i due nomi non si somiglino più.
RSpec.describe "Preferenze e Amministrazione (CYRA-338)", type: :request do
  let(:org) { create(:organization, name: "Demo") }
  # Italiano esplicito: la lingua di default dell'app è l'inglese, e il rilievo nasce dai nomi italiani.
  let(:owner) { create(:account, locale: "it") }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  # Metodo, non `let`: gli esempi che seguono un collegamento leggono DUE pagine e un
  # documento memoizzato resterebbe fermo alla prima.
  def doc
    Nokogiri::HTML(response.body)
  end

  def titolo
    doc.at_css("h1").text.strip
  end

  def voce_preferenze
    doc.at_css("[data-test='member-nav-preferences']")
  end

  it "Scenario 1: la voce del menu dice «Preferenze» e apre la pagina delle preferenze" do
    get root_path
    expect(voce_preferenze.text.strip).to eq("Preferenze")

    # Seconda richiesta nello stesso esempio: le query di layout (sessione, account, org) si
    # ripetono per pagina e non sono un N+1 di produzione.
    allow_n_plus_one { get voce_preferenze["href"] }

    expect(response.request.path).to eq(member_preferences_path)
    expect(titolo).to eq("Preferenze")
  end

  it "Scenario 1: la lingua si cambia lì, senza entrare nell'amministrazione" do
    get member_preferences_path

    expect(response.body).to include('data-test="preferences-row-language"')
    expect(response.body).to include('data-test="preferences-locale-en"')
    expect(titolo).to eq("Preferenze")
  end

  it "Scenario 2: nella stessa schermata le due aree portano nomi diversi" do
    get root_path

    personale = voce_preferenze.text.strip
    organizzazione = doc.at_css("[data-test='member-nav-settings']").text.strip

    expect(personale).to eq("Preferenze")
    expect(organizzazione).to eq("Amministrazione")
    expect([ personale, organizzazione ]).not_to include("Impostazioni")
  end

  it "Scenario 2: la pagina personale si presenta come «Preferenze»" do
    get member_preferences_path

    expect(titolo).to eq("Preferenze")
  end

  it "Scenario 2: l'area dell'organizzazione si presenta come «Amministrazione»" do
    get member_settings_path

    expect(titolo).to eq("Amministrazione")
  end

  # Le tre pagine dell'area si aprono dalle schede in cima: se una si presentasse con un altro nome,
  # cambiando scheda sembrerebbe di aver cambiato area.
  %i[member_preferences_path member_notification_preferences_path member_telegram_connection_path].each do |scheda|
    it "la scheda #{scheda} dell'area personale si presenta come «Preferenze»" do
      get send(scheda)

      expect(titolo).to eq("Preferenze")
    end
  end

  # La prima scheda non può ripetere il nome dell'area: si leggerebbe «Preferenze › Preferenze».
  it "la prima scheda dell'area non ripete il nome dell'area" do
    get member_preferences_path

    expect(doc.at_css("[data-test='settings-tab-display']").text.strip).to eq("Generali")
  end
end
