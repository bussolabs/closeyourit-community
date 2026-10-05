# frozen_string_literal: true

# CYRA-728 — la conferma delle azioni pericolose, uguale nei due canali.
#
# Chi include questa concern ottiene le tre mosse che servono a un gate: chiedersi se la richiesta
# vada confermata, sapere se la conferma è arrivata, e lasciarne traccia quando l'azione parte.
# Come si NEGA resta al canale: l'area utenti mostra una pagina, la riga di comando risponde con
# l'envelope degli errori. Il resto — quali chiavi, quali verbi, quali forme valgono come sì — sta
# in Authorization::DangerousAction, in un punto solo.
module DangerousActionConfirmation
  extend ActiveSupport::Concern

  # Il codice che i client leggono quando manca la conferma. Non è un 403: il permesso c'è, manca il
  # gesto. Un client che ricevesse «permesso negato» proverebbe a farsi dare un permesso che ha già.
  MISSING_CONFIRMATION_CODE = "R422-CONFIRM-001"

  # Il motivo che vale per tutte le azioni del controller.
  EVERY_ACTION = "*"

  included do
    # Ereditato dai figli, come le esenzioni dei permessi (CYRA-727).
    class_attribute :confirmation_exemptions, instance_writer: false, default: {}.freeze
  end

  class_methods do
    # Dichiara PERCHÉ questa azione non chiede conferma pur passando da una chiave pericolosa.
    #
    # Serve perché «scrive» si deduce dal verbo, e il verbo qualche volta mente: la pagina che mostra
    # cosa succederebbe fondendo due gruppi di errori è un POST (la selezione è lunga e non ci sta in
    # un indirizzo) ma non tocca niente — ed è, per giunta, proprio la schermata di conferma. Farle
    # chiedere una conferma per mostrare una conferma è il modo più rapido di insegnare a chi usa il
    # prodotto che le conferme si cliccano senza leggerle.
    #
    # Il motivo è obbligatorio e va scritto per esteso: lo leggerà chi, fra un anno, si chiederà se
    # qui manchi una protezione.
    def confirmation_not_required(reason, only: nil)
      actions = only.nil? ? [ EVERY_ACTION ] : Array(only).map(&:to_s)
      self.confirmation_exemptions = confirmation_exemptions.merge(actions.index_with(reason.to_s)).freeze
    end
  end

  private

  def confirmation_exempt_action?
    confirmation_exemptions[action_name.to_s].present? || confirmation_exemptions[EVERY_ACTION].present?
  end

  # La richiesta corrente passa da una chiave pericolosa, scrive, e nessuno ha confermato.
  def dangerous_confirmation_missing?(key)
    return false unless dangerous_action?(key)

    !dangerous_action_confirmed?
  end

  def dangerous_action?(key)
    return false if confirmation_exempt_action?

    Authorization::DangerousAction.confirmation_required?(key: key, request_method: request.request_method)
  end

  def dangerous_action_confirmed?
    Authorization::DangerousAction.confirmed?(params[Authorization::DangerousAction::CONFIRM_PARAM])
  end

  # L'azione pericolosa è stata confermata e sta per partire: resta nel registro dei permessi, dove
  # già si legge chi ha dato e tolto poteri a chi. Una riga per chiave per richiesta — un'azione che
  # interroga due volte lo stesso gate (fondere due gruppi di errori, per dirne una) è UN gesto.
  #
  # Il registro non può impedire l'azione: se scrivere la riga fallisce resta un warn nel log, come
  # per le altre scritture accessorie dell'area. Un'eliminazione che l'utente ha confermato e che il
  # permesso consente non si blocca perché la cronologia non ha preso nota.
  def record_dangerous_confirmation!(key, scope: nil)
    return unless dangerous_action?(key)
    return unless Current.organization

    @dangerous_confirmations_recorded ||= Set.new
    return unless @dangerous_confirmations_recorded.add?(key)

    Authorization::RecordChange.call(
      organization: Current.organization,
      actor: Current.account,
      true_actor: Current.true_account,
      action: "dangerous_action_confirmed",
      data: {
        key: key,
        method: request.request_method,
        path: request.path,
        scope_type: scope&.class&.name,
        scope_id: scope&.id
      }.compact
    )
  rescue StandardError => e
    Rails.logger.warn("CYRA-728 — registro della conferma non scritto (#{key}): #{e.class}: #{e.message}")
  end

  # Il gate completo, dopo che il permesso è già stato concesso: o l'azione è confermata e resta
  # scritta, o non parte. Ritorna false quando ha negato, così i due canali possono usarlo inline.
  def enforce_dangerous_confirmation!(key, scope: nil)
    if dangerous_confirmation_missing?(key)
      Rails.logger.warn(
        "Dangerous action unconfirmed — account=#{Current.account&.id} org=#{Current.organization&.id} " \
        "key=#{key} path=#{request.path}"
      )
      deny_unconfirmed_dangerous_action(key)
      return false
    end

    record_dangerous_confirmation!(key, scope: scope)
    true
  end
end
