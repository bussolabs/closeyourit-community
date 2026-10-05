# frozen_string_literal: true

# CYRA-340 — il periodo di tempo dell'area di controllo: uno solo, ricordato mentre si gira fra le
# pagine e sempre scritto nell'indirizzo.
#
# Due regole, e da lì discende tutto:
#   1. L'indirizzo comanda. `range` (o `from`/`to`) nell'indirizzo vince sempre su quello ricordato,
#      così il collegamento mandato a un collega gli mostra ESATTAMENTE gli stessi dati.
#   2. Chi sceglie un periodo se lo ritrova. La scelta finisce in sessione e, sulla pagina
#      successiva aperta senza periodo, torna NELL'INDIRIZZO con un redirect: se restasse solo in
#      sessione, la pagina mostrerebbe una finestra che il suo stesso indirizzo non dichiara — e
#      quel collegamento, condiviso, mostrerebbe a un altro un periodo diverso.
#
# Chi non ha mai scelto niente non ha nulla in sessione: nessun redirect, si atterra sul periodo
# predefinito (Monitoring::TimeRange::DEFAULT).
module TimeRangeable
  extend ActiveSupport::Concern

  SESSION_KEY = "monitoring_time_range"

  included do
    helper_method :current_time_range, :time_range_link_params
  end

  private

  def current_time_range
    @current_time_range ||= Monitoring::TimeRange.resolve(
      key: params[:range], from: params[:from], to: params[:to]
    )
  end

  # Il periodo che questa pagina passa a chi ci clicca sopra: il dettaglio di una riga si apre sullo
  # stesso arco di tempo dell'elenco da cui si arriva.
  def time_range_link_params = current_time_range.link_params

  # L'indirizzo dichiara già un periodo? Le pagine che hanno altri modi di dirlo (i log con
  # `since=today`, che è un deep-link dalla dashboard) sovrascrivono questo predicato.
  def time_range_declared? = params[:range].present? || params[:from].present? || params[:to].present?

  # before_action: nessun periodo nell'indirizzo ma uno ricordato → lo si rimette nell'indirizzo.
  # Solo su GET HTML: un redirect su una richiesta Turbo Stream o su un formato dati non avrebbe
  # senso. Nessun ciclo: dopo il redirect il periodo è dichiarato.
  def restore_time_range
    return if time_range_declared? || !request.get? || !request.format.html?

    remembered = session[SESSION_KEY]
    return if remembered.blank?

    redirect_to "#{request.path}?#{request.query_parameters.merge(remembered).to_query}"
  end

  # before_action: un periodo scelto (o arrivato da un collegamento) diventa quello corrente per
  # tutte le pagine successive, finché non lo si cambia.
  def remember_time_range
    return unless time_range_declared?

    session[SESSION_KEY] = current_time_range.link_params.stringify_keys
  end
end
