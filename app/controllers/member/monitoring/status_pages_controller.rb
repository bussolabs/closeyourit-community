# frozen_string_literal: true

module Member
  module Monitoring
    # La pagina di stato pubblica, finalmente visibile da dentro il prodotto (CYRA-483). Era la
    # funzionalità di maggior valore dell'area e la si scopriva solo leggendo una guida che nessuna
    # pagina richiamava: niente voce di menu, nessun indirizzo mostrato, nessuna anteprima. Qui si
    # vede cosa è esposto all'esterno, a quale indirizzo, e il codice da incorporare — che serve
    # PRIMA di pubblicare, per sapere cosa si sta per mettere sul proprio sito.
    class StatusPagesController < Member::BaseController
      permission_not_required "Mostra cosa è già pubblico e a quale indirizzo: sola lettura dei monitor visibili."

      # CYRA-737 — la base condivisa dell'area di controllo. Qui non c'è una lista da paginare: resta
      # inerte, e serve a far nascere già sulla base comune la prossima cosa che si aggiunge.
      include Indexable

      def show
        @published_monitors = visible.monitors.public_status.includes(:project, :environment).to_a
        @published_groups = ::Uptime::Group.where(organization_id: Current.organization.id)
                                           .public_status.order(:name).to_a
      end
    end
  end
end
