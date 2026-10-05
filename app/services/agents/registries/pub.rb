# frozen_string_literal: true

module Agents
  module Registries
    # pub.dev (Dart/Flutter). Il puntatore dichiarato sta in `latest.version`: si legge quello, mai
    # il massimo ricalcolato dall'elenco — il registro sa quale considera «ultima buona», e
    # ricalcolarlo vorrebbe dire sostituire la sua parola con la nostra.
    class Pub < Client
      def lookup(package, version)
        validate!(package, version)
        url = url_for("api", "packages", package)
        data = get(url, allow_not_found: true)
        return { present: false, yanked: false, latest: nil, sha: nil, url: url } if data.nil?

        row = Array(data["versions"]).find { |v| v["version"] == version }
        { present: row.present?, yanked: row && row["retracted"] == true,
          latest: data.dig("latest", "version"), sha: nil, url: url }
      end
    end
  end
end
