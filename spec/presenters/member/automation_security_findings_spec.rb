# frozen_string_literal: true

require "rails_helper"

# CYRA-384 — su un ticket vero la segnalazione di sicurezza (uno script che sondava le credenziali
# git, un token dentro l'indirizzo di download) era testo corrente dentro un paragrafo di 250 parole,
# e non la vedeva nessuno.
#
# Decisione del 2026-08-17: la scrive la macchina in un CAMPO APPOSTA del risultato consegnato
# (`security_findings`), non si cerca nel testo. Cercarla nel testo vuol dire indovinare, e su una
# segnalazione di sicurezza indovinare male costa in tutte e due le direzioni.
#
# Il campo passa il contratto agent-result/v1 senza toccarlo: ogni result ha `additionalProperties`
# aperto. Qui si prova la lettura, che è difensiva per costruzione — il payload è dato esterno e non
# deve MAI far esplodere la pagina del ticket.
RSpec.describe Member::AutomationSecurityFindings do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:host) { create(:agent_host, organization:) }

  def findings = described_class.call(ticket: ticket.reload)
  def declared? = described_class.declared?(ticket: ticket.reload)

  def attempt_with(result, **overrides)
    create(:agent_attempt, { organization:, workflow:, host:, phase: "autopilot", status: :approved,
                             started_at: 10.minutes.ago, finished_at: 9.minutes.ago, result: }.merge(overrides))
  end

  it "legge titolo, dettaglio e gravità dal campo apposta" do
    attempt_with({ "state" => "blocked", "reason" => "Fermato",
                   "security_findings" => [ { "title" => "Credenziali git sondate",
                                              "detail" => "Uno script legge ~/.git-credentials.",
                                              "severity" => "high" } ] })

    expect(findings.size).to eq(1)
    expect(findings.first.title).to eq("Credenziali git sondate")
    expect(findings.first.detail).to eq("Uno script legge ~/.git-credentials.")
    expect(findings.first.severity).to eq("high")
  end

  it "non trova niente dove la macchina non ha segnalato niente" do
    attempt_with({ "state" => "delivered" })

    expect(findings).to be_empty
  end

  # Un ticket senza lavorazione automatica non deve nemmeno interrogare il database: la pagina del
  # ticket si apre migliaia di volte al giorno e questa è una scheda che quasi sempre non c'è.
  it "un ticket senza lavorazione automatica non ha segnalazioni" do
    ticket = create(:ticket, organization:, project:)

    expect(described_class.call(ticket:)).to be_empty
  end

  # Diciannove tentativi identici ripetono diciannove volte la stessa segnalazione: un avviso con
  # diciannove righe uguali è di nuovo il registro di macchina che questo ticket toglie di mezzo.
  it "la stessa segnalazione ripetuta a ogni tentativo compare una volta sola" do
    3.times do |index|
      attempt_with({ "state" => "blocked", "reason" => "Fermato",
                     "security_findings" => [ { "title" => "Token nell'indirizzo",
                                                "detail" => "Il token viaggia nella query string." } ] },
                   started_at: (30 - index).minutes.ago, finished_at: (29 - index).minutes.ago)
    end

    expect(findings.size).to eq(1)
  end

  # Una consegna respinta dalla revisione ha comunque il risultato salvato. La segnalazione lì dentro
  # resta da leggere: la revisione ha bocciato il LAVORO, non ha smentito l'allarme.
  it "vale anche la segnalazione di un tentativo respinto" do
    attempt_with({ "state" => "blocked", "reason" => "Fermato",
                   "security_findings" => [ { "title" => "Segreto nei log" } ] }, status: :review_failed)

    expect(findings.map(&:title)).to eq([ "Segreto nei log" ])
  end

  describe "un payload malfatto non rompe la pagina" do
    it "scarta le voci senza titolo" do
      attempt_with({ "security_findings" => [ { "detail" => "Solo il dettaglio" }, { "title" => "  " } ] })

      expect(findings).to be_empty
    end

    it "regge un campo che non è una lista" do
      attempt_with({ "security_findings" => "una stringa" })

      expect(findings).to be_empty
    end

    it "regge una lista di valori che non sono oggetti" do
      attempt_with({ "security_findings" => [ "stringa", 42, nil ] })

      expect(findings).to be_empty
    end

    it "una gravità fuori vocabolario non diventa un colore inventato" do
      attempt_with({ "security_findings" => [ { "title" => "Qualcosa", "severity" => "catastrofica" } ] })

      expect(findings.first.severity).to be_nil
    end
  end

  # CYRA-603 — «nessuna segnalazione» erano due cose diverse e indistinguibili: «ho guardato e non ho
  # trovato niente» e «non ho guardato». Un silenzio che vuol dire due cose non è una risposta.
  #
  # La differenza vive tutta nella query: `-> 'security_findings' IS NOT NULL` distingue il JSON `[]`
  # (dichiarato, vuoto) dalla chiave assente. È l'unico punto del sistema in cui esiste, quindi è qui
  # che va provata — e va provata in ENTRAMBI i versi, perché un `declared?` che risponde sempre true
  # passerebbe metà di questi esempi.
  describe ".declared?" do
    it "è falso quando nessuna consegna ha dichiarato il campo" do
      attempt_with({ "state" => "delivered", "cycles" => 1 })

      expect(declared?).to be(false)
      expect(findings).to be_empty
    end

    it "è vero con l'elenco VUOTO: «ho guardato e non ho trovato niente» è una risposta" do
      attempt_with({ "state" => "delivered", "cycles" => 1, "security_findings" => [] })

      expect(declared?).to be(true)
      expect(findings).to be_empty
    end

    it "è vero con l'elenco pieno" do
      attempt_with({ "state" => "delivered", "cycles" => 1,
                     "security_findings" => [ { "title" => "Chiave dentro un indirizzo" } ] })

      expect(declared?).to be(true)
      expect(findings.size).to eq(1)
    end

    it "è falso senza lavorazione automatica: non c'è nessuno che possa aver guardato" do
      expect(described_class.declared?(ticket: create(:ticket, organization:, project:))).to be(false)
    end
  end
end
