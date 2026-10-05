# frozen_string_literal: true

require "rails_helper"

# CYRA-425 — nella coda di revisione le parole sono metà del lavoro: chi decide non ha costruito il
# flusso e legge quelle etichette per capire cosa sta per fare.
#
# «Da archiviare» diceva il passo interno (scrivere la pagina fra i documenti versionati) con una
# parola che in italiano comune significa «mettere via», cioè quasi il contrario. E l'avviso sul
# costo dell'errore era un frammento appeso a un titolo, non una frase che si legge da sola.
RSpec.describe "Parole della coda di revisione (CYRA-425)", type: :model do
  # Parole del mestiere di chi ha costruito il flusso, non di chi lo usa.
  GERGO_INTERNO = /\b(repo|repository|commit|branch|markdown|embedding|endpoint|backfill|path)\b|\.md\b/i

  # «Archiviare» qui vuol dire «scrivere fra i documenti»: nessuno lo indovina.
  PAROLA_AMBIGUA = /archivi/i

  def etichette_della_coda
    I18n.with_locale(:it) do
      strings = {}
      flatten(I18n.t("member.knowledge.reviews"), "member.knowledge.reviews", strings)
      strings["member.knowledge.overview.review_stat_to_file"] = I18n.t("member.knowledge.overview.review_stat_to_file")
      strings
    end
  end

  def flatten(node, prefix, out)
    case node
    when Hash then node.each { |key, value| flatten(value, "#{prefix}.#{key}", out) }
    when String then out[prefix] = node
    end
  end

  it "nessuna etichetta della schermata usa il gergo di chi ha costruito il flusso" do
    colpevoli = etichette_della_coda.select { |_, testo| testo.match?(GERGO_INTERNO) }

    expect(colpevoli).to be_empty, "gergo interno in: #{colpevoli.keys.join(', ')}"
  end

  it "«archiviare» non compare più: le etichette dicono che manca il documento" do
    colpevoli = etichette_della_coda.select { |_, testo| testo.match?(PAROLA_AMBIGUA) }

    expect(colpevoli).to be_empty, "parola ambigua in: #{colpevoli.keys.join(', ')}"
  end

  it "il contatore delle accettate dice cosa manca davvero" do
    I18n.with_locale(:it) do
      expect(I18n.t("member.knowledge.reviews.stat_to_file")).to match(/documenti/i)
      expect(I18n.t("member.knowledge.reviews.not_filed")).to match(/documenti/i)
    end
  end

  # La coda e la panoramica della knowledge contano la stessa cosa: chiamarla in due modi diversi
  # fa credere che siano due cose (stessa regola di spec/i18n/knowledge_product_vocabulary_spec.rb).
  it "la panoramica chiama quel contatore come lo chiama la coda" do
    I18n.with_locale(:it) do
      expect(I18n.t("member.knowledge.overview.review_stat_to_file"))
        .to eq(I18n.t("member.knowledge.reviews.stat_to_file").downcase)
    end
  end

  # La guida racconta la stessa schermata: se cita un'etichetta con le vecchie parole, manda a
  # cercare qualcosa che sulla pagina non c'è più.
  it "la guida chiama le sezioni con le parole che si leggono sulla pagina" do
    I18n.with_locale(:it) do
      expect(I18n.t("member.guides.knowledge_review.file_title"))
        .to eq(I18n.t("member.knowledge.reviews.to_file_title"))
      expect(I18n.t("member.guides.knowledge_review.file_body"))
        .to include(I18n.t("member.knowledge.reviews.to_file_title"))

      # Nessun testo della guida manda a cercare un'etichetta sparita dalla pagina.
      sparite = /Leggi la pagina|#{PAROLA_AMBIGUA.source}/i
      colpevoli = I18n.t("member.guides.knowledge_review").values.grep(String).grep(sparite)
      expect(colpevoli).to be_empty, "la guida cita etichette che non esistono più: #{colpevoli.join(' | ')}"
    end
  end

  it "l'avviso sulla visibilità è una frase compiuta, non un frammento appeso a un titolo" do
    %i[it en].each do |locale|
      I18n.with_locale(locale) do
        avviso = I18n.t("member.knowledge.reviews.waiting_note")
        expect(avviso.length).to be > 40, "#{locale}: avviso troppo corto per leggersi da solo"
        expect(avviso).to end_with(".")
      end
    end
  end

  it "accanto ai due bottoni la conseguenza è scritta in entrambe le lingue" do
    %i[it en].each do |locale|
      I18n.with_locale(locale) do
        expect(I18n.t("member.knowledge.reviews.accept_hint")).to be_present
        expect(I18n.t("member.knowledge.reviews.reject_hint")).to be_present
      end
    end
  end
end
