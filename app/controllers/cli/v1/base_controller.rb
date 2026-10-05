# frozen_string_literal: true

module Cli
  module V1
    # Base dell'API dati CLI (token utente). Autentica via UserTokenAuthentication (pinna Current.account
    # + organization) e gate ogni mutazione con Authorization::Resolver. Anti-BOLA: lo scope progetto si
    # risolve da visible_projects (invisibile → RecordNotFound → R404, mai 403).
    class BaseController < Cli::Api::BaseController
      include UserTokenAuthentication
      # CYRA-728 — le azioni segnate `dangerous` nel catalogo non partono senza conferma nemmeno qui.
      include DangerousActionConfirmation

      before_action :authenticate_user_token!

      private

      def authorization
        @authorization ||=
          Authorization::Resolver.new(account: Current.account, organization: Current.organization)
      end

      # Gate di permesso. Usabile come before_action (render su deny → halt della catena) o inline
      # (ritorna true/false). Anti-BOLA: lo scope va risolto PRIMA (set_project!) così un progetto non
      # visibile dà 404 prima del 403.
      def require_permission!(key, scope: nil)
        unless authorization.can?(key, scope: scope)
          render_error("R403-CLIAUTH-002", "Permesso negato", status: :forbidden)
          return false
        end

        # CYRA-728 — il permesso c'è; per le chiavi pericolose serve anche il gesto. Dal terminale
        # arriva col flag di conferma del comando, che lo traduce nel parametro `confirm`.
        enforce_dangerous_confirmation!(key, scope: scope)
      end

      # Manca la conferma: 422, non 403. Il permesso c'è — un client che leggesse «permesso negato»
      # andrebbe a farsi dare un permesso che ha già, invece di ripetere il comando con --yes.
      def deny_unconfirmed_dangerous_action(key)
        render_error(
          MISSING_CONFIRMATION_CODE,
          "Azione pericolosa: ripeti il comando confermando (--yes)",
          status: :unprocessable_content,
          details: { permission: key }
        )
      end

      # Gate "solo owner o god", org-level: serve alle cancellazioni DEFINITIVE dei file segreti, dove
      # il manage non basta perché l'operazione distrugge ciphertext e storico e non è recuperabile.
      # Ritorna true/false come require_permission! (usabile inline con `return unless`).
      def require_owner!(message = "Solo owner o god può eliminare definitivamente un asset")
        return true if Current.account&.god? ||
                       Current.organization.memberships.exists?(account_id: Current.account&.id, role: :owner)

        render_error("R403-CLIAUTH-002", message, status: :forbidden)
        false
      end

      def visible_projects
        Authorization::VisibleScope.new(account: Current.account, organization: Current.organization).projects
      end

      # Gruppi visibili dell'org (gemello di visible_projects): owner/god vedono tutto, member/customer
      # solo gli assegnati. Fonte unica per l'enumerazione groups nel canale CLI, come visible.groups
      # nel Member — evita il leak di enumerare TUTTI i gruppi org con un token a visibilità ristretta.
      def visible_groups
        Authorization::VisibleScope.new(account: Current.account, organization: Current.organization).groups
      end

      # Risolve il progetto del path dentro lo scope visibile (fuori scope → R404, anti-BOLA).
      def set_project!
        @project = visible_projects.find(params[:project_id] || params[:id])
      end

      # Risolve un ticket dentro il progetto per UUID OPPURE code umano ("DRFL-3", case-insensitive):
      # la CLI referenzia i ticket col code mostrato in list/show. Si accetta SOLO il code del progetto
      # del path (prefisso diverso o numero inesistente → RecordNotFound → R404, stesso anti-BOLA del
      # lookup per id). Usato da TicketsController e da tutti i sub-controller tickets/*.
      def find_ticket!(project, ref)
        ref = ref.to_s.strip
        if (match = /\A#{Regexp.escape(project.key)}-(\d+)\z/i.match(ref))
          project.tickets.find_by!(number: match[1].to_i)
        else
          project.tickets.find(ref)
        end
      end

      # Ticket visibili all'account nell'org corrente = ticket dei progetti visibili (gemello CLI di
      # Authorization::VisibleScope#tickets del canale Member). Fuori scope → assenti, non 403.
      def visible_tickets
        Ticketing::Ticket.where(project_id: visible_projects.select(:id))
      end

      # Risolve un ticket tra TUTTI i visibili (cross-project intra-org) per UUID o code umano ("DRFL-3").
      # A differenza di find_ticket! (scoped a UN progetto del path), serve dove il riferimento può
      # puntare a un progetto DIVERSO — es. il blocker di una dipendenza cross-project. Il lookup è
      # SEMPRE scoped prima (mai globale poi authz): un ref fuori scope (altra org, progetto non
      # assegnato, code inesistente) → nil, e il chiamante lo traduce in 404 anti-BOLA. La key è al
      # massimo 4 caratteri: un UUID non entra mai nel ramo KEY-N e finisce sempre sul lookup per id.
      def find_visible_ticket(ref)
        ref = ref.to_s.strip
        if (match = /\A([a-z0-9]{1,4})-(\d+)\z/i.match(ref))
          project = visible_projects.find_by(key: match[1].upcase)
          project&.tickets&.find_by(number: match[2].to_i)
        else
          visible_tickets.find_by(id: ref)
        end
      end

      # Paginazione offset nativa → [records, meta] per l'envelope {data:, meta:}.
      def paginate(scope)
        result = Pagination.call(scope, page: params[:page], per: params[:per].presence || Pagination::MACHINE_DEFAULT_PER)
        meta = { page: result.page, per: result.per, total: result.total, total_pages: result.total_pages }
        [ result.records, meta ]
      end
    end
  end
end
