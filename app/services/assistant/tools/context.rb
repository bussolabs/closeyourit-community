# frozen_string_literal: true

module Assistant
  module Tools
    # Il perimetro dentro cui l'assistente può guardare, CONGELATO nel momento in cui la domanda
    # viene accodata (stesso pattern del RAG sui ticket del canale web: Member::TicketsController
    # #ask_query salva project_ids negli argomenti e il job ricostruisce lo scope da lì).
    #
    # È l'unico punto da cui gli attrezzi ricavano i dati: nessun attrezzo accetta un id grezzo
    # scelto dal modello. Il modello passa una CHIAVE di progetto o un codice ticket, l'attrezzo lo
    # risolve DENTRO questo perimetro, e se non lo trova risponde "non visibile" senza allargare la
    # ricerca. Così un id inventato o copiato da un'altra organizzazione non produce mai una lettura.
    #
    # Il perimetro porta TRE cose e non una sola: i progetti, i gruppi e il flag di accesso pieno.
    # Servono tutti e tre perché la knowledge base non appartiene a un progetto — una pagina sta su
    # più progetti e su più gruppi (N:N), e chi ha accesso pieno le vede tutte. Ricalcolarli a valle
    # darebbe il perimetro di un altro momento, e per un god che impersona quello sbagliato.
    # `scope_reduced` dice che quel perimetro è MENO di quello con cui la domanda era partita: fra
    # l'invio e l'esecuzione è stato tolto l'accesso a qualcosa (CYRA-812). Chi risponde lo dice a
    # chi ha chiesto, invece di consegnare in silenzio una risposta più povera che si legge come un
    # dato di fatto. Nasce falso perché il perimetro appena fotografato non ha ancora perso niente.
    Context = Data.define(:account, :organization, :project_ids, :group_ids, :full_access, :scope_reduced,
                          :reply_message_id) do
      def initialize(scope_reduced: false, reply_message_id: nil, **) = super

      def self.freeze_for(account:, organization:)
        snapshot = Authorization::ScopeSnapshot.capture(account: account, organization: organization)
        from_snapshot(snapshot, account: account, organization: organization)
      end

      # Il perimetro con cui gli attrezzi vanno a leggere: il tetto dell'invio ripassato dal
      # perimetro di ADESSO (Authorization::ScopeSnapshot#narrow).
      def self.from_snapshot(snapshot, account:, organization:, reply_message_id: nil)
        new(account: account, organization: organization,
            project_ids: snapshot.project_ids, group_ids: snapshot.group_ids,
            full_access: snapshot.full_access, scope_reduced: snapshot.reduced?,
            reply_message_id: reply_message_id)
      end

      # Write tools attach their proposals to this reply; without it they are not offered (CYRA-907).
      def proposals? = reply_message_id.present?

      def projects = Projects::Project.where(id: project_ids)
      def tickets = Ticketing::Ticket.where(project_id: project_ids)

      # Le pagine NON hanno un project_id: la visibilità passa dai progetti E dai gruppi collegati,
      # e chi ha accesso pieno vede tutta l'organizzazione. Lo scope che sa tutto questo esiste già.
      def knowledge_pages
        Knowledge::Page.visible_to(account: account, organization: organization,
                                   full_access: full_access,
                                   visible_project_ids: project_ids, visible_group_ids: group_ids)
      end

      # Risoluzione di un progetto per chiave (CYRA) o nome, sempre dentro il perimetro.
      # Case-insensitive perché la chiave arriva dal parlato di chi scrive, non da un menu.
      def find_project(reference)
        key = reference.to_s.strip
        return nil if key.blank?

        projects.where("UPPER(key) = ?", key.upcase).first ||
          projects.where("name ILIKE ?", "%#{Projects::Project.sanitize_sql_like(key)}%").first
      end

      # A ticket by code (CYRA-279), always inside the scope (CYRA-907).
      def find_ticket(reference)
        match = reference.to_s.strip.match(/\A([A-Za-z0-9]+)-(\d+)\z/)
        project = match && find_project(match[1])
        return nil if project.nil?

        tickets.where(project_id: project.id, number: match[2]).first
      end
    end
  end
end
