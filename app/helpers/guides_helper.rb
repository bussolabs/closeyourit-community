# frozen_string_literal: true

# CYRA-336 — l'indice delle guide spiegava bene tredici funzioni su una quarantina: chi arrivava non
# aveva modo di sapere cosa fanno le altre, e le guide sono l'unica pagina che risponde a «cosa sa
# fare questo strumento».
#
# Il catalogo si costruisce dalle STESSE voci del menu, area per area: un elenco scritto a mano
# resterebbe indietro alla prima pagina nuova, e il buco tornerebbe. Ogni voce porta la sua riga di
# spiegazione (member.guides.catalog.<voce>) e, quando esiste, il link alla guida che la approfondisce.
module GuidesHelper
  def guides_catalog
    Navigation::Group.all.reject(&:pinned?).filter_map do |group|
      items = group_leaf_items(group)
      next if items.empty?

      { label: group.label, items: items.map { |item| catalog_item(item) } }
    end
  end

  # CYRA-441 — la riga di spiegazione di una destinazione del menu. È scritta una volta sola
  # (member.guides.catalog.<voce>) e letta da chiunque elenchi quelle voci: il catalogo qui sotto e
  # le pagine d'ingresso delle aree, dove l'elenco di link era nudo. Vuota se la voce non ne ha una.
  def nav_item_description(item)
    t("member.guides.catalog.#{nav_item_key(item)}", default: "")
  end

  private

  def nav_item_key(item) = item.test.to_s.delete_prefix("member-nav-").tr("-", "_")

  def catalog_item(item)
    { label: item.label, href: item.path, icon: item.icon,
      description: nav_item_description(item),
      guide_href: Guides::Map.path_for(item.path) }
  end
end
