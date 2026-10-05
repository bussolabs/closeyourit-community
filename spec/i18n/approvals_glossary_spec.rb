# frozen_string_literal: true

require "rails_helper"

# CYRA-318 — Glossario di prodotto della coda delle decisioni. La stessa pila aveva quattro nomi
# («Approvazioni», «Sblocchi e approvazioni», «Da approvare», «Da decidere», «coda», «fila»), i verbi
# cambiavano tra Home e dettaglio («Approva/Rifiuta» vs «Accetta/Respingi») e l'esecutore era chiamato
# in più modi («agente», «automa», «Agenti AI»). Qui fissiamo un solo termine per concetto e lo
# blindiamo contro le regressioni: nome coda «Approvazioni», chip «Da approvare», verbi «Approva/Respingi»,
# esecutore «agente». Vale sull'italiano, il locale del glossario.
#
# CYRA-502 ha invertito il verbo negativo: era «Rifiuta», ora è «Respingi». La coppia doveva essere
# una sola in tutta la coda — e lo era — ma non parlava la stessa lingua dell'esito che genera: il
# pulsante diceva «Rifiuta», la riga del ticket «bocciato» e il riquadro del rendimento «respinti».
# Il verbo si chiama come l'esito, e «Rifiuta» passa fra i termini banditi. Il glossario completo sta
# in docs/glossario-prodotto.md, presidiato da spec/i18n/product_glossary_spec.rb.
RSpec.describe "Glossario coda approvazioni (CYRA-318)", type: :model do
  # Appiattisce l'albero di traduzioni in tutte le sue foglie stringa, così un guard può cercarvi i
  # termini banditi senza inciampare su hash annidati o pluralizzazioni.
  def leaf_strings(value)
    case value
    when String then [ value ]
    when Hash   then value.values.flat_map { |v| leaf_strings(v) }
    when Array  then value.flat_map { |v| leaf_strings(v) }
    else []
    end
  end

  # \b evita i falsi positivi: «automatica»/«automazione» (l'attività e il sistema, che restano) non
  # matchano, solo «automa»/«automi» (l'esecutore, bandito).
  BANNED_EXECUTOR = /\bautom[ai]\b/i
  BANNED_VERBS    = /accett|rifiut/i
  BANNED_QUEUE    = /\bfila\b/i

  describe "un solo nome per la coda: «Approvazioni»" do
    it "la pagina della coda si chiama «Approvazioni»" do
      expect(I18n.t("member.approvals.title", locale: :it)).to eq("Approvazioni")
    end

    it "la card in Home si chiama «Approvazioni» (non più «Sblocchi e approvazioni»)" do
      expect(I18n.t("member.home.approvals.title", locale: :it)).to eq("Approvazioni")
    end

    it "la guida si chiama «Approvazioni»" do
      expect(I18n.t("member.guides.approvals.title", locale: :it)).to eq("Approvazioni")
      expect(I18n.t("member.guides.index.approvals.title", locale: :it)).to eq("Approvazioni")
    end
  end

  describe "un solo nome per il conteggio: «Da approvare»" do
    it "il chip in Home dice «Da approvare»" do
      expect(I18n.t("member.home.counts.approvals", locale: :it)).to eq("Da approvare")
    end

    it "il chip nella coda dice «Da approvare» (non più «Da decidere»)" do
      expect(I18n.t("member.approvals.counts.total", locale: :it)).to eq("Da approvare")
    end
  end

  describe "una sola coppia di verbi: «Approva» / «Respingi»" do
    it "nella coda i verbi sono «Approva» e «Respingi» (non più «Accetta»/«Rifiuta»)" do
      expect(I18n.t("member.approvals.actions.approve.review", locale: :it)).to eq("Approva")
      expect(I18n.t("member.approvals.actions.reject.review", locale: :it)).to eq("Respingi")
      expect(I18n.t("member.approvals.bulk.approve", locale: :it)).to eq("Approva")
    end

    # CYRA-658 — la Home non ha più pulsanti suoi: rende lo stesso pannello di decisione della
    # plancia, quindi i verbi sono già quelli presidiati dal test qui sopra. Resta da guardare che
    # i modi per NON decidere non usino gli stessi verbi, o si confonderebbero con una decisione.
    it "in Home i modi per non decidere non parlano come una decisione" do
      %w[skip defer].each do |azione|
        etichetta = I18n.t("member.home.decision.#{azione}", locale: :it)
        expect(etichetta).not_to match(/Approva|Respingi|Rifiuta|Accetta/i), "«#{etichetta}» sembra una decisione"
      end
    end

    it "nella guida i tre modi di rispondere usano «Approva» e «Respingi»" do
      expect(I18n.t("member.guides.approvals.buttons.accept.title", locale: :it)).to eq("Approva")
      expect(I18n.t("member.guides.approvals.buttons.reject.title", locale: :it)).to eq("Respingi")
    end
  end

  describe "un solo nome per chi svolge il lavoro: «agente»" do
    it "le domande in coda sono «Domande dell'agente» (non più «dell'automa»)" do
      expect(I18n.t("member.approvals.questions", locale: :it)).to eq("Domande dell'agente")
    end

    it "il pannello di eleggibilità del ticket si chiama «Agenti» (non più «Agenti AI»)" do
      expect(I18n.t("member.tickets.agent_eligibility.title", locale: :it)).to eq("Agenti")
      expect(I18n.t("member.tickets.filter_agent_eligibility", locale: :it)).to eq("Agenti")
    end

    it "in tutta l'area ticket l'esecutore è «agenti», mai «agenti AI»" do
      # Anche gli eventi di cronologia dell'eleggibilità (Valutazione automatica…, impostato su…)
      # devono dire «agenti»: erano rimasti «agenti AI», incoerenti col pannello.
      strings = leaf_strings(I18n.t("member.tickets", locale: :it))
      offenders = strings.select { |s| s.match?(/\bagent[ei]\s+AI\b/i) }
      expect(offenders).to be_empty, "«agente/agenti AI» ancora presenti nell'area ticket: #{offenders.inspect}"
    end
  end

  describe "nessun termine bandito sopravvive nell'area coda" do
    it "in member.approvals non resta traccia di «automa/automi» né di «Accetta/Rifiuta»" do
      strings = leaf_strings(I18n.t("member.approvals", locale: :it))
      offenders = strings.select { |s| s.match?(BANNED_EXECUTOR) || s.match?(BANNED_VERBS) }
      expect(offenders).to be_empty, "termini banditi ancora presenti: #{offenders.inspect}"
    end

    it "nella guida della coda non resta traccia di «automa», «Accetta/Rifiuta» né «fila»" do
      strings = leaf_strings(I18n.t("member.guides.approvals", locale: :it))
      offenders = strings.select { |s| s.match?(BANNED_EXECUTOR) || s.match?(BANNED_VERBS) || s.match?(BANNED_QUEUE) }
      expect(offenders).to be_empty, "termini banditi ancora presenti: #{offenders.inspect}"
    end
  end
end
