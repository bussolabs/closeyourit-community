# frozen_string_literal: true

module Assistant
  module Tools
    # "Come sta CYRA?" in un colpo solo: ticket per categoria, errori non risolti, monitor giù.
    #
    # È l'unico attrezzo che compone più domini, ed esiste perché la domanda è una sola mentre i dati
    # stanno in tre posti: senza, il modello dovrebbe incatenare tre attrezzi e pagare tre giri per
    # una domanda che chiunque fa di continuo.
    #
    # I conteggi vengono dalle stesse fonti che l'utente vede a schermo — Ticketing::Tally (categoria,
    # non code) ed Errors::Group#status_unresolved — così il numero detto dall'assistente e quello
    # della pagina non possono divergere.
    class ProjectHealth < Base
      def self.declaration
        { name: "project_health",
          description: "Health summary of ONE project: how many tickets are to do, " \
                       "in progress and done, how many errors are unresolved, which monitors are down. " \
                       "Use it for questions like 'how is CYRA doing?' or 'how are my projects going?'.",
          parameters: {
            type: "OBJECT",
            properties: { project: { type: "STRING", description: "Project key, e.g. CYRA" } },
            required: [ "project" ]
          } }
      end

      def call(args)
        project = context.find_project(args["project"])
        return not_visible(args["project"]) if project.nil?

        tally = ::Ticketing::Tally.for(context.tickets.where(project_id: project.id))

        { project: project.key, name: project.name,
          tickets: { da_fare: tally.todo, in_corso: tally.in_progress,
                     conclusi: tally.done, non_chiusi: tally.unresolved },
          errori_non_risolti: ::Errors::Group.where(project_id: project.id).status_unresolved.count,
          monitor_giu: monitors_down(project) }
      end

      private

      # Solo i monitor ATTIVI: uno in pausa non è un guasto, e segnalarlo come tale farebbe suonare
      # un allarme per una scelta deliberata.
      def monitors_down(project)
        ::Uptime::Monitor.where(project_id: project.id).active.status_down.order(:name).pluck(:name)
      end
    end
  end
end
