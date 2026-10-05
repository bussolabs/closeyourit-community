# frozen_string_literal: true

require "rails_helper"

# CYRA-327 — in giro per il prodotto restavano parole inglesi in mezzo all'italiano («Idee pending»,
# «Definition of Done», «Todos», «Board»): proprio il gergo che il prodotto dichiara di voler evitare
# con chi non è tecnico. Questa spec è la guardia: se una voce nuova rientra in italiano con una
# parola inglese, fallisce qui.
#
# Il pannello god (`valhalla.*`) è escluso di proposito: è la console interna, non il prodotto.
RSpec.describe "Interfaccia in italiano", type: :model do
  # Parole inglesi osservate nell'audit, più quelle che tornerebbero facilmente. Non è un dizionario:
  # è la lista di ciò che è già successo, che è la sola che si può difendere senza falsi allarmi.
  # `owner` resta: è il NOME di un ruolo del prodotto (come `admin`), non una parola di prosa —
  # rinominare i ruoli è una decisione di prodotto, non una traduzione.
  # CYRA-366 aggiunge «case» e «action»: in italiano «case» si legge come il plurale di casa, e
  # comparivano proprio nel campo che chiede un esempio concreto.
  # CYRA-388 aggiunge il vocabolario del monitoraggio: «issue» e gli stati inglesi comparivano
  # accanto alle stesse cose scritte in italiano, nella stessa schermata.
  FORBIDDEN = /\b(pending|Definition of Done|Todos|Guides|Review|Board|Draft|cases?|actions?|Book|issues?|unresolved|breadcrumbs?)\b/i

  # `%{pending}` è un segnaposto di interpolazione, non una parola letta da nessuno.
  PLACEHOLDER = /%\{[a-z_]+\}/

  # Nomi di prodotto: si scrivono come si chiamano, in qualunque lingua sia la frase intorno.
  PRODUCT_NAMES = /GitHub Actions/

  def italian_strings
    strings = {}
    Dir[Rails.root.join("config/locales/**/*.yml")].each do |file|
      tree = YAML.load_file(file)
      next unless tree.is_a?(Hash) && tree["it"]

      flatten(tree["it"], "", strings)
    end
    # `valhalla.` è la console interna; `website.` è il sito pubblico, scritto per team tecnici
    # («issue tracker» è il nome del mestiere): nessuno dei due è l'interfaccia del prodotto.
    strings.reject { |key, _| key.start_with?("valhalla.", "website.") }
  end

  def flatten(node, prefix, out)
    node.each do |key, value|
      case value
      when Hash then flatten(value, "#{prefix}#{key}.", out)
      when String then out["#{prefix}#{key}"] = value
      end
    end
    out
  end

  it "nessun testo italiano contiene le parole inglesi già segnalate" do
    offenders = italian_strings.select do |_key, value|
      value.gsub(PLACEHOLDER, "").gsub(PRODUCT_NAMES, "").match?(FORBIDDEN)
    end

    expect(offenders).to be_empty, "testi ancora in inglese: #{offenders.keys.join(', ')}"
  end

  it "nessun testo italiano è una traduzione mancante" do
    offenders = italian_strings.select { |_key, value| value.include?("translation missing") }

    expect(offenders).to be_empty
  end

  # Le icone della barra in alto: senza nome, un lettore di schermo legge la chiave interna.
  it "ogni icona della barra in alto ha un nome in italiano" do
    %w[member.quick_add.button member.nav.todos member.nav.chat member.nav.alerts member.nav.toggle].each do |key|
      expect(I18n.t(key, locale: :it)).to be_present
      expect(I18n.t(key, locale: :it)).not_to include("translation missing")
    end
  end
end
