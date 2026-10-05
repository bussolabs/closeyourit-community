# frozen_string_literal: true

require "rails_helper"

# CYRA-799 — ogni pagina dell'area membro ereditava venticinque elenchi (`current_visible_*`) e il
# menu si prendeva in prestito diciotto metodi PRIVATI del controller con `send`. Chi scriveva una
# pagina nuova non vedeva da dove arrivasse niente. Adesso la visibilità è un oggetto che si riceve.
#
# Qui si guarda il SORGENTE: che i metodi ereditati non tornino, e che il menu non torni a prendere
# in prestito. Il comportamento lo provano l'oggetto (spec/services/authorization/
# visible_scope_resources_spec.rb), il filo (spec/controllers/member/visible_resources_spec.rb) e le
# request spec della sidebar.
RSpec.describe "La visibilità è un oggetto, non quaranta metodi ereditati", type: :model do
  # I nomi dei lettori ereditati, spariti con la migrazione. Ritrovarne uno significa che una pagina
  # ha ricominciato a chiedere al controller invece che all'oggetto.
  GRAFIE_EREDITATE = %w[current_visible_ current_pages_in_review].freeze

  it "nessun file dell'applicazione usa più i lettori ereditati" do
    tornati = Dir[Rails.root.join("app/**/*.{rb,erb}")].select do |file|
      contenuto = File.read(file)
      GRAFIE_EREDITATE.any? { |grafia| contenuto.include?(grafia) }
    end

    expect(tornati).to be_empty,
                       "Questi file chiedono ancora gli elenchi al controller: " \
                       "#{tornati.map { |f| f.sub("#{Rails.root}/", '') }.join(', ')}. " \
                       "Si chiedono a `visible` (Authorization::VisibleScope)."
  end

  # Il menu riceve i suoi collaboratori nel costruttore. `send` e `define_method` sono le due grafie
  # con cui se li prendeva da solo: la prima scavalcava il `private` del controller, la seconda ne
  # generava diciotto in un colpo senza che nessuna riga li nominasse.
  it "il menu non prende in prestito metodi dal controller" do
    sorgente = Rails.root.join("app/presenters/navigation/visibility.rb").read
    codice = sorgente.lines.reject { |riga| riga.strip.start_with?("#") }.join

    expect(codice).not_to include("define_method")
    expect(codice).not_to match(/@context|\.send\(/)
  end

  # Il concern è il filo, non l'elenco: sopra questa misura ci è tornato dentro qualcosa.
  it "il concern che lega l'oggetto alla richiesta resta corto" do
    righe = Rails.root.join("app/controllers/concerns/visible_resources.rb").readlines.size

    expect(righe).to be < 40, "app/controllers/concerns/visible_resources.rb misura #{righe} righe: " \
                              "gli elenchi vivono in Authorization::VisibleScope."
  end

  # L'oggetto sa rispondere per ogni dominio che le pagine gli chiedono: un lettore dimenticato qui
  # è una pagina che va in NoMethodError solo quando qualcuno la apre.
  it "l'oggetto risponde per ogni dominio dell'area membro" do
    scope = Authorization::VisibleScope.new(account: nil, organization: nil)

    %i[
      projects groups tickets ideas pages pages_in_review books error_groups replay_sessions
      monitors metric_groups cron_monitors logs vulnerabilities runtime_statuses
      vulnerability_manifests seo_sites seo_issues seo_pages datasets teams workload_actions
      servers uptime_groups
    ].each { |dominio| expect(scope).to respond_to(dominio) }
  end
end
