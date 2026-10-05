# frozen_string_literal: true

require "rails_helper"

# CYRA-576 — LE TRE SPIEGAZIONI DELLA GUIDANCE, una per livello.
#
# La guidance si scrive a tre livelli (organizzazione, gruppo, progetto) e l'unica frase che
# spiegava come funziona era scritta dal punto di vista del progetto: «dichiarati qui ed ereditati
# da organizzazione e gruppo». Mostrata identica sull'organizzazione diceva che l'organizzazione
# eredita da sé stessa; letta sul gruppo faceva credere di stare scrivendo per un progetto.
#
# The project level shows no explanation since its page is a tab of the project with nothing
# outside its panels (CYRA-930): the rule holds for the two levels that still show one.
#
# LA REGOLA
#   1. Ogni livello ha la propria spiegazione: le tre non possono coincidere.
#   2. Ogni spiegazione nomina il livello di cui parla, in entrambe le lingue.
#   3. Solo l'organizzazione non eredita: è la base. Gruppo e progetto dicono da dove arrivano.
#   4. Il modulo dichiara il livello e il nome di ciò a cui si applica: la frase porta il nome.
RSpec.describe "Le tre spiegazioni della guidance (CYRA-576)", type: :model do
  # Il livello e la parola con cui ciascuna lingua lo chiama: una spiegazione che non nomina il
  # proprio livello non dice a chi si applica.
  LIVELLI_GUIDANCE = {
    "organization" => { it: /organizzazione/i, en: /organization/i },
    "group"        => { it: /grupp/i,          en: /group/i },
    "project"      => { it: /progett/i,        en: /project/i }
  }.freeze

  # Le parole con cui le due lingue dicono che il contenuto arriva da un livello più in alto.
  EREDITA_GUIDANCE = { it: /eredit/i, en: /inherit/i }.freeze

  SPIEGATI_GUIDANCE = %w[organization group].freeze

  def spiegazione(livello, locale) = I18n.t("member.guidance.help.#{livello}", locale: locale)

  def dichiarazione(livello, locale, nome:) = I18n.t("member.guidance.applies_to.#{livello}", locale: locale, name: nome)

  %i[it en].each do |locale|
    context "in #{locale}" do
      it "ogni livello ha la propria spiegazione" do
        testi = SPIEGATI_GUIDANCE.map { |livello| spiegazione(livello, locale) }
        expect(testi.uniq.size).to eq(2), "le spiegazioni dei tre livelli coincidono: #{testi.inspect}"
      end

      it "ogni spiegazione nomina il livello di cui parla" do
        LIVELLI_GUIDANCE.slice(*SPIEGATI_GUIDANCE).each do |livello, parole|
          expect(spiegazione(livello, locale)).to match(parole.fetch(locale)),
                                                  "la spiegazione di #{livello} non nomina il proprio livello"
        end
      end

      it "l'organizzazione è la base e non eredita da nessuno" do
        expect(spiegazione("organization", locale)).not_to match(EREDITA_GUIDANCE.fetch(locale))
      end

      it "gruppo e progetto dicono da dove arriva ciò che ricevono" do
        %w[group].each do |livello|
          expect(spiegazione(livello, locale)).to match(EREDITA_GUIDANCE.fetch(locale)),
                                                  "la spiegazione di #{livello} non dice cosa riceve"
        end
      end

      it "il modulo dichiara il livello e il nome di ciò a cui si applica" do
        LIVELLI_GUIDANCE.each do |livello, parole|
          testo = dichiarazione(livello, locale, nome: "Acme")
          expect(testo).to include("Acme"), "la dichiarazione di #{livello} non porta il nome"
          expect(testo).to match(parole.fetch(locale)), "la dichiarazione di #{livello} non nomina il livello"
        end
      end
    end
  end
end
