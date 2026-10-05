# frozen_string_literal: true

require "rails_helper"

# CYRA-727 — la rete che pretende, da ogni pagina dell'area utenti, un gate o un motivo scritto.
# Si esercita su un controller di prova costruito qui: quelli veri sono tutti in regola, e una prova
# che ne usasse uno diventerebbe rossa il giorno in cui quel controller cambia gate per motivi suoi.
RSpec.describe Member::PermissionDeclaration do
  subject(:controller) do
    istanza = classe_di_prova.new
    istanza.set_request!(ActionDispatch::TestRequest.create)
    istanza.set_response!(classe_di_prova.make_response!(istanza.request))
    istanza.instance_variable_set(:@_action_name, "index")
    istanza
  end

  let(:classe_di_prova) do
    Class.new(Member::BaseController) do
      def self.name = "Member::PaginaDiProvaController"
    end
  end

  def verifica! = controller.send(:verify_permission_declared)

  it "una pagina che non chiede niente e non dichiara niente fa fallire le prove" do
    expect { verifica! }.to raise_error(described_class::NotDeclared, /PaginaDiProvaController#index/)
  end

  it "l'errore dice cosa fare, non solo cosa manca" do
    expect { verifica! }.to raise_error(/require_permission!.*permission_not_required/m)
  end

  it "una pagina che interroga un permesso passa" do
    controller.send(:note_permission_check!)
    expect { verifica! }.not_to raise_error
  end

  it "una pagina che esce prima di sapere su cosa gatare passa" do
    controller.send(:nothing_to_authorize!)
    expect { verifica! }.not_to raise_error
  end

  it "un motivo scritto per tutto il controller passa" do
    classe_di_prova.permission_not_required "Casella personale: ognuno vede e gestisce le proprie."
    expect { verifica! }.not_to raise_error
  end

  it "un motivo scritto per un'ALTRA azione non copre questa" do
    classe_di_prova.permission_not_required "Sola lettura del proprio profilo.", only: :show
    expect { verifica! }.to raise_error(described_class::NotDeclared)
  end

  it "il motivo si eredita dalla base: chi la estende non deve riscriverlo" do
    classe_di_prova.permission_not_required "Le azioni le autorizza il service che le esegue."
    figlia = Class.new(classe_di_prova) { def self.name = "Member::FigliaDiProvaController" }
    expect(figlia.permission_exemptions).to eq(classe_di_prova.permission_exemptions)
  end

  it "un motivo scritto nella figlia non torna indietro alla base" do
    figlia = Class.new(classe_di_prova) { def self.name = "Member::FigliaDiProvaController" }
    figlia.permission_not_required "Solo per la figlia, e solo qui."
    expect(classe_di_prova.permission_exemptions).to be_empty
  end

  # Il caso per cui esiste la "finestra": la barra laterale interroga can? per ogni voce di menu a
  # ogni pagina. Se quelle domande contassero, ogni pagina risulterebbe controllata per il solo fatto
  # di essersi disegnata, e questa rete non prenderebbe mai niente.
  it "quello che la vista chiede DOPO il render non vale come gate" do
    controller.render(plain: "una pagina qualsiasi")
    controller.send(:note_permission_check!)
    expect { verifica! }.to raise_error(described_class::NotDeclared)
  end

  it "in produzione lascia un warn e non chiude in faccia la pagina a nessuno" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
    allow(Rails.logger).to receive(:warn)

    expect { verifica! }.not_to raise_error
    expect(Rails.logger).to have_received(:warn).with(/CYRA-727 .*PaginaDiProvaController#index/)
  end
end
