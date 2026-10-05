# frozen_string_literal: true

require "rails_helper"

# CYRA-442 — LA REGOLA DELLA LINGUA, scritta una volta e presidiata qui.
#
# Chi sceglie l'italiano continuava a leggere parole inglesi. Non erano traduzioni sbagliate: erano
# testi scritti direttamente dentro il markup o dentro il JavaScript, dove nessuna scelta di lingua
# li raggiunge. Cambiare lingua non poteva sistemarli, e la scelta offerta nelle preferenze prometteva
# una cosa che il prodotto non poteva mantenere.
#
# LA REGOLA
#
# 1. Ogni parola che una persona legge passa da i18n. Nessuna eccezione per «è solo un bottone», per
#    le intestazioni di tabella, per i segnaposto dei campi, per i testi che compone il JavaScript
#    (arrivano dal componente come valore Stimulus, tradotti) e per le pagine di errore.
# 2. Ogni voce esiste in ENTRAMBE le lingue: una chiave che vive in una lingua sola stampa il
#    segnaposto di i18n a chi ha scelto l'altra. Lo presidia spec/i18n/locale_parity_spec.rb.
# 3. RESTANO IN INGLESE, di proposito:
#    - i nomi propri di prodotti e servizi (GitHub, Telegram, Kamal, Docker, Slack…);
#    - i nomi di ruolo del prodotto quando sono identificatori, non prosa (owner, admin, member) —
#      rinominarli è una decisione di prodotto, non una traduzione;
#    - i valori tecnici che l'utente copia o confronta altrove (nomi di ambiente, chiavi, percorsi,
#      intestazioni HTTP, codici di errore);
#    - la console interna Valhalla e il sito pubblico, che hanno un pubblico proprio.
# 4. I tempi trascorsi non si compongono a mano: si scrivono con l'helper localizzato, che legge
#    datetime.distance_in_words. Lo presidia spec/i18n/relative_dates_spec.rb.
#
# Questa spec è il controllo automatico chiesto dalla Definition of Done: segnala i testi rimasti
# fuori dal sistema delle lingue. Il vocabolario non è un dizionario dell'inglese — è la lista di ciò
# che è già successo, la sola difendibile senza falsi allarmi.
RSpec.describe "Regola della lingua", type: :model do
  # Parole d'interfaccia osservate nell'audit dentro il markup o dentro il JS.
  PAROLE_INGLESI = /\b(Settings|Platforms|Environments|Organization|Scope|Selected|Slug|Retention|
                      Guides|Crons|Overview|Search|Filters|Apply|Save|Cancel|Delete|Edit|New|
                      Loading|Saving|Saved|Sending|Retry|Failed|Success|Show|Hide|Copied)\b/x

  # Testo visibile fra due tag, senza ERB dentro: è ciò che finisce sotto gli occhi così com'è.
  TESTO_VISIBILE = />([^<>]{2,120})</

  def scovate_nelle_viste
    Dir[Rails.root.join("app/{views,components}/**/*.erb")].flat_map do |file|
      File.readlines(file).each_with_index.filter_map do |riga, indice|
        testo = riga.scan(TESTO_VISIBILE).flatten.find do |candidato|
          !candidato.include?("<%") && !candidato.include?("%>") && candidato.match?(PAROLE_INGLESI)
        end
        "#{relative(file)}:#{indice + 1}: #{testo.strip}" if testo
      end
    end
  end

  def scovate_nel_javascript
    Dir[Rails.root.join("app/javascript/**/*.js")].flat_map do |file|
      File.readlines(file).each_with_index.filter_map do |riga, indice|
        next if riga.strip.start_with?("//")

        testo = riga.scan(/(?:`([^`]{2,80})`|"([^"]{2,80})"|'([^']{2,80})')/).flatten.compact.find do |candidato|
          candidato.match?(PAROLE_INGLESI) && candidato.match?(/\s/)
        end
        "#{relative(file)}:#{indice + 1}: #{testo.strip}" if testo
      end
    end
  end

  def relative(file) = Pathname(file).relative_path_from(Rails.root)

  it "nessuna vista scrive testo in inglese fuori dalle traduzioni" do
    expect(scovate_nelle_viste).to be_empty
  end

  it "nessun controller JavaScript compone testo in inglese" do
    # I default dentro i values Stimulus restano: sono la rete se un caller non passa la traduzione,
    # e vivono su una riga con `{ type: String, default:` — non nel corpo del controller.
    scovate = scovate_nel_javascript.reject { |riga| riga.include?("default:") }

    expect(scovate).to be_empty
  end
end
