# frozen_string_literal: true

module Agents
  module Registries
    # npm. È l'unico dei quattro che dichiara da quale codice il pacchetto è stato costruito
    # (`gitHead`): lì il confronto col codice sigillato si può fare, e si fa.
    class Npm < Client
      # CYRA-1034 — only the latest published version, from the small `/latest` document.
      def latest(package)
        raise Error.new("package name outside the alphabet", code: "R422-REGISTRY-001") unless
          package.is_a?(String) && ALPHABETS.fetch(family).match?(package)

        get(url_for(package, "latest"), allow_not_found: true)&.dig("version")
      end

      def lookup(package, version)
        validate!(package, version)
        url = url_for(package)
        data = get(url, allow_not_found: true)
        return { present: false, yanked: false, latest: nil, sha: nil, url: url } if data.nil?

        row = data.dig("versions", version)
        {
          # La chiave c'è anche quando il suo contenuto è vuoto: `present?` direbbe di no, e la
          # versione risulterebbe non pubblicata proprio nel caso in cui manca solo il codice di
          # costruzione — due difetti diversi raccontati con la stessa parola.
          present: !row.nil?,
          # npm non dichiara il ritiro su questa risposta: una versione ritirata semplicemente
          # sparisce da `versions`. Non si finge di saperlo.
          yanked: false,
          latest: data.dig("dist-tags", "latest"),
          # Il campo può mancare: allora non c'è niente da confrontare, e la prova non passa.
          sha: row && row["gitHead"],
          url: url
        }
      end
    end
  end
end
