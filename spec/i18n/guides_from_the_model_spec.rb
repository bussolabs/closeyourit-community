# frozen_string_literal: true

require "rails_helper"

# CYRA-631 — le guide raccontano il modello che il sistema esegue davvero.
#
# Il difetto non era una frase sbagliata: era che le guide tenevano un elenco proprio e un conteggio
# proprio. L'elenco sotto si costruiva da solo, la frase sopra annunciava «cinque passaggi» col
# numero scritto dentro, e il giorno del passaggio a sei la frase avrebbe continuato a dire cinque —
# senza che niente diventasse rosso.
#
# Queste prove non guardano i testi: guardano che i testi NON possano divergere.
RSpec.describe "le guide prendono il modello da dove lo prende il prodotto" do
  risolutore = Agents::Workflows::PhaseResolver

  describe "i passaggi" do
    # Se la guida tenesse un elenco suo, sostituire quello canonico non cambierebbe la pagina.
    it "l'elenco reso è quello canonico, nell'ordine canonico" do
      expect(risolutore::STEPS).to eq(%w[to_plan plan_to_approve in_progress to_review closing done])
    end

    it "ogni passaggio ha un nome e una spiegazione, in tutte e due le lingue" do
      %w[it en].each do |lingua|
        risolutore::STEPS.each do |step|
          nome = I18n.t("member.tickets.automation.stage.#{step}", locale: lingua, default: "")
          corpo = I18n.t("member.guides.agents.steps.#{step}.body", locale: lingua, default: "")

          expect(nome).to be_present, "#{lingua}: manca il nome di #{step}"
          expect(corpo).to be_present, "#{lingua}: manca la spiegazione di #{step}"
          expect(corpo).not_to eq(nome), "#{lingua}: #{step} si spiega ripetendo il proprio nome"
        end
      end
    end

    # Il nome è UNO: quello che la plancia scrive nella colonna. Due sorgenti sono due nomi al primo
    # cambio, ed è già successo.
    it "il nome del passaggio è lo stesso che rende la plancia" do
      risolutore::STEPS.each do |step|
        expect(I18n.exists?("member.tickets.automation.stage.#{step}")).to be(true), step
      end
      expect(I18n.exists?("member.guides.agents.phases")).to be(false),
        "la guida tiene ancora un elenco di fasi suo"
    end
  end

  describe "il segno «Tocca a te»" do
    # Il conto che si fa sulla guida dev'essere quello che si trova nella coda: né uno di più né uno
    # di meno. Derivandolo, CYRA-629 ha portato i segni da tre a due senza toccare un testo.
    it "sta esattamente sui passaggi che il server dichiara in attesa di una persona" do
      attesi = risolutore::HUMAN_GATED_PHASES.map { |f| risolutore.stage(f) }.uniq & risolutore::STEPS

      expect(risolutore.waiting_steps).to eq(attesi)
      expect(risolutore.waiting_steps).to be_present
    end

    it "ognuno porta un testo visibile nelle due lingue, e gli altri non ce l'hanno" do
      %w[it en].each do |lingua|
        risolutore::STEPS.each do |step|
          gate = I18n.t("member.guides.agents.steps.#{step}.gate", locale: lingua, default: "")

          if risolutore.waiting_steps.include?(step)
            expect(gate).to be_present, "#{lingua}: #{step} aspetta una persona e non lo dice"
          else
            expect(gate).to be_blank, "#{lingua}: #{step} non aspetta nessuno ma porta un segno"
          end
        end
      end
    end
  end

  describe "le due uscite" do
    it "sono derivate, non riscritte" do
      expect(risolutore::EXITS).to eq(risolutore::STAGES - risolutore::STEPS)
    end

    it "la guida le rende con le stesse parole della schermata, e le spiega" do
      %w[it en].each do |lingua|
        risolutore::EXITS.each do |uscita|
          nome = I18n.t("member.tickets.automation.stage.#{uscita}", locale: lingua, default: "")
          corpo = I18n.t("member.guides.agents.exits.#{uscita}.body", locale: lingua, default: "")

          expect(nome).to be_present, "#{lingua}: manca il nome di #{uscita}"
          expect(corpo).to be_present, "#{lingua}: l'uscita #{uscita} non è spiegata"
          expect(corpo).not_to eq(nome), "#{lingua}: #{uscita} si spiega ripetendo il proprio nome"
        end
      end
    end
  end

  # Un numerale dentro una frase è un elenco scritto a mano che non si vede: sopravvive a ogni
  # cambiamento del modello dicendo il falso, e nessuna prova se ne accorge. Le poche voci in cui un
  # numero è legittimo stanno in un elenco CHIUSO: se cresce, questa prova diventa rossa e qualcuno
  # deve guardare perché.
  describe "nessun conteggio scritto a mano" do
    # Il numerale conta solo se è ATTACCATO a ciò che il modello enumera. In italiano «sei» è anche
    # un verbo — «sei tu a doverli guardare» — e un elenco di sole parole-numero segnalava quello,
    # cioè rumore che nessuno può togliere. Qui la regola dice quello che intende: quanti sono i
    # passaggi, gli stati, gli esiti, i modi.
    COSE_CONTATE = /passagg\w+|stat[io]|esit\w+|modi|pallin\w+|colonn\w+|steps?|status(?:es)?|outcomes?|ways?|dots?|columns?/i
    NUMERALI = /\b(due|tre|quattro|cinque|sei|sette|otto|two|three|four|five|six|seven|eight)\b[^.;:]{0,40}?#{COSE_CONTATE}/i

    # Le guide che raccontano il MODELLO. Un numero dentro una loro frase è un elenco scritto a mano:
    # sopravvive al cambiamento dicendo il falso. Altrove un numero è solo un numero — «due posti»,
    # «tre giorni» — e vietarlo ovunque farebbe una prova che nessuno può tenere verde.
    GUIDE_DEL_MODELLO = %w[agents approvals ticket_lifecycle].freeze

    # Esenzioni: numeri legittimi DENTRO quelle guide. Elenco chiuso — se cresce, questa prova
    # diventa rossa e qualcuno deve guardare perché.
    ESENTATE = [
      # Due SCHERMATE da cui si cambia lo stato, non due passaggi del modello.
      "member.guides.ticket_lifecycle.states_intro",
      # Le uscite sono due per costruzione (STAGES meno STEPS), e la prova qui sopra lo verifica.
      "member.guides.agents.exits_intro",
      # Tre modi in cui una MACCHINA si guasta — spenta, senza rete, indietro con le competenze —
      # non tre passaggi del modello.
      "member.guides.agents.stopped_intro",
      # «Oltre tre giorni» è una soglia vera, non un conteggio di qualcosa che il modello enumera.
      "member.guides.approvals.board_b3"
    ].freeze

    def self.foglie(albero, prefisso = "member.guides")
      albero.flat_map do |chiave, valore|
        percorso = "#{prefisso}.#{chiave}"
        valore.is_a?(Hash) ? foglie(valore, percorso) : [ [ percorso, valore.to_s ] ]
      end
    end

    %w[it en].each do |lingua|
      it "#{lingua}: nessuna voce annuncia quanti sono i passaggi, gli stati o gli esiti" do
        sotto_esame = GUIDE_DEL_MODELLO.flat_map do |guida|
          self.class.foglie(I18n.t("member.guides.#{guida}", locale: lingua), "member.guides.#{guida}")
        end
        colpevoli = sotto_esame
                        .reject { |chiave, _| ESENTATE.include?(chiave) }
                        .select { |_, testo| testo.match?(NUMERALI) }
                        .map(&:first)

        expect(colpevoli).to be_empty,
          "voci con un conteggio scritto a mano:\n#{colpevoli.join("\n")}"
      end
    end
  end
end
