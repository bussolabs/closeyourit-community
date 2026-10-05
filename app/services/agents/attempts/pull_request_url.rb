# frozen_string_literal: true

module Agents
  module Attempts
    # L'indirizzo della proposta, letto una volta sola. Lo guardano in due — il contratto della
    # consegna (la proposta sta in uno dei progetti fissati?) e l'effetto dell'autopilot (quale riga
    # scrivo nel registro?) — e due copie della stessa espressione sono due regole destinate a
    # divergere: basta che una accetti una forma che l'altra rifiuta perché una consegna passi il
    # controllo e poi non venga registrata.
    module PullRequestUrl
      # Solo github.com: un host diverso non è un altro modo di scrivere lo stesso indirizzo, è un
      # altro posto.
      PATTERN = %r{\Ahttps://github\.com/([A-Za-z0-9._-]{1,100})/([A-Za-z0-9._-]{1,100})/pull/([1-9][0-9]*)\z}

      # `<owner>/<repo>` e numero, o nil se l'indirizzo non è quello di una proposta su github.com.
      def self.coordinates(url)
        match = PATTERN.match(url.to_s) or return nil

        { full_name: "#{match[1]}/#{match[2]}", number: match[3].to_i }
      end
    end
  end
end
