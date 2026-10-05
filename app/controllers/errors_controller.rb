# frozen_string_literal: true

# Pagine di errore DELL'APPLICAZIONE (CYRA-372). Prima rispondeva il file statico di Rails: schermata
# bianca, messaggio in inglese, nessun menu e nessuna via d'uscita — proprio a chi è già disorientato.
#
# Non richiede autenticazione: un indirizzo inesistente aperto da sloggato è comunque un 404, non un
# invito ad accedere. Quando invece la sessione e l'organizzazione ci sono, la pagina si veste col
# layout completo (menu, logo) e offre il ritorno alla home. Senza contesto degrada a una pagina
# semplice, senza errori a cascata — il rischio dichiarato nel ticket.
#
# I file in `public/` restano: sono la rete per quando Rails non gira affatto (da CYRA-325 sono
# comunque in italiano e con l'aspetto del prodotto).
class ErrorsController < Member::BaseController
  permission_not_required "Pagine di errore: dicono che quell'indirizzo non c'è o che qualcosa si è rotto, e si " \
                          "aprono anche da sloggati."

  allow_unauthenticated_access
  skip_before_action :set_current_organization
  skip_before_action :require_organization
  # CYRA-722 — un indirizzo sbagliato resta un 404 anche quando l'organizzazione è sospesa: qui si
  # dice che la pagina non esiste, non perché l'area è chiusa. Le due notizie non si sostituiscono.
  skip_before_action :require_active_organization
  # CYRA-554 — PREPEND, non un before_action normale: `around_action :switch_locale` (Localizable) è
  # registrato nella superclasse e avvolgerebbe un callback del figlio. La lingua verrebbe scelta con
  # la sessione non ancora ripresa — Current.account nil → default I18n (:en) — e chi usa il prodotto
  # in italiano si vedeva rispondere in inglese: titolo, testo e tutte le voci del menu.
  prepend_before_action :resolve_context

  layout :error_layout

  def not_found = render_error(:not_found)
  def unprocessable_entity = render_error(:unprocessable_content)
  def internal_server_error = render_error(:internal_server_error)

  private

  # La sessione si risolve SENZA imporla: se c'è, la pagina è quella completa.
  def resolve_context
    resume_session
    set_current_organization if Current.account
  rescue StandardError
    nil
  end

  # Cascata della lingua (CYRA-554): la preferenza di chi è dentro; per chi non lo è, la lingua
  # dichiarata dal browser; senza nemmeno quella, l'italiano — le stesse parole di public/404.html,
  # che è la controparte statica di questa pagina. Il default I18n (:en) qui non serve nessuno: chi
  # atterra su un errore è già disorientato, e il momento peggiore per cambiargli lingua sotto gli
  # occhi è proprio quello in cui gli serve leggere come tornare indietro.
  def request_locale
    Current.account&.effective_locale || browser_locale || :it
  end

  # CYRA-722 — con l'organizzazione sospesa la pagina di errore degrada al guscio semplice: il guscio
  # completo È l'area, e mostrarne menu e conteggi a chi è stato chiuso fuori riaprirebbe da qui la
  # porta che la sospensione ha chiuso. L'errore però resta quello vero (un 500 non diventa una
  # sospensione): questa pagina dice cos'è successo, non chi sei.
  def member_context?
    Current.account.present? && Current.organization.present? && !Current.organization.suspended?
  end

  def error_layout = member_context? ? "member" : "application"

  def render_error(status)
    # Only HTML has a page: a missing sitemap.xml got a 500 for the absent XML template (CYRA-914 P4).
    return head(status) unless request.format.html?

    @status = status
    @member_context = member_context?
    render "errors/show", status: status
  end
end
