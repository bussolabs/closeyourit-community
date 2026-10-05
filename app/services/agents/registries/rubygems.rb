# frozen_string_literal: true

module Agents
  module Registries
    # RubyGems. Il ritiro lo dichiara la risposta per singola versione (`yanked`), quindi servono due
    # letture: una per sapere se quella versione c'è e non è stata ritirata, una per il puntatore
    # «ultima buona» che il registro dichiara.
    class Rubygems < Client
      def lookup(package, version)
        validate!(package, version)
        url = url_for("api", "v2", "rubygems", package, "versions", "#{version}.json")
        row = get(url, allow_not_found: true)
        latest = get(url_for("api", "v1", "versions", "#{package}", "latest.json"), allow_not_found: true)

        { present: row.present?, yanked: row.present? && row["yanked"] == true,
          latest: latest && latest["version"], sha: nil, url: url }
      end
    end
  end
end
