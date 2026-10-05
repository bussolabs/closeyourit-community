# frozen_string_literal: true

require "rails_helper"

# CYRA-602 — un nome solo per ogni momento della lavorazione.
#
# Prima lo stesso momento si chiamava in tre modi a un clic di distanza: «Work stalled» nell'elenco
# delle decisioni, «Run stopped» nella scheda della decisione, «Run blocked» nella scheda del ticket.
# In italiano coincidevano per fortuna, non per costruzione.
#
# Ma il valore vero di questa lavorazione non è la pulizia: è la porta che resta chiusa. Se domani
# nasce una fase e nessuno le dà una parola, la suite diventa rossa — invece di stampare il nome
# interno del passaggio su una pagina italiana, che è quello che succedeva.
RSpec.describe Agents::Workflows::PhaseResolver, "il vocabolario dei passaggi" do
  # Le fasi non le dichiara un elenco: le produce la catena, e l'elenco deve inseguirla. Se la
  # leggessimo da una costante, una fase nuova aggiunta al codice passerebbe inosservata — che è
  # esattamente il difetto.
  #
  # Si legge SOLO il corpo del metodo che produce le fasi. Nello stesso file vive un altro
  # vocabolario — la fase reclamabile dalla coda, che dice "triage" e "planner" — e leggerlo insieme
  # farebbe fallire questo spec su una cosa che non c'entra: una spia accesa per il motivo sbagliato.
  def fasi_prodotte_da(file, metodo)
    sorgente = File.read(Rails.root.join(file))
    corpo = sorgente[/^(\s*)def #{metodo}\b.*?^\1end$/m]
    raise "metodo #{metodo} non trovato in #{file}" if corpo.nil?

    corpo.scan(/"([a-z_]+)"/).flatten.uniq
  end

  let(:dalla_catena) do
    fasi_prodotte_da("app/services/agents/workflows/phase_resolver.rb", "phase\\(workflow")
  end

  it "l'elenco copre tutte le fasi che la catena può restituire" do
    expect(dalla_catena).not_to be_empty
    expect(dalla_catena - described_class::PHASES).to eq([])
  end

  # CYRA-796 — la catena sta in un posto solo. Prima era ricopiata dentro Workflow#phase, ventidue
  # rami in cui l'ORDINE è la regola, e tenerli allineati era un lavoro a mano presidiato da spec:
  # bastava aggiungere una fase da un lato perché la stessa lavorazione avesse due nomi a seconda di
  # chi la guardava — la scheda del ticket o la coda delle approvazioni.
  #
  # Il modello ora la chiede al risolutore, e questo spec è la porta che impedisce alla copia di
  # tornare: una fase scritta a mano dentro #phase rende la suite rossa qui.
  it "il modello non ricopia la catena: la chiede al risolutore" do
    expect(fasi_prodotte_da("app/models/agents/workflow.rb", "phase")).to eq([])
  end

  # È questa la porta. Una fase senza parola non arriva a chi legge: si ferma qui.
  it "ogni fase dell'elenco ha il suo passaggio" do
    senza = described_class::PHASES.reject { |f| described_class::STAGE.key?(f) }

    expect(senza).to eq([]), "fasi senza passaggio: #{senza.join(', ')}"
  end

  it "nessun passaggio inventato: tutti stanno fra le otto parole" do
    fuori = described_class::STAGE.values.uniq - described_class::STAGES

    expect(fuori).to eq([])
  end

  it "le otto parole hanno tutte una traduzione, in entrambe le lingue" do
    %i[it en].each do |lingua|
      I18n.with_locale(lingua) do
        described_class::STAGES.each do |parola|
          testo = I18n.t("member.tickets.automation.stage.#{parola}", default: nil)
          expect(testo).to be_present, "manca #{parola} in #{lingua}"
        end
      end
    end
  end

  describe ".stage" do
    it "traduce una fase conosciuta" do
      expect(described_class.stage("awaiting_approval")).to eq("plan_to_approve")
      expect(described_class.stage("closer_production")).to eq("closing")
    end

    # In sviluppo e in test si rompe subito: è il momento in cui costa meno accorgersene.
    it "una fase sconosciuta solleva fuori dalla produzione" do
      expect { described_class.stage("fase_che_non_esiste") }
        .to raise_error(ArgumentError, /fase senza passaggio/)
    end

    # In produzione non si rompe una pagina per un nome: ripiega su «in lavorazione», che è vero per
    # quasi tutte le fasi. Ma non stampa mai il nome interno, che era il difetto.
    it "in produzione ripiega, e non stampa mai il nome interno" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

      expect(described_class.stage("fase_che_non_esiste")).to eq("in_progress")
    end
  end

  describe ".waiting_on_you?" do
    it "riconosce i momenti che aspettano una persona" do
      expect(described_class).to be_waiting_on_you("awaiting_approval")
      expect(described_class).to be_waiting_on_you("review_blocked")
    end

    it "e quelli che non aspettano niente" do
      expect(described_class).not_to be_waiting_on_you("autopilot")
      expect(described_class).not_to be_waiting_on_you("completed")
    end
  end

  # CYRA-619 — la mappa «quale fase interna si sta decidendo» è caduta con i suoi consumatori: la
  # plancia e la striscia parlano ora dei sei passaggi del modello, e non hanno più bisogno di
  # tradurre uno stato in una fase della macchina.
  it "la mappa delle fasi interne non esiste più: nessuno traduce a mano" do
    expect(described_class).not_to be_const_defined(:WAITING_ON_PHASE)
    expect(described_class).not_to respond_to(:deciding_phase)
  end

  # CYRA-619 — i sei passaggi sono le prime sei parole, in ordine: le due uscite non sono tappe.
  it "i sei passaggi sono le tappe, non le uscite" do
    expect(described_class::STEPS).to eq(described_class::STAGES.first(6))
    expect(described_class::STEPS).not_to include("blocked", "cancelled")
  end

  # Ogni fase di esecuzione che il dominio può scrivere in `blocked_phase` deve sapere dove mettere il
  # segno rosso: senza, una fermata resterebbe invisibile sulla griglia.
  it "ogni fase di esecuzione sa su quale passaggio si è fermata" do
    Agents::PhaseProfile::PHASES.each do |fase|
      passaggio = described_class.step_of_execution_phase(fase)
      expect(described_class::STEPS).to include(passaggio), fase
    end
  end
end
