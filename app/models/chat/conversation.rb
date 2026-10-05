# frozen_string_literal: true

module Chat
  # Conversazione di chat per-organizzazione. Tre forme (kind):
  # - direct: DM 1:1; identità canonica in direct_key (SHA degli account-id ordinati, unica per org).
  #   L'accesso È essere partecipante (le 2 righe Chat::Participant sono anche l'ACL).
  # - project / team: canale legato a un contesto (contextable polimorfico). L'accesso è RELAZIONALE
  #   (VisibleScope per i progetti / team membership per i team): le righe Chat::Participant esistono
  #   solo per lo STATO (letto/muto), non per l'accesso.
  # organization_id è la radice tenant; context e direct_key sono mutuamente esclusivi (validati).
  class Conversation < ApplicationRecord
    # kind di canale → tipo di contextable atteso.
    KIND_CONTEXT = { "project" => "Projects::Project", "team" => "Teams::Team" }.freeze

    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :created_by, class_name: "Accounts::Account", optional: true
    belongs_to :contextable, polymorphic: true, optional: true

    has_many :participants, class_name: "Chat::Participant", inverse_of: :conversation, dependent: :destroy
    has_many :accounts, through: :participants
    has_many :messages, -> { chronological }, class_name: "Chat::Message", inverse_of: :conversation,
                                               dependent: :destroy

    enum :kind, { direct: 0, project: 1, team: 2 }, prefix: :kind

    validates :kind, presence: true
    # Un solo DM per coppia nell'org (gemello dell'indice parziale unique). allow_nil: i canali non
    # hanno direct_key.
    validates :direct_key, uniqueness: { scope: :organization_id }, allow_nil: true
    validate :context_matches_kind
    validate :context_in_organization

    # Attività recente prima; i DM appena creati senza messaggi (last_message_at nil) in coda.
    scope :ordered, -> { order(Arel.sql("last_message_at DESC NULLS LAST"), created_at: :desc) }

    # Chiave canonica di un DM: SHA degli id ordinati → indipendente dall'ordine dei due account.
    def self.direct_key_for(account_a, account_b)
      Digest::SHA256.hexdigest([ account_a.id, account_b.id ].sort.join(":"))
    end

    # Conversazioni visibili all'account nell'org: DM dove è partecipante ∪ canali col contesto visibile
    # (progetti via VisibleScope, team via appartenenza). Gemello dei Authorization::VisibleScope.
    def self.visible_to(account:, organization:)
      base = where(organization_id: organization.id)

      dm_ids = base.kind_direct.joins(:participants)
                   .where(chat_participants: { account_id: account.id }).pluck(:id)

      scope = Authorization::VisibleScope.new(account: account, organization: organization)
      project_ids = scope.projects.pluck(:id)
      team_ids = account.teams.where(organization_id: organization.id).pluck(:id)

      channel_ids =
        base.kind_project.where(contextable_type: "Projects::Project", contextable_id: project_ids).pluck(:id) +
        base.kind_team.where(contextable_type: "Teams::Team", contextable_id: team_ids).pluck(:id)

      where(id: (dm_ids + channel_ids).uniq)
    end

    # Non-letti per-conversazione in 1 query (badge della lista chat): messaggi kept altrui più
    # recenti del last_read_at del viewer. LEFT JOIN perché la riga participant può mancare (per i
    # canali è lazy, vedi Chat::Participant) → nessun last_read_at = tutto non letto. IS DISTINCT
    # FROM: un autore nullificato (account cancellato) resta "altrui" — un != NULL-unsafe lo
    # perderebbe. Hash { conversation_id => n } senza chiavi a zero.
    def self.unread_counts_for(account:, conversation_ids:)
      return {} if conversation_ids.blank?

      participant_join = sanitize_sql_array([
        "LEFT JOIN chat_participants ON chat_participants.conversation_id = chat_messages.conversation_id " \
        "AND chat_participants.account_id = ?", account.id
      ])

      Chat::Message.kept
                   .where(conversation_id: conversation_ids)
                   .where("chat_messages.author_id IS DISTINCT FROM ?", account.id)
                   .joins(participant_join)
                   .where("chat_participants.last_read_at IS NULL OR chat_messages.created_at > chat_participants.last_read_at")
                   .group(:conversation_id)
                   .count
    end

    # Vero quando l'account può accedere a questa conversazione (DM → partecipante; canale → contesto
    # visibile). Usato dai controller/channel come guard anti-BOLA.
    def accessible_by?(account)
      if kind_direct?
        participants.exists?(account_id: account.id)
      else
        self.class.visible_to(account: account, organization: organization).exists?(id: id)
      end
    end

    # Titolo mostrato all'account: per un DM il nome dell'altro partecipante, per un canale il nome del
    # contesto (progetto/team). Neutro rispetto al chiamante (ogni utente vede "l'altro" nel proprio DM).
    def title_for(account)
      case kind
      when "direct" then accounts.reject { |a| a.id == account.id }.first&.name
      when "project", "team" then contextable&.name
      end
    end

    # Gli account che possono vedere questa conversazione: base per lo scoping "in comune" delle risorse
    # taggate e per il fan-out delle notifiche. DM → i due partecipanti; canale progetto → chi vede il
    # progetto (Alerting::Recipients, inverso di VisibleScope); canale team → i membri del team.
    def audience
      case kind
      when "direct" then accounts.to_a
      when "project" then Alerting::Recipients.for(project: contextable).to_a
      when "team" then contextable.members.to_a
      else []
      end
    end

    private

    # direct ⇔ direct_key presente e nessun contextable; canale ⇔ contextable del tipo giusto, no direct_key.
    def context_matches_kind
      if kind_direct?
        errors.add(:contextable, :present) if contextable_id.present?
        errors.add(:direct_key, :blank) if direct_key.blank?
      else
        errors.add(:direct_key, :present) if direct_key.present?
        errors.add(:contextable, :blank) and return if contextable.blank?
        errors.add(:contextable, :invalid) if contextable_type != KIND_CONTEXT[kind]
      end
    end

    # Integrità tenant: il contesto (progetto/team) dev'essere della stessa org della conversazione.
    def context_in_organization
      return if contextable.blank? || organization_id.blank?

      ctx_org = contextable.try(:organization_id)
      errors.add(:contextable, :mismatch) if ctx_org.present? && ctx_org != organization_id
    end
  end
end
