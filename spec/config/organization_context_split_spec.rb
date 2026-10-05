# frozen_string_literal: true

require "rails_helper"

# CYRA-740 — il modulo che ogni pagina dell'area utenti si porta dietro era diventato il posto in cui
# finiva tutto: la risoluzione dell'organizzazione, i permessi, gli elenchi visibili di ogni dominio e
# la visibilità di ogni voce di menu, in seicento righe. Una pagina che deve solo sapere in quale
# organizzazione si trova caricava anche le regole della cassaforte, del SEO e degli avvisi.
#
# Qui si guarda il SORGENTE, non il comportamento: che le parti esistano davvero e che il modulo
# condiviso non se le sia riprese. Le prove di comportamento restano quelle del menu
# (spec/helpers/member/navigation_helper_spec.rb, spec/requests/member/customer_navigation_spec.rb) e
# le unit dei singoli moduli, che sono la rete vera di questa divisione.
RSpec.describe "Il contesto condiviso da ogni pagina non fa tutto", type: :model do
  # Il tetto della Definition of Done. Non è un numero estetico: sopra questa misura il modulo torna a
  # essere quello che ogni pagina paga per intero, che è esattamente il problema.
  let(:tetto_righe) { 80 }
  let(:context_path) { Rails.root.join("app/controllers/concerns/organization_context.rb") }
  # Solo le righe di CODICE: un commento che NOMINA il menu o i permessi è memoria utile e resta
  # dov'è; quello che non deve tornare qui è la regola scritta di nuovo.
  let(:codice) { context_path.readlines.reject { |riga| riga.strip.start_with?("#") } }

  it "il modulo condiviso sta sotto le ottanta righe" do
    righe = context_path.readlines.size

    expect(righe).to be < tetto_righe,
                     "app/controllers/concerns/organization_context.rb misura #{righe} righe " \
                     "(tetto #{tetto_righe}): quello che è tornato dentro va nella parte che ha quel compito."
  end

  # Le tre parti nominate dal ticket, ciascuna con il proprio compito: chi cambia un permesso apre i
  # permessi, chi cambia una voce di menu apre il menu, chi cambia un elenco visibile apre gli elenchi.
  it "ogni parte estratta esiste ed è caricabile" do
    expect(defined?(PermissionGates)).to eq("constant")
    expect(defined?(VisibleResources)).to eq("constant")
    expect(defined?(NavigationVisibility)).to eq("constant")
    expect(defined?(Navigation::Visibility)).to eq("constant")
  end

  # Le grafie che dicono «la regola è tornata nel modulo condiviso». Non sono divieti di stile: ognuna
  # è il cuore di una delle parti estratte, e ritrovarla qui significa che ne esistono di nuovo due copie.
  {
    "la visibilità delle voci di menu" => [ "_nav_visible?", "customer_content_gate" ],
    "gli elenchi visibili dei domini" => [ "helper_method :visible", "VisibleScope" ],
    "i permessi e la conferma delle azioni pericolose" =>
      [ "require_permission!", "Authorization::Resolver", "DangerousActionConfirmation" ]
  }.each do |compito, grafie|
    it "il modulo condiviso non riscrive più #{compito}" do
      tornate = grafie.select { |grafia| codice.any? { |riga| riga.include?(grafia) } }

      expect(tornate).to be_empty,
                         "Queste grafie sono tornate nel modulo condiviso: #{tornate.join(', ')}. " \
                         "Vivono nella parte che ha quel compito, non qui."
    end
  end

  # Il presenter è la ragione per cui la divisione non costa niente: la barra laterale interroga la
  # stessa istanza per tutte le voci, quindi le condizioni si valutano una volta per pagina aperta.
  it "la visibilità del menu è UN oggetto solo per richiesta" do
    controller = Member::MembersController.new
    controller.set_request!(ActionDispatch::TestRequest.create)

    expect(controller.send(:navigation_visibility)).to be(controller.send(:navigation_visibility))
  end
end
