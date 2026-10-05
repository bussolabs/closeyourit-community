# frozen_string_literal: true

module Agents
  module Registries
    # PyPI. È il progetto su cui il difetto si vedeva a occhio nudo: l'etichetta 0.2.0 nel repository
    # dal primo agosto, e sul magazzino ancora solo la 0.1.0.
    class Pypi < Client
      def lookup(package, version)
        validate!(package, version)
        url = url_for("pypi", package, version, "json")
        row = get(url, allow_not_found: true)
        project = get(url_for("pypi", package, "json"), allow_not_found: true)

        { present: row.present?, yanked: row.present? && row.dig("info", "yanked") == true,
          latest: project&.dig("info", "version"), sha: nil, url: url }
      end
    end
  end
end
