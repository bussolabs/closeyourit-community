# frozen_string_literal: true

module Projects
  module Releases
    # CYRA-738 — la lista delle registrazioni di rilascio di un progetto, una domanda sola per i due
    # canali a token. Le due copie ordinavano già allo stesso modo con due grafie diverse
    # (`recent` da una parte, `order(created_at: :desc)` dall'altra): stesso risultato oggi, due
    # posti da cambiare domani. Quanti se ne servono (tetto fisso o pagina) resta del canale.
    class Query < ApplicationService
      def initialize(project:)
        @project = project
      end

      def call = @project.releases.recent
    end
  end
end
