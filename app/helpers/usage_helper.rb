# frozen_string_literal: true

# CYRA-733 — il vocabolario della pagina d'uso. La tabella conserva simboli tecnici (una chiave, un
# nome di classe): qui diventano parole che chi legge riconosce, senza mai perdere il simbolo vero
# quando una parola non c'è.
module UsageHelper
  USAGE_KIND_ICONS = {
    "feature_view" => "star",
    "route" => "file-text",
    "job" => "cog",
    "custom" => "tag"
  }.freeze

  def usage_kind_icon(kind) = USAGE_KIND_ICONS.fetch(kind, "circle")

  # Il tipo di simbolo con la parola del prodotto. Un kind sconosciuto — un SDK più nuovo del
  # backend — si mostra com'è arrivato invece di sparire dietro un'etichetta generica.
  def usage_kind_label(kind)
    t("member.usage.kinds.#{kind}", default: kind.to_s)
  end

  # Il nome leggibile di un simbolo. Per una funzione di prodotto è quello del catalogo, lo stesso
  # che si legge nel menu e nelle guide: la chiave `tickets` è un nome interno e non deve arrivare a
  # schermo. Le chiavi di un altro prodotto, che quel catalogo non conosce, restano come sono: meglio
  # il simbolo grezzo di un nome inventato qui.
  def usage_symbol_label(symbol)
    key = symbol.symbol
    return key unless symbol.kind == "feature_view" && ::Usage::FeatureMap.index.value?(key)

    t("member.assistant.catalog.#{key}.label")
  end

  # Il simbolo tecnico da mostrare accanto al nome, solo quando il nome non lo è già.
  def usage_symbol_hint(symbol)
    hint = usage_symbol_label(symbol)
    hint == symbol.symbol ? nil : symbol.symbol
  end
end
